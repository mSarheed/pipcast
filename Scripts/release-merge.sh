#!/bin/bash
set -euo pipefail
ARM_APP="${1:?usage: release-merge.sh <arm64.app> <x86_64.app>}"
INTEL_APP="${2:?usage: release-merge.sh <arm64.app> <x86_64.app>}"
NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ARM_APP/Contents/Info.plist")"
for PLIST in Contents/Info.plist 'Contents/Helpers/Pipcast Dictation.app/Contents/Info.plist'; do
    for KEY in CFBundleIdentifier CFBundleExecutable CFBundleShortVersionString CFBundleVersion; do
        ARM_VALUE="$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$ARM_APP/$PLIST")"
        INTEL_VALUE="$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$INTEL_APP/$PLIST")"
        [ "$ARM_VALUE" = "$INTEL_VALUE" ] || { echo "Mismatched $KEY in $PLIST" >&2; exit 1; }
    done
done
BINARIES=(
    "Contents/MacOS/$NAME"
    Contents/Helpers/ClipboardTextHelper
    Contents/Helpers/FileIndexHelper
    'Contents/Helpers/Pipcast Dictation.app/Contents/MacOS/Pipcast Dictation'
)
for BIN in "${BINARIES[@]}"; do
    [ "$(lipo -archs "$ARM_APP/$BIN")" = arm64 ]
    [ "$(lipo -archs "$INTEL_APP/$BIN")" = x86_64 ]
done
for BIN in "${BINARIES[@]}"; do
    lipo -create "$ARM_APP/$BIN" "$INTEL_APP/$BIN" -output "$ARM_APP/$BIN.universal"
    chmod 755 "$ARM_APP/$BIN.universal"
    mv "$ARM_APP/$BIN.universal" "$ARM_APP/$BIN"
    for ARCH in arm64 x86_64; do lipo "$ARM_APP/$BIN" -verify_arch "$ARCH"; done
done
