import AppKit

/// What's New: the bundled changelog as a palette screen, and the one nudge an update earns.
@MainActor
final class ChangelogCoordinator {
    /// Long enough to clear the login rush and the relaunch that delivered the update.
    private static let announcementDelay = Duration.seconds(4)

    private let store: ChangelogStore
    private let paletteCoordinator: PaletteCoordinator
    /// Environment injection and activity reads only — never for state this type owns.
    private unowned let core: AppCore

    init(store: ChangelogStore, paletteCoordinator: PaletteCoordinator, core: AppCore) {
        self.store = store
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    /// Opening the notes is what reads them, so the dot goes with this call.
    func showChangelog() {
        store.markSeen()
        paletteCoordinator.showPalette(mode: .changelog)
    }

    /// The command's path: a second press of its hotkey closes the screen, like every other one.
    func toggleChangelog() {
        store.markSeen()
        paletteCoordinator.togglePalette(mode: .changelog)
    }

    /// Said once per version, after the relaunch an update ends in; the dot outlasts it.
    func announceIfUpdated() {
        guard store.isAnnouncementDue, let running = store.running else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.announcementDelay)
            guard let self, store.isAnnouncementDue, core.canInterruptUser else { return }
            store.markAnnounced()
            core.showMessage(
                "Updated to \(Bundle.main.appDisplayName) \(running) — see what's new",
                tone: .neutral, onClick: { [weak self] in self?.showChangelog() })
        }
    }

    /// A beta's entry is a version with no tag yet, so it falls back to the release list.
    func openRelease(_ entry: Changelog.Entry) {
        let tagged = store.running?.isPrerelease != true || entry.id != store.current?.id
        let path = tagged ? "releases/tag/v\(entry.version)" : "releases"
        guard let url = URL(string: "https://github.com/\(ReleaseFeed.repository)/\(path)") else {
            return
        }
        if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
        NSWorkspace.shared.open(url)
    }
}
