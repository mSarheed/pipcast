import AppKit

/// Owns the Apple Shortcuts flow: discovery into the launcher slice, and the one run funnel.
@MainActor
@Observable
final class AppleShortcutCoordinator {
    /// A row whose own icon is unread draws the Shortcuts app's, from one cached bitmap.
    static let applicationURL =
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts")
        ?? URL(fileURLWithPath: "/System/Applications/Shortcuts.app")

    /// The discovered library as rows, rebuilt only when the list itself changes.
    private(set) var entries: [AppEntry] = []

    private let settings: AppSettings
    private let appIndex: AppIndex
    private let hotKeys: HotKeyManager
    private let favorites: FavoritesStore
    private let visibility: VisibilityStore
    private let ranking: LauncherRankingStore
    private let aliases: AliasStore
    private let paletteCoordinator: PaletteCoordinator
    private unowned let core: AppCore
    private let iconCache = AppleShortcutIconCache()
    /// Nil until a read succeeds, so the first one after launch always sweeps.
    @ObservationIgnored private var shortcuts: [AppleShortcut]?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Nil until this launch has scanned the icon folder.
    @ObservationIgnored private var icons: [UUID: AppleShortcutIconFile]?
    @ObservationIgnored private var iconTask: Task<Void, Never>?
    /// Only the Settings pane may raise the Automation prompt, so the launcher stops at a refusal.
    @ObservationIgnored private var iconReadRefused = false

    init(
        settings: AppSettings, appIndex: AppIndex, hotKeys: HotKeyManager,
        favorites: FavoritesStore, visibility: VisibilityStore, ranking: LauncherRankingStore,
        aliases: AliasStore, paletteCoordinator: PaletteCoordinator, core: AppCore
    ) {
        self.settings = settings
        self.appIndex = appIndex
        self.hotKeys = hotKeys
        self.favorites = favorites
        self.visibility = visibility
        self.ranking = ranking
        self.aliases = aliases
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    func name(of id: UUID) -> String? {
        shortcuts?.first { $0.id == id }?.name
    }

    // MARK: - Feature presence

    /// Off forgets the library but frees nothing: only a successful read may say what is gone.
    func applyPresence() {
        guard settings.appleShortcutsEnabled else {
            iconTask?.cancel()
            shortcuts = nil
            entries = []
            appIndex.setAppleShortcuts([])
            return
        }
        refresh()
    }

    /// Re-read on every launcher open; the tool answers in milliseconds, so overlaps just drop.
    func refresh(promptingForIcons prompting: Bool = false) {
        guard settings.appleShortcutsEnabled, refreshTask == nil else { return }
        refreshTask = Task {
            let found = try? await AppleShortcutRunner.list()
            refreshTask = nil
            // A failed read keeps the last good library, and with it every alias and binding.
            guard let found, settings.appleShortcutsEnabled else { return }
            let isFirstRead = shortcuts == nil
            if found != shortcuts {
                shortcuts = found
                publishEntries()
                removeReferences(toShortcutsMissingFrom: found)
            }
            refreshIcons(sweep: isFirstRead || prompting, prompting: prompting)
        }
    }

    private func publishEntries() {
        entries = (shortcuts ?? []).map { shortcut in
            AppEntry(
                shortcut, applicationURL: Self.applicationURL,
                icon: icons?[shortcut.id].map(iconCache.url(of:)))
        }
        appIndex.setAppleShortcuts(entries)
    }

    // MARK: - Icons

    /// A sweep re-reads every icon; otherwise only a shortcut with none yet costs an Apple event.
    private func refreshIcons(sweep: Bool, prompting: Bool) {
        guard let live = shortcuts, !live.isEmpty, iconTask == nil else { return }
        if let icons, AppleShortcutIconFile.pending(live: live, cached: icons, sweep: sweep).isEmpty {
            return
        }
        guard prompting || !iconReadRefused else { return }
        iconTask = Task {
            defer { iconTask = nil }
            var scanned = icons ?? [:]
            if icons == nil {
                scanned = await iconCache.scan(live: live)
                guard !Task.isCancelled else { return }
                applyIcons(scanned)
            }
            let pending = AppleShortcutIconFile.pending(live: live, cached: scanned, sweep: sweep)
            guard !pending.isEmpty else { return }
            let canRead = await AppleShortcutIconProvider.canRead(prompting: prompting)
            guard !Task.isCancelled else { return }
            iconReadRefused = !canRead
            guard canRead else { return }
            let fetched = await iconCache.fetch(pending, cached: scanned)
            guard !Task.isCancelled, !fetched.isEmpty else { return }
            applyIcons((icons ?? [:]).merging(fetched) { $1 })
            await iconCache.remove(fetched.keys.compactMap { scanned[$0] })
        }
    }

    private func applyIcons(_ updated: [UUID: AppleShortcutIconFile]) {
        guard updated != icons else { return }
        icons = updated
        publishEntries()
    }

    /// Frees what a deleted shortcut held, including one deleted while Pipcast wasn't running.
    private func removeReferences(toShortcutsMissingFrom live: [AppleShortcut]) {
        let keys =
            Array(aliases.aliases.keys) + favorites.keys + visibility.hiddenItemKeys
            + ranking.visits.keys
        let bound = Set(hotKeys.boundAppleShortcutIDs)
        let stale = AppleShortcut.staleIDs(referencedBy: keys, bound: bound, live: live)
        guard !stale.isEmpty else { return }
        for id in stale.intersection(bound) {
            let action = HotKeyAction.appleShortcut(id: id)
            if hotKeys.recordingAction == action { hotKeys.recordingAction = nil }
            hotKeys.setBinding(nil, for: action)
        }
        let entryIDs = Set(stale.map(AppleShortcut.entryID(for:)))
        favorites.remove(keys: entryIDs)
        visibility.removeItemKeys(entryIDs)
        aliases.removeKeys(entryIDs)
        for entryID in entryIDs {
            ranking.reset(itemKey: entryID)
        }
    }

    // MARK: - Running

    /// The one funnel for a launcher row and a global shortcut, so the switch can't be bypassed.
    func run(id: UUID) {
        guard settings.appleShortcutsEnabled else { return }
        // Focus goes back first: a shortcut usually acts on whatever the user was in.
        if paletteCoordinator.isVisible { paletteCoordinator.hidePalette() }
        let name = name(of: id) ?? String(localized: "Shortcut")
        Task {
            do throws(AppleShortcutRunner.Failure) {
                try await AppleShortcutRunner.run(id: id)
            } catch {
                await core.showNotice(
                    title: String(localized: "Couldn’t Run \(name)"), message: error.localizedDescription,
                    symbol: AppleShortcut.sfSymbol, tone: .danger)
            }
        }
    }

    func openShortcutsApp() {
        AppLauncher.launch(Self.applicationURL)
    }
}
