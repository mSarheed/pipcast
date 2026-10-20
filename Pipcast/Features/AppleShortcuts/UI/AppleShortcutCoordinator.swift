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
    private let icons = AppleShortcutIconStore()
    /// Nil until a read succeeds, so the first one after launch always sweeps.
    @ObservationIgnored private var shortcuts: [AppleShortcut]?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

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
        icons.onChange = { [weak self] in self?.publishEntries() }
    }

    func name(of id: UUID) -> String? {
        shortcuts?.first { $0.id == id }?.name
    }

    // MARK: - Feature presence

    /// Off forgets the library but frees nothing: only a successful read may say what is gone.
    func applyPresence() {
        guard settings.appleShortcutsEnabled else {
            icons.cancel()
            shortcuts = nil
            entries = []
            appIndex.setAppleShortcuts([])
            return
        }
        refresh()
    }

    /// Re-read on every launcher open; the tool answers in milliseconds, so overlaps just drop.
    func refresh(promptingForIcons prompting: Bool = false) {
        guard settings.appleShortcutsEnabled else { return }
        if prompting { icons.queue(.prompt) }
        guard refreshTask == nil else { return }
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
            icons.read(found, AppleShortcutIconStore.Request(sweep: isFirstRead))
        }
    }

    private func publishEntries() {
        entries = (shortcuts ?? []).map { shortcut in
            AppEntry(
                shortcut, applicationURL: Self.applicationURL,
                icon: icons.url(of: shortcut.id))
        }
        appIndex.setAppleShortcuts(entries)
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
