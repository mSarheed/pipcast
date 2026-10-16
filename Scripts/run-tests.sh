#!/bin/bash
# The test suite: each harness compiles the shipped sources it guards. See docs/testing.md.

set -uo pipefail

# Absolute: the workers re-enter this script after the cd, where a relative $0 would not resolve.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.." || exit 1

BIN="${TMPDIR:-/tmp}/pipcast-harness"
mkdir -p "$BIN"

# `--exec` is the worker half: xargs re-enters here once per queued harness.
if [ "${1:-}" = "--exec" ]; then
    shift
    name=$1 opt=$2
    shift 2
    : > "$BIN/$name.running"
    trap 'rm -f "$BIN/$name.running" "$BIN/$name.time"' EXIT
    fail() {
        printf '\033[31mFAIL\033[0m  %-25s %s\n' "$name" "$1"
        : > "$BIN/$name.failed"
        exit 0
    }
    TIMEFORMAT=%1R
    if ! compiled=$( { time swiftc -swift-version 6 "$opt" "$@" "Tests/$name.swift" -o "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2>&1 ); then
        fail "did not compile"
    fi
    { time "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2> "$BIN/$name.time" &
    pid=$!
    # macOS ships no `timeout`, so the worker polls; a wedged harness must fail, not stall.
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $((PIPCAST_TEST_TIMEOUT * 5)) ]; then
            { pkill -KILL -P "$pid"; kill -KILL "$pid"; wait "$pid"; } 2>/dev/null
            printf '\n[run-tests] killed after %ss without finishing\n' "$PIPCAST_TEST_TIMEOUT" >> "$BIN/$name.log"
            fail "timed out after ${PIPCAST_TEST_TIMEOUT}s"
        fi
        ticks=$((ticks + 1))
        sleep 0.2
    done
    wait "$pid"
    status=$?
    took=$(< "$BIN/$name.time")
    if [ "$status" -gt 128 ]; then fail "crashed (signal $((status - 128))) after ${took}s"; fi
    if [ "$status" -ne 0 ]; then fail "assertion failed after ${took}s"; fi
    printf '\033[32mok\033[0m    %-25s %5ss  \033[2m(compile %ss)\033[0m\n' "$name" "$took" "$compiled"
    exit 0
fi

QUEUE="$BIN/queue"
: > "$QUEUE"
rm -f "$BIN"/*.failed "$BIN"/*.running

failed=()
ran=0
only="${1:-}"

# `--index` feeds harness compile commands to .compile, as xcodebuild never compiles Tests/.
emit_db=0
DB="${TMPDIR:-/tmp}/pipcast-compile-db.json"
if [ "$only" = "--index" ]; then
    emit_db=1
    only=""
    printf '[' > "$DB"
fi

# `slow` dispatches in the first wave; `index` only claims editor flags for a hand-run harness.
run() {
    local opt=-Onone pri=1 index_only=0
    while :; do
        case "$1" in
            slow)  pri=0; shift;;
            -O)    opt=-O; shift;;
            index) index_only=1; shift;;
            *)     break;;
        esac
    done
    local name=$1
    shift
    if [ -n "$only" ] && [ "$name" != "$only" ]; then return 0; fi
    if [ "$index_only" -eq 1 ] && [ "$emit_db" -eq 0 ]; then return 0; fi
    ran=$((ran + 1))

    # Absolute paths: sourcekit-lsp ignores `directory` for relative arguments and indexes nothing.
    if [ "$emit_db" -eq 1 ]; then
        local sources=()
        for source in "$@" "Tests/$name.swift"; do sources+=("$PWD/$source"); done
        [ "$ran" -gt 1 ] && printf ',' >> "$DB"
        printf '{"directory":"%s","command":"swiftc -swift-version 6 -sdk %s' \
            "$PWD" "$(xcrun --show-sdk-path --sdk macosx)" >> "$DB"
        printf ' %s' "${sources[@]}" >> "$DB"
        # Only `Tests/` files: `.compile` is last-wins, so a shipped source keeps the app's command.
        local claimed=""
        for source in "${sources[@]}"; do
            case "$source" in *"/Tests/"*) claimed="$claimed${claimed:+,}\"$source\"";; esac
        done
        printf '","files":[%s]}' "$claimed" >> "$DB"
        return 0
    fi

    # xargs splits the queue on whitespace, so no harness source path may contain a space.
    printf '%s %s %s %s\n' "$pri" "$name" "$opt" "$*" >> "$QUEUE"
}

L=Pipcast/Features/Launcher/Model
run slow -O fuzz-test      $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/LauncherMatch.swift $L/EntryNaming.swift $L/LauncherOrder.swift \
                           $L/LauncherRankingStore.swift $L/LauncherSuggestions.swift
FS=Pipcast/Features/FileSearch
FILE_INDEX="$FS/Service/FileIndex.swift $FS/Service/FileIndexSnapshot.swift $FS/Service/FileIndexCrawler.swift"
run file-search-test       $FS/Model/*.swift
run file-index-test        $FS/Model/*.swift $FILE_INDEX
run file-search-session-test $FS/Model/*.swift $FS/Service/FileSearchSession.swift $FILE_INDEX
run menu-search-test       $L/SearchRelevance.swift \
                           Pipcast/Features/MenuSearch/Model/*.swift \
                           Pipcast/Features/MenuSearch/Service/*.swift
run window-switch-test     $L/SearchRelevance.swift \
                           Pipcast/Features/WindowSwitcher/Model/*.swift
run index file-search-performance $FS/Model/*.swift $FILE_INDEX
run ranking-test           $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/LauncherMatch.swift $L/LauncherRankingStore.swift
run scopes-test            $L/SearchScopes.swift
run app-name-test          Pipcast/Platform/AppDisplayName.swift \
                           Pipcast/Platform/BundleLocalization.swift \
                           $L/SearchRelevance.swift
run favorites-test         $L/FavoriteSlots.swift
run launcher-file-test     $L/LauncherFileFormat.swift \
                           Pipcast/Features/Settings/Model/SettingsFileJSON.swift
run launcher-settings-file-test \
                           $L/LauncherFileFormat.swift $L/CommandID.swift $L/CommandCatalog.swift \
                           Pipcast/Features/Launcher/Service/LauncherSettingsFile.swift \
                           Pipcast/Features/Launcher/Service/AliasStore.swift \
                           Pipcast/Features/Launcher/Service/VisibilityStore.swift \
                           Pipcast/Features/Settings/SettingsTab.swift \
                           Pipcast/Features/Settings/Model/*.swift \
                           Pipcast/Features/HotKeys/Service/HotKeySettingsFile.swift \
                           Pipcast/Features/HotKeys/Service/KeyShortcut.swift \
                           Pipcast/Features/HotKeys/Model/HotKeyAction.swift \
                           Pipcast/Features/HotKeys/Model/HotKeyBinding.swift \
                           Pipcast/Features/HotKeys/Model/HotKeySpelling.swift \
                           Pipcast/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Pipcast/Features/HotKeys/Model/ModifierKey.swift \
                           Pipcast/Features/HotKeys/Model/HyperKey.swift \
                           Pipcast/Features/HotKeys/Model/HIDKeyMapping.swift \
                           Pipcast/Platform/ASCIIKeyboardLayout.swift \
                           Pipcast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Pipcast/Features/Quicklinks/Model/Quicklink.swift \
                           Pipcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Pipcast/Features/SystemActions/Model/SystemAction.swift \
                           Pipcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Pipcast/Features/Snippets/Model/Snippet.swift
run apple-shortcut-test    Pipcast/Features/AppleShortcuts/Model/*.swift
run calc-test              Pipcast/Features/Calculator/Model/*.swift
run index calc-performance Pipcast/Features/Calculator/Model/*.swift
run calendar-test          Pipcast/Features/Calendar/Model/*.swift \
                           Pipcast/Features/Calendar/UI/EventEditorSession.swift
run clipboard-test         Pipcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Pipcast/Platform/Images/ImageDerivative.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Pipcast/Features/Clipboard/Model/ColorValue.swift \
                           Pipcast/Features/Clipboard/Model/ColorFormat.swift \
                           Pipcast/Features/Clipboard/Model/ColorSpaces.swift
run clipboard-thumbnail-test Pipcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Pipcast/Platform/Images/ImageDerivative.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Pipcast/Features/Clipboard/Model/ColorValue.swift \
                           Pipcast/Features/Clipboard/Model/ColorFormat.swift \
                           Pipcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Pipcast/Platform/ProcessExit.swift \
                           Pipcast/Platform/Images/ImageThumbnail.swift \
                           Pipcast/Platform/Images/ThumbnailCache.swift
# `Q` is the URL detector a drag payload builds its link with, rather than a second one.
Q=Pipcast/Features/Quicklinks/Model/QuicklinkDestination.swift
run clipboard-search-test  Pipcast/Features/Clipboard/Model/*.swift Pipcast/Platform/Images/ImageDerivative.swift $Q
run paste-sequence-test    Pipcast/Features/Clipboard/Model/*.swift Pipcast/Platform/Images/ImageDerivative.swift $Q
run clipboard-text-test    Pipcast/Features/Clipboard/Model/*.swift Pipcast/Platform/Images/ImageDerivative.swift $Q \
                           Pipcast/Features/Clipboard/Service/ClipboardTextExtractor.swift \
                           Pipcast/Features/Clipboard/Service/ClipboardTextIndexer.swift \
                           Pipcast/Features/Clipboard/Service/ClipboardTextWorker.swift \
                           Pipcast/Platform/ProcessExit.swift
run pasteboard-test        Pipcast/Platform/PasteboardFiles.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Pipcast/Platform/Images/ImageDerivative.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Pipcast/Features/Clipboard/Model/ColorValue.swift \
                           Pipcast/Features/Clipboard/Model/ColorFormat.swift \
                           Pipcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Pipcast/Features/Clipboard/Service/ClipboardManager.swift \
                           Pipcast/Features/Clipboard/Service/Paster.swift
run index clipboard-file-performance \
                           Pipcast/Platform/PasteboardFiles.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Pipcast/Platform/Images/ImageDerivative.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Pipcast/Features/Clipboard/Model/ColorValue.swift \
                           Pipcast/Features/Clipboard/Model/ColorFormat.swift \
                           Pipcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Pipcast/Features/Clipboard/Service/ClipboardManager.swift
run index clipboard-thumbnail-performance \
                           Pipcast/Platform/ProcessExit.swift \
                           Pipcast/Platform/Images/ImageThumbnail.swift \
                           Pipcast/Platform/Images/ImageDerivative.swift \
                           Pipcast/Platform/Images/ThumbnailCache.swift
run emoji-test             Pipcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Pipcast/Features/Emoji/Model/EmojiGridGeometry.swift \
                           Pipcast/Features/Emoji/Model/EmojiData.generated.swift
run emoji-search-test      Pipcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Pipcast/Features/Emoji/Model/EmojiData.generated.swift \
                           Pipcast/Features/Emoji/Service/EmojiIndex.swift \
                           Pipcast/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Pipcast/Features/Emoji/Service/PinnedEmojiStore.swift \
                           Pipcast/Features/Launcher/Model/SearchRelevance.swift \
                           Pipcast/Platform/AppPaths.swift Pipcast/Platform/Memo.swift
run index emoji-search-performance \
                           Pipcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Pipcast/Features/Emoji/Model/EmojiData.generated.swift \
                           Pipcast/Features/Emoji/Service/EmojiIndex.swift \
                           Pipcast/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Pipcast/Features/Launcher/Model/SearchRelevance.swift \
                           Pipcast/Platform/AppPaths.swift Pipcast/Platform/Memo.swift
run palette-selection-test Pipcast/Features/PaletteRowIndex.swift \
                           Pipcast/Features/Emoji/Model/EmojiGridGeometry.swift
run appearance-test        Pipcast/Platform/Appearance.swift \
                           Pipcast/DesignSystem/Theme.swift \
                           Pipcast/DesignSystem/InterfaceMetrics.swift \
                           Pipcast/Features/Settings/AppAppearance.swift
run interface-size-test    Pipcast/Platform/Appearance.swift \
                           Pipcast/DesignSystem/Theme.swift \
                           Pipcast/DesignSystem/InterfaceMetrics.swift \
                           Pipcast/Features/Settings/InterfaceSize.swift \
                           Pipcast/Features/Extensions/Model/ExtensionFormMetrics.swift
run palette-placement-test Pipcast/Platform/Appearance.swift \
                           Pipcast/DesignSystem/Theme.swift \
                           Pipcast/DesignSystem/InterfaceMetrics.swift \
                           Pipcast/Features/Settings/InterfaceSize.swift \
                           Pipcast/Palette/PalettePlacement.swift
run palette-menu-click-test Pipcast/Platform/Appearance.swift \
                           Pipcast/DesignSystem/Theme.swift \
                           Pipcast/Platform/WindowLevel.swift \
                           Pipcast/Platform/NotificationToken.swift \
                           Pipcast/DesignSystem/Interaction/KeyboardFocus.swift \
                           Pipcast/Palette/PalettePanel.swift
run form-input-test        Pipcast/Platform/Appearance.swift \
                           Pipcast/DesignSystem/Theme.swift \
                           Pipcast/DesignSystem/InterfaceMetrics.swift \
                           Pipcast/DesignSystem/FormTextInput.swift \
                           Pipcast/DesignSystem/FormTextArea.swift
run scroll-reveal-test     Pipcast/DesignSystem/Scrolling/SelectionReveal.swift
run redaction-test         Pipcast/DesignSystem/RedactedPlaceholder.swift
run keyboard-focus-test    Pipcast/DesignSystem/Interaction/KeyboardFocus.swift
run palette-escape-test    Pipcast/Palette/PaletteMode.swift \
                           Pipcast/Palette/PaletteEscapeAction.swift \
                           Pipcast/Palette/CommandEscapeTap.swift \
                           Pipcast/Features/Settings/EscapeKeyBehavior.swift \
                           Pipcast/Features/Quicklinks/Model/Quicklink.swift \
                           Pipcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Pipcast/Features/CustomCommands/Model/CustomCommand.swift
run palette-navigation-test Pipcast/Palette/PaletteState.swift \
                           Pipcast/Palette/PaletteMode.swift \
                           Pipcast/Palette/HoverArming.swift \
                           Pipcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Pipcast/Platform/Images/ImageDerivative.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Pipcast/Features/FileSearch/Model/FileSearchFilter.swift \
                           Pipcast/Features/Clipboard/Model/ColorValue.swift \
                           Pipcast/Features/Clipboard/Model/ColorFormat.swift \
                           Pipcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Pipcast/Features/Quicklinks/Model/Quicklink.swift \
                           Pipcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Pipcast/Features/CustomCommands/Model/CustomCommand.swift
run palette-filter-test    Pipcast/Palette/PaletteMode.swift \
                           Pipcast/Palette/PaletteFilterAction.swift \
                           Pipcast/Features/Quicklinks/Model/Quicklink.swift \
                           Pipcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Pipcast/Features/CustomCommands/Model/CustomCommand.swift
run action-menu-search-test Pipcast/Palette/ActionMenuSearchQuery.swift \
                            Pipcast/Features/Launcher/Model/SearchRelevance.swift
run palette-shortcut-test  Pipcast/Palette/PaletteShortcut.swift
run ascii-layout-test      Pipcast/Platform/ASCIIKeyboardLayout.swift
run palette-tab-test       Pipcast/Palette/PaletteMode.swift \
                           Pipcast/Palette/PaletteTabAction.swift \
                           Pipcast/Features/Quicklinks/Model/Quicklink.swift \
                           Pipcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Pipcast/Features/CustomCommands/Model/CustomCommand.swift
run fallback-test          Pipcast/Features/Launcher/Model/Fallback.swift \
                           Pipcast/Features/Launcher/Model/CommandID.swift \
                           Pipcast/Features/HotKeys/Model/HotKeyAction.swift \
                           Pipcast/Features/QuickActions/Model/QuickAction.swift \
                           Pipcast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Pipcast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Pipcast/Features/Quicklinks/Model/Quicklink.swift \
                           Pipcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Pipcast/Features/SystemActions/Model/SystemAction.swift \
                           Pipcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Pipcast/Features/Snippets/Model/Snippet.swift
run dictionary-test        Pipcast/Features/Dictionary/Model/DictionaryEntry.swift \
                           Pipcast/Features/Dictionary/Model/DictionaryMarkup.swift
run dictation-test         Pipcast/Features/Dictation/Model/DictationModel.swift Pipcast/Features/Dictation/Model/DictationIdleRelease.swift Pipcast/Features/Dictation/Model/DictationTextFormatter.swift
run dictation-field-test   Pipcast/Features/Dictation/Model/DictationModel.swift \
                           Pipcast/Features/Dictation/Model/DictationAudioChunks.swift \
                           Pipcast/Features/Dictation/Model/DictationMode.swift \
                           Pipcast/Features/Dictation/Model/DictationDestination.swift \
                           Pipcast/Features/Dictation/Model/DictationTextFormatter.swift \
                           Pipcast/Features/Dictation/Service/DictationCoordinator.swift \
                           Pipcast/Features/Dictation/Service/DictationInsertionContext.swift \
                           Pipcast/Features/AI/UI/ChatComposerTextView.swift \
                           Pipcast/Features/TextInjection/Service/*.swift \
                           Pipcast/Features/Snippets/Model/*.swift \
                           Pipcast/Platform/AccessibilityText.swift \
                           Pipcast/Platform/PasteboardFiles.swift \
                           Pipcast/Platform/Appearance.swift Pipcast/DesignSystem/Theme.swift
run dictation-volume-test  Pipcast/Features/Dictation/Model/DictationVolumeSnapshot.swift \
                           Pipcast/Features/Dictation/Service/DictationAudioDucker.swift \
                           Pipcast/Platform/AppPaths.swift
run index -O dictation-performance Pipcast/Platform/ProcessExit.swift \
                           Pipcast/Features/Dictation/Model/DictationModel.swift \
                           Pipcast/Features/Dictation/Service/DictationWire.swift
run dictation-inference-test Pipcast/Features/Dictation/Model/DictationAudioChunks.swift \
    Pipcast/Features/Dictation/Service/DictationSpectrum.swift \
    Pipcast/Features/Dictation/Helper/DictationTensor.swift Pipcast/Features/Dictation/Helper/DictationTokenizer.swift \
    Pipcast/Features/Dictation/Helper/DictationMel.swift
run dictation-worker-test  Pipcast/Features/Dictation/Model/DictationModel.swift \
                           Pipcast/Features/Dictation/Model/DictationIdleRelease.swift \
                           Pipcast/Features/Dictation/Service/DictationWire.swift \
                           Pipcast/Features/Dictation/Service/DictationWorker.swift \
                           Pipcast/Features/Dictation/Service/DictationModelStore.swift \
                           Pipcast/Features/Dictation/Service/DictationModelDownloader.swift \
                           Pipcast/Platform/ProcessExit.swift Pipcast/Platform/AppPaths.swift
run hotkey-test            Pipcast/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Pipcast/Features/HotKeys/Model/ModifierKey.swift \
                           Pipcast/Features/HotKeys/Model/ModifierKeyDetector.swift \
                           Pipcast/Features/HotKeys/Model/DoubleTapDetector.swift \
                           Pipcast/Features/HotKeys/Model/HotKeyBinding.swift \
                           Pipcast/Features/HotKeys/Model/HotKeySpelling.swift \
                           Pipcast/Features/HotKeys/Model/HyperKey.swift \
                           Pipcast/Features/HotKeys/Model/HIDKeyMapping.swift \
                           Pipcast/Platform/ASCIIKeyboardLayout.swift \
                           Pipcast/Features/HotKeys/Service/KeyShortcut.swift \
                           Pipcast/Features/HotKeys/Model/HotKeyAction.swift \
                           Pipcast/Features/QuickActions/Model/QuickAction.swift \
                           Pipcast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Pipcast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Pipcast/Features/Launcher/Model/CommandID.swift \
                           Pipcast/Features/Quicklinks/Model/Quicklink.swift \
                           Pipcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Pipcast/Features/SystemActions/Model/SystemAction.swift \
                           Pipcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Pipcast/Features/Snippets/Model/Snippet.swift
run callout-test          Pipcast/Platform/Appearance.swift \
                           Pipcast/DesignSystem/Theme.swift \
                           Pipcast/DesignSystem/InterfaceMetrics.swift \
                           Pipcast/Features/HotKeys/UI/CalloutPlacement.swift
run icon-cache-test        Pipcast/Platform/Appearance.swift \
                           Pipcast/Platform/Images/IconCache.swift
run entry-icon-test        Pipcast/Platform/Appearance.swift \
                           Pipcast/Platform/Images/IconCache.swift \
                           Pipcast/Platform/Images/FileIconStamp.swift
run ext-icon-test          Pipcast/Platform/Appearance.swift \
                           Pipcast/Platform/AppDisplayName.swift \
                           Pipcast/Platform/Images/IconCache.swift \
                           Pipcast/Platform/Compression/Zlib.swift \
                           Pipcast/DesignSystem/Theme.swift \
                           Pipcast/DesignSystem/InterfaceMetrics.swift \
                           Pipcast/Features/Extensions/Model/ExtensionBootConfig.swift \
                           Pipcast/Features/Extensions/Model/ExtensionLaunchType.swift \
                           Pipcast/Features/Extensions/Model/ExtensionManifest.swift \
                           Pipcast/Features/Extensions/Model/ExtensionRefreshPolicy.swift \
                           Pipcast/Features/Extensions/Model/ExtensionRefreshState.swift \
                           Pipcast/Features/Extensions/Model/RenderNode.swift \
                           Pipcast/Features/Extensions/Service/ExtensionCatalog.swift \
                           Pipcast/Features/Extensions/Service/ExtensionFetcher.swift \
                           Pipcast/Platform/ProcessExit.swift \
                           Pipcast/Features/Extensions/Service/ExtensionNodeShims.swift \
                           Pipcast/Features/Extensions/Service/ExtensionRuntime.swift \
                           Pipcast/Features/Extensions/Service/ExtensionIconCache.swift \
                           Pipcast/Features/Extensions/UI/ExtensionAnimatedImage.swift \
                           Pipcast/Features/Extensions/UI/ExtensionImage.swift \
                           Pipcast/Features/Clipboard/Model/ColorValue.swift \
                           Pipcast/Features/Clipboard/Model/ColorSpaces.swift
run system-action-test     Pipcast/Features/SystemActions/Model/SystemAction.swift
run microphone-mute-test   Pipcast/Features/SystemActions/Service/SystemActionFailure.swift \
                           Pipcast/Features/SystemActions/Service/SystemActionRunner+Microphone.swift
run volume-test            Pipcast/Features/SystemActions/Model/VolumeLevel.swift
run window-command-test    Pipcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Pipcast/Features/WindowManagement/Model/WindowCycle.swift \
                           Pipcast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Pipcast/Features/WindowManagement/Model/WindowActionMemory.swift
run window-preset-test     Pipcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Pipcast/Features/WindowManagement/Model/WindowShortcutPreset.swift \
                           Pipcast/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Pipcast/Features/HotKeys/Model/ModifierKey.swift \
                           Pipcast/Features/HotKeys/Model/HotKeyBinding.swift \
                           Pipcast/Features/HotKeys/Model/HyperKey.swift \
                           Pipcast/Features/HotKeys/Model/HIDKeyMapping.swift \
                           Pipcast/Platform/ASCIIKeyboardLayout.swift \
                           Pipcast/Features/HotKeys/Service/KeyShortcut.swift
run space-gesture-test     Pipcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Pipcast/Features/WindowManagement/Model/SpaceGesture.swift
run window-layout-test     Pipcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Pipcast/Features/WindowManagement/Model/WindowCycle.swift \
                           Pipcast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Pipcast/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Pipcast/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Pipcast/Features/WindowManagement/Model/WindowLayout.swift \
                           Pipcast/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Pipcast/Features/WindowManagement/Model/WindowLayoutPlan.swift \
                           Pipcast/Features/WindowManagement/Model/WindowLayoutStore.swift \
                           Pipcast/Features/WindowManagement/Model/CustomWindowSize.swift \
                           Pipcast/Features/WindowManagement/Model/CustomWindowSizeStore.swift
run window-room-test       Pipcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Pipcast/Features/WindowManagement/Model/WindowCycle.swift \
                           Pipcast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Pipcast/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Pipcast/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Pipcast/Features/WindowManagement/Model/WindowLayout.swift \
                           Pipcast/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Pipcast/Features/WindowManagement/Model/WindowLayoutPlan.swift \
                           Pipcast/Features/WindowManagement/Model/RoomLayoutKind.swift \
                           Pipcast/Features/WindowManagement/Model/RoomLayoutEngine.swift \
                           Pipcast/Features/WindowManagement/Model/RoomGrid.swift \
                           Pipcast/Features/WindowManagement/Model/RoomWindow.swift \
                           Pipcast/Features/WindowManagement/Model/Room.swift \
                           Pipcast/Features/WindowManagement/Model/RoomWindowMatcher.swift \
                           Pipcast/Features/WindowManagement/Model/RoomParking.swift \
                           Pipcast/Features/WindowManagement/Model/RoomPlan.swift \
                           Pipcast/Features/WindowManagement/Model/RoomArrangement.swift \
                           Pipcast/Features/WindowManagement/Model/RoomStore.swift \
                           Pipcast/Features/WindowManagement/Model/RoomMinimumSizeStore.swift \
                           Pipcast/Features/WindowManagement/Model/RoomParkingLedger.swift
run window-file-test       Pipcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Pipcast/Features/WindowManagement/Model/WindowCycle.swift \
                           Pipcast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Pipcast/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Pipcast/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Pipcast/Features/WindowManagement/Model/WindowLayout.swift \
                           Pipcast/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Pipcast/Features/WindowManagement/Model/CustomWindowSize.swift \
                           Pipcast/Features/WindowManagement/Model/Room.swift \
                           Pipcast/Features/WindowManagement/Model/RoomWindow.swift \
                           Pipcast/Features/WindowManagement/Model/RoomLayoutKind.swift \
                           Pipcast/Features/WindowManagement/Model/RoomGrid.swift \
                           Pipcast/Features/WindowManagement/Model/RoomLayoutEngine.swift \
                           Pipcast/Features/WindowManagement/Model/WindowManagementFileFormat.swift \
                           Pipcast/Features/Settings/Model/SettingsFileJSON.swift \
                           Pipcast/Features/Settings/Model/SettingsFileIdentity.swift
run custom-command-test    Pipcast/Platform/PseudoTerminal.swift \
                           Pipcast/Platform/ProcessExit.swift \
                           Pipcast/Features/CustomCommands/Model/CustomCommand.swift \
                           Pipcast/Features/CustomCommands/Model/RaycastScriptImport.swift \
                           Pipcast/Features/CustomCommands/UI/CustomCommandEditorSession.swift \
                           Pipcast/Features/CustomCommands/Service/ShellCommandRunner.swift
run custom-command-list-test Pipcast/Features/CustomCommands/Model/CustomCommand.swift \
                             Pipcast/Features/CustomCommands/UI/CustomCommandListScreen.swift
run uninstall-test         Pipcast/Features/Uninstall/Model/UninstallTarget.swift \
                           Pipcast/Features/Uninstall/Model/UninstallSearchRoot.swift \
                           Pipcast/Features/Uninstall/Model/UninstallRules.swift \
                           Pipcast/Features/Uninstall/Model/UninstallProtection.swift \
                           Pipcast/Features/Uninstall/Model/UninstallPlan.swift
run quicklink-test         Pipcast/Features/Quicklinks/Model/Quicklink.swift \
                           Pipcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Pipcast/Features/Quicklinks/Model/QuicklinkStore.swift \
                           Pipcast/Features/Quicklinks/Model/QuicklinkArchive.swift \
                           Pipcast/Features/Quicklinks/Model/RaycastQuicklinkImport.swift \
                           Pipcast/Features/Quicklinks/UI/QuicklinkEditorSession.swift
run quicklink-coordinator-test Pipcast/Features/Quicklinks/Model/Quicklink.swift \
                           Pipcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Pipcast/Features/Quicklinks/Model/QuicklinkStore.swift \
                           Pipcast/Features/Quicklinks/Model/QuicklinkArchive.swift \
                           Pipcast/Features/Quicklinks/UI/QuicklinkCoordinator.swift \
                           Pipcast/Features/Quicklinks/UI/QuicklinkEditorSession.swift \
                           Pipcast/Features/Quicklinks/UI/QuicklinkArgumentsAccessory.swift \
                           Pipcast/Features/Snippets/Model/Snippet.swift \
                           Pipcast/Features/Snippets/Model/SnippetTemplateEngine.swift
run slow snippets-test     Pipcast/Platform/NotificationToken.swift \
                           Pipcast/Platform/HealthTicker.swift \
                           Pipcast/Platform/AccessibilityText.swift \
                           Pipcast/Features/Snippets/Model/*.swift \
                           Pipcast/Features/Snippets/Service/*.swift \
                           Pipcast/Features/Snippets/UI/SnippetEditorSession.swift \
                           Pipcast/Features/TextInjection/Service/*.swift
run notes-test             Pipcast/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Pipcast/Features/Notes/Model/*.swift \
                           Pipcast/Features/Notes/Service/*.swift
run notes-editor-test      Pipcast/Platform/Signposts.swift \
                           Pipcast/Platform/Appearance.swift \
                           Pipcast/DesignSystem/Theme.swift \
                           Pipcast/DesignSystem/InterfaceMetrics.swift \
                           Pipcast/Platform/NotificationToken.swift \
                           Pipcast/Features/TextInjection/Service/InjectableTextView.swift \
                           Pipcast/Features/Notes/Model/NoteDocument.swift \
                           Pipcast/Features/Notes/Model/NoteMarkdown.swift \
                           Pipcast/Features/Notes/Model/NoteMarkdownParser.swift \
                           Pipcast/Features/Notes/Model/NoteInlineScanner.swift \
                           Pipcast/Features/Notes/Model/NoteEditPlan.swift \
                           Pipcast/Features/Notes/Model/NoteEditAction.swift \
                           Pipcast/Features/Notes/Model/NoteFormatting.swift \
                           Pipcast/Features/Notes/Model/NoteMarkdownEditing.swift \
                           Pipcast/Features/Notes/Model/NoteRevealPolicy.swift \
                           Pipcast/Features/Notes/UI/NoteMarkdownTypography.swift \
                           Pipcast/Features/Notes/UI/NoteBlockDecoration.swift \
                           Pipcast/Features/Notes/UI/NoteMarkdownStyler.swift \
                           Pipcast/Features/Notes/UI/NoteMarkdownRenderer.swift \
                           Pipcast/Features/Notes/UI/NoteCheckboxGeometry.swift \
                           Pipcast/Features/Notes/UI/NoteBlockLayoutFragment.swift \
                           Pipcast/Features/Notes/UI/NoteLayoutFragmentProvider.swift \
                           Pipcast/Features/Notes/UI/NoteTextViewEditing.swift \
                           Pipcast/Features/Notes/UI/NoteTextView.swift \
                           Pipcast/Features/Notes/UI/NoteEditorView.swift
run -O index notes-editor-performance \
                           Pipcast/Platform/Signposts.swift \
                           Pipcast/Platform/Appearance.swift \
                           Pipcast/DesignSystem/Theme.swift \
                           Pipcast/DesignSystem/InterfaceMetrics.swift \
                           Pipcast/Platform/NotificationToken.swift \
                           Pipcast/Features/TextInjection/Service/InjectableTextView.swift \
                           Pipcast/Features/Notes/Model/NoteDocument.swift \
                           Pipcast/Features/Notes/Model/NoteMarkdown.swift \
                           Pipcast/Features/Notes/Model/NoteMarkdownParser.swift \
                           Pipcast/Features/Notes/Model/NoteInlineScanner.swift \
                           Pipcast/Features/Notes/Model/NoteEditPlan.swift \
                           Pipcast/Features/Notes/Model/NoteEditAction.swift \
                           Pipcast/Features/Notes/Model/NoteFormatting.swift \
                           Pipcast/Features/Notes/Model/NoteMarkdownEditing.swift \
                           Pipcast/Features/Notes/Model/NoteRevealPolicy.swift \
                           Pipcast/Features/Notes/UI/NoteMarkdownTypography.swift \
                           Pipcast/Features/Notes/UI/NoteBlockDecoration.swift \
                           Pipcast/Features/Notes/UI/NoteMarkdownStyler.swift \
                           Pipcast/Features/Notes/UI/NoteMarkdownRenderer.swift \
                           Pipcast/Features/Notes/UI/NoteCheckboxGeometry.swift \
                           Pipcast/Features/Notes/UI/NoteBlockLayoutFragment.swift \
                           Pipcast/Features/Notes/UI/NoteLayoutFragmentProvider.swift \
                           Pipcast/Features/Notes/UI/NoteTextViewEditing.swift \
                           Pipcast/Features/Notes/UI/NoteTextView.swift \
                           Pipcast/Features/Notes/UI/NoteEditorView.swift
run slow -O raycast-test   Pipcast/Features/Backup/Model/RaycastImportError.swift \
                           Pipcast/Features/Backup/Service/RaycastDecoder.swift \
                           Pipcast/Features/Backup/Service/Scrypt.swift \
                           Pipcast/Platform/Compression/Zlib.swift \
                           Pipcast/Features/Clipboard/Model/RaycastClipboardImport.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Pipcast/Platform/Images/ImageDerivative.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Pipcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Pipcast/Features/Clipboard/Model/ColorValue.swift \
                           Pipcast/Features/Clipboard/Model/ColorFormat.swift \
                           Pipcast/Features/Clipboard/Model/ColorSpaces.swift
run settings-backup-test   Pipcast/Features/Settings/AppSettingsKey.swift \
                           Pipcast/Features/Backup/Model/SettingsBackupCoverage.swift
run hyper-key-test         Pipcast/Features/HotKeys/Model/HIDKeyMapping.swift \
                           Pipcast/Features/HotKeys/Model/HyperKeyConflictPolicy.swift \
                           Pipcast/Features/HotKeys/Service/KeyboardRemapper.swift \
                           Tests/hyper-key-fixtures.swift
run hotkey-dispatch-test   Pipcast/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Pipcast/Features/HotKeys/Model/ModifierKey.swift \
                           Pipcast/Features/HotKeys/Model/HotKeyBinding.swift \
                           Pipcast/Features/HotKeys/Model/HyperKey.swift \
                           Pipcast/Features/HotKeys/Model/HIDKeyMapping.swift \
                           Pipcast/Features/HotKeys/Model/HotKeyAction.swift \
                           Pipcast/Features/HotKeys/Service/KeyShortcut.swift \
                           Pipcast/Features/HotKeys/Service/HotKeyManager.swift \
                           Pipcast/Platform/ASCIIKeyboardLayout.swift \
                           Tests/hotkey-dispatch-fixtures.swift
run settings-file-test     Pipcast/Features/Settings/Model/*.swift \
                           Pipcast/Features/Settings/Service/SettingsFileMonitor.swift \
                           Pipcast/Features/Settings/Service/SettingsFileRepository.swift \
                           Pipcast/Platform/AppPaths.swift
run backup-archive-test    Pipcast/Platform/AppPaths.swift \
                           Pipcast/Features/Backup/Model/BackupArchive.swift \
                           Pipcast/Features/Backup/Model/BackupBundle.swift \
                           Pipcast/Features/Backup/Model/BackupCategory.swift \
                           Pipcast/Features/Backup/Model/BackupClipboardItem.swift \
                           Pipcast/Features/Backup/Model/BackupManifest.swift \
                           Pipcast/Features/Backup/Service/BackupStaging.swift
E=Pipcast/Features/Extensions
run symbols-test           $E/Service/SymbolCatalog.swift
run ext-cleanup-test       $E/Service/ExtensionCleanup.swift \
                           $E/Service/ExtensionCatalog.swift \
                           Pipcast/Platform/AppDisplayName.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-refresh-test       $E/Model/ExtensionManifest.swift \
                           Pipcast/Platform/AppDisplayName.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-metadata-test      $E/Model/ExtensionCommandMetadata.swift \
                           $E/Model/ExtensionMenuBarSnapshot.swift \
                           $E/Service/ExtensionCommandMetadataStore.swift
run ext-version-test       $E/Model/ExtensionListing.swift \
                           $E/Service/ExtensionVersionStore.swift
run ext-store-test         $E/Model/ExtensionGitHubSource.swift \
                           $E/Model/ExtensionListing.swift \
                           $E/Model/ExtensionPackageManager.swift \
                           $E/Model/ExtensionStoreResponse.swift
run ext-form-test          $E/Model/ExtensionFormMetrics.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/UI/ExtensionFormKey.swift \
                           $E/Model/ExtensionDateExpression.swift \
                           $E/UI/ExtensionListKey.swift \
                           Tests/ext-list-key-test.swift
run ext-image-size-test   $E/Model/ExtensionImageSize.swift
run ext-accessory-test     $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionStorage.swift
run ext-sign-in-test       -parse-as-library $E/Service/ExtensionSignInSession.swift
run slow ext-test          -parse-as-library \
                           Tests/ext-menu-bar-test.swift \
                           Tests/ext-fetch-test.swift \
                           $E/Model/ExtensionLaunchError.swift \
                           $E/Model/ExtensionMenuBarSnapshot.swift \
                           $E/Service/ExtensionStorage.swift \
                           $E/Service/ExtensionMenuBarManager.swift \
                           $E/Model/ExtensionCommandMetadata.swift \
                           $E/Service/ExtensionCommandMetadataStore.swift \
                           $E/UI/ExtensionMenuBarController.swift \
                           $E/UI/ExtensionMenuBarImage.swift \
                           Pipcast/Platform/Appearance.swift \
                           Pipcast/Platform/AppDisplayName.swift \
                           Pipcast/Platform/Images/IconCache.swift \
                           Pipcast/DesignSystem/Theme.swift \
                           Pipcast/DesignSystem/InterfaceMetrics.swift \
                           $E/Model/ExtensionBootConfig.swift \
                           $E/Model/ExtensionDeepLink.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/Model/ExtensionGridLayout.swift \
                           $E/Model/ExtensionSearchState.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift \
                           $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionCatalog.swift \
                           $E/Service/ExtensionFetcher.swift \
                           Pipcast/Platform/ProcessExit.swift \
                           $E/Service/ExtensionIconCache.swift \
                           $E/Service/ExtensionNodeShims.swift \
                           $E/Service/ExtensionRuntime.swift \
                           $E/Service/ExtensionNameResolver.swift \
                           $E/Service/ExtensionWebSocketBridge.swift \
                           $E/UI/ExtensionAnimatedImage.swift \
                           $E/UI/ExtensionImage.swift \
                           $E/UI/ExtensionScreen.swift \
                           $L/SearchRelevance.swift \
                           Pipcast/Platform/Compression/Zlib.swift \
                           Pipcast/Features/Clipboard/Model/ColorValue.swift \
                           Pipcast/Features/Clipboard/Model/ColorSpaces.swift
run settings-history-test  Pipcast/Features/Settings/SettingsTab.swift \
                           Pipcast/Features/Settings/SettingsHistory.swift \
                           Pipcast/Features/Settings/SettingsAnchor.swift \
                           Pipcast/Features/Settings/SettingsNavigationState.swift \
                           Pipcast/Features/Settings/SettingsSearchCatalog.swift \
                           $L/SearchRelevance.swift
run updates-test           Pipcast/Features/Updates/Model/*.swift \
                           Pipcast/Features/Updates/Service/BundleSignature.swift
run update-check-test      Pipcast/Features/Updates/Model/*.swift \
                           Pipcast/Features/Updates/Service/UpdateCheckStore.swift \
                           Pipcast/Platform/AppPaths.swift
run support-test           Pipcast/Features/Support/Model/*.swift
run ai-provider-test       Pipcast/Features/Settings/AppSettingsKey.swift \
                           Pipcast/Features/AI/Model/*.swift \
                           Pipcast/Features/AI/Settings/AISettingsStore.swift
run ai-chat-test           Pipcast/Features/AI/Model/AIRequest.swift \
                           Pipcast/Features/AI/Model/AIConnection.swift \
                           Pipcast/Features/AI/Model/AIConversationOpenPolicy.swift \
                           Pipcast/Features/AI/Model/AppleIntelligence.swift \
                           Pipcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Pipcast/Features/AI/Model/AIRetention.swift \
                           Pipcast/Features/AI/Model/AITool.swift \
                           Pipcast/Features/AI/Model/JSONValue.swift \
                           Pipcast/Features/AI/Model/ChatMessage.swift \
                           Pipcast/Features/AI/Model/ChatSession.swift \
                           Pipcast/Features/AI/Model/ChatChoices.swift \
                           Pipcast/Features/AI/Model/ChatReferences.swift \
                           Pipcast/Features/AI/Model/ChatTitle.swift \
                           Pipcast/Features/AI/Model/ChatFind.swift \
                           Pipcast/Features/AI/Model/ChatCitations.swift \
                           Pipcast/Features/AI/Model/ChatToolScope.swift \
                           Pipcast/Features/AI/Model/MarkdownBlock.swift \
                           Pipcast/Features/AI/Model/MarkdownMath.swift \
                           Pipcast/Features/AI/Model/MathFormula.swift \
                           Pipcast/Features/AI/Model/MathNode.swift \
                           Pipcast/Features/AI/Model/MathSymbolCatalog.swift \
                           Pipcast/Features/AI/Service/AIProvider.swift \
                           Pipcast/Features/AI/Service/ChatHistoryStore.swift \
                           Pipcast/Features/AI/Service/AIToolLoopProvider.swift \
                           Pipcast/Features/AI/UI/AIChatState.swift \
                           Pipcast/Features/AI/UI/AIChatSurfacesState.swift \
                           Pipcast/Features/AI/UI/ChatFindState.swift
run chat-markdown-test     Pipcast/Platform/Appearance.swift \
                           Pipcast/DesignSystem/Theme.swift \
                           Pipcast/DesignSystem/InterfaceMetrics.swift \
                           Pipcast/Features/Settings/InterfaceSize.swift \
                           Pipcast/Features/AI/Model/AIRequest.swift \
                           Pipcast/Features/AI/Model/AITool.swift \
                           Pipcast/Features/AI/Model/JSONValue.swift \
                           Pipcast/Features/AI/Model/ChatMessage.swift \
                           Pipcast/Features/AI/Model/ChatChoices.swift \
                           Pipcast/Features/AI/Model/ChatReferences.swift \
                           Pipcast/Features/AI/Model/ChatCitations.swift \
                           Pipcast/Features/AI/Model/ChatFind.swift \
                           Pipcast/Features/AI/Model/MarkdownBlock.swift \
                           Pipcast/Features/AI/Model/MarkdownMath.swift \
                           Pipcast/Features/AI/Model/MathFormula.swift \
                           Pipcast/Features/AI/Model/MathNode.swift \
                           Pipcast/Features/AI/Model/MathSymbolCatalog.swift \
                           Pipcast/Features/AI/Model/SyntaxGrammar.swift \
                           Pipcast/Features/AI/Model/SyntaxHighlighter.swift \
                           Pipcast/Features/AI/Model/SyntaxStructuredLexers.swift \
                           Pipcast/Features/AI/UI/ChatTextHighlight.swift \
                           Pipcast/Features/AI/UI/ChatMarkdownRenderer.swift \
                           Pipcast/Features/AI/UI/MathAttachmentCell.swift \
                           Pipcast/Features/AI/UI/MathBox.swift \
                           Pipcast/Features/AI/UI/MathFont.swift \
                           Pipcast/Features/AI/UI/MathLayoutEngine.swift
run syntax-highlight-test  Pipcast/Features/AI/Model/SyntaxGrammar.swift \
                           Pipcast/Features/AI/Model/SyntaxHighlighter.swift \
                           Pipcast/Features/AI/Model/SyntaxStructuredLexers.swift
run mcp-test               Pipcast/Features/Settings/AppSettingsKey.swift \
                           Pipcast/Features/AI/Model/AIConnection.swift \
                           Pipcast/Features/AI/Model/AppleIntelligence.swift \
                           Pipcast/Features/AI/Model/AITool.swift \
                           Pipcast/Features/AI/Model/AIToolServer.swift \
                           Pipcast/Features/AI/Model/JSONValue.swift \
                           Pipcast/Features/MCP/Model/*.swift \
                           Pipcast/Features/MCP/Settings/MCPSettingsStore.swift
run -O text-diff-test      Pipcast/Features/QuickActions/Model/TextDiffEngine.swift
run index text-diff-performance Pipcast/Features/QuickActions/Model/TextDiffEngine.swift
run quick-action-test      Pipcast/Features/Settings/AppSettingsKey.swift \
                           Pipcast/Features/AI/Model/AIConnection.swift \
                           Pipcast/Features/AI/Model/AppleIntelligence.swift \
                           Pipcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Pipcast/Features/AI/Model/InstalledAI.swift \
                           Pipcast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Pipcast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Pipcast/Features/QuickActions/Model/CustomQuickActionStore.swift \
                           Pipcast/Features/QuickActions/Model/QuickAction.swift \
                           Pipcast/Features/QuickActions/Model/QuickActionFailure.swift \
                           Pipcast/Features/QuickActions/Model/QuickActionPrompt.swift \
                           Pipcast/Features/QuickActions/Model/QuickActionSettings.swift \
                           Pipcast/Features/QuickActions/Settings/QuickActionSettingsStore.swift
run apple-intelligence-test Pipcast/Features/Settings/AppSettingsKey.swift \
                           Pipcast/Features/AI/Model/*.swift \
                           Pipcast/Features/AI/Service/AIProvider.swift \
                           Pipcast/Features/AI/Service/AppleIntelligenceProvider.swift
run mcp-oauth-test         Pipcast/Platform/ExecutableLocator.swift \
                           Pipcast/Platform/ProcessExit.swift \
                           Pipcast/Platform/KeychainSecretStore.swift \
                           Pipcast/Features/Settings/AppSettingsKey.swift \
                           Pipcast/Features/AI/Model/AIConnection.swift \
                           Pipcast/Features/AI/Model/AppleIntelligence.swift \
                           Pipcast/Features/AI/Model/AITool.swift \
                           Pipcast/Features/AI/Model/AIToolServer.swift \
                           Pipcast/Features/AI/Model/AIStreamDecoder.swift \
                           Pipcast/Features/AI/Model/AIProviderFailure.swift \
                           Pipcast/Features/AI/Model/AIThinkTagDecoder.swift \
                           Pipcast/Features/AI/Model/AIRequest.swift \
                           Pipcast/Features/AI/Model/JSONValue.swift \
                           Pipcast/Features/MCP/Model/*.swift \
                           Pipcast/Features/MCP/Service/*.swift
run slow mcp-stdio-test    Pipcast/Platform/ExecutableLocator.swift \
                           Pipcast/Platform/ProcessExit.swift \
                           Pipcast/Platform/KeychainSecretStore.swift \
                           Pipcast/Features/Settings/AppSettingsKey.swift \
                           Pipcast/Features/AI/Model/AIConnection.swift \
                           Pipcast/Features/AI/Model/AppleIntelligence.swift \
                           Pipcast/Features/AI/Model/AITool.swift \
                           Pipcast/Features/AI/Model/AIToolServer.swift \
                           Pipcast/Features/AI/Model/AIStreamDecoder.swift \
                           Pipcast/Features/AI/Model/AIProviderFailure.swift \
                           Pipcast/Features/AI/Model/AIThinkTagDecoder.swift \
                           Pipcast/Features/AI/Model/AIRequest.swift \
                           Pipcast/Features/AI/Model/JSONValue.swift \
                           Pipcast/Features/MCP/Model/*.swift \
                           Pipcast/Features/MCP/Service/*.swift

if [ "$emit_db" -eq 1 ]; then
    printf ']\n' >> "$DB"
    [ -f .compile ] || echo '[]' > .compile
    node -e '
const fs = require("node:fs");
const [comp, db] = process.argv.slice(1);
const existing = JSON.parse(fs.readFileSync(comp, "utf8"));
const harnesses = JSON.parse(fs.readFileSync(db, "utf8"));
const kept = existing.filter((e) => !(e.files || []).some((f) => f.includes("/Tests/")));
fs.writeFileSync(comp, JSON.stringify([...kept, ...harnesses], null, 1));
console.log(harnesses.length + " harness entries indexed into .compile");
' .compile "$DB"
    exit 0
fi

if [ "$ran" -eq 0 ]; then
    echo "No harness named '$only'." >&2
    exit 2
fi

# `sort -s` is stable, so the slow harnesses lead and everything else keeps its declaration order.
JOBS="${PIPCAST_TEST_JOBS:-4}"
export PIPCAST_TEST_TIMEOUT="${PIPCAST_TEST_TIMEOUT:-300}"
started=$SECONDS

# Numbers each result, and names what is still running whenever the output goes quiet.
report() {
    local finished=0 line asked running file
    while :; do
        asked=$SECONDS
        if IFS= read -r -t 15 line; then
            case "$line" in "dispatch "*) return "${line#dispatch }";; esac
            finished=$((finished + 1))
            printf '[%*d/%d] %s\n' "${#ran}" "$finished" "$ran" "$line"
            continue
        fi
        # Bash 3.2 returns the same status for a timeout and EOF; only EOF comes back at once.
        if [ $((SECONDS - asked)) -lt 10 ]; then return 1; fi
        running=""
        for file in "$BIN"/*.running; do
            [ -e "$file" ] && running="$running $(basename "$file" .running)"
        done
        printf '        \033[2mstill running after %ds:%s\033[0m\n' $((SECONDS - started)) "$running"
    done
}

# Without this the suite reports "all passed" whenever dispatch itself dies and no harness ran.
if ! { sort -s -k1,1n "$QUEUE" | cut -d' ' -f2- | xargs -P "$JOBS" -L1 "$SELF" --exec; echo "dispatch $?"; } | report; then
    echo "harness dispatch failed; no result below can be trusted" >&2
    exit 1
fi
elapsed=$((SECONDS - started))

# A compiler diagnostic is far longer than PIPE_BUF, so the workers log it and it is replayed here.
while read -r _ name _; do
    if [ -f "$BIN/$name.failed" ]; then failed+=("$name"); fi
done < "$QUEUE"

if [ ${#failed[@]} -gt 0 ]; then
    for name in "${failed[@]}"; do
        printf '\n\033[31m--- %s ---\033[0m\n' "$name"
        cat "$BIN/$name.log"
    done
    printf '\n\033[31mFAILED\033[0m  %d of %d harness(es) failed in %ds: %s\n' \
        "${#failed[@]}" "$ran" "$elapsed" "${failed[*]}" >&2
    exit 1
fi
printf '\n\033[32mPASSED\033[0m  All %d harness(es) passed in %ds.\n' "$ran" "$elapsed"
