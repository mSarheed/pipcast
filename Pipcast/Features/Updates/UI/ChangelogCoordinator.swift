import AppKit

/// What's New: the bundled changelog as a palette screen, and the one nudge an update earns.
@MainActor
final class ChangelogCoordinator {
    /// Long enough to clear the login rush and the relaunch that delivered the update.
    private static let announcementDelay = Duration.seconds(4)
    /// A busy moment defers the HUD for up to two minutes; past that, the next launch offers it.
    private static let announcementRetry = Duration.seconds(15)
    private static let announcementAttempts = 8

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
            for _ in 0..<Self.announcementAttempts {
                guard let self, store.isAnnouncementDue else { return }
                // The pill is shared: a Quick Action's progress and its Cancel must not be replaced.
                if core.canInterruptUser, !core.isShowingMessage {
                    store.markAnnounced()
                    core.showMessage(
                        "Updated to \(Bundle.main.appDisplayName) \(running) — see what's new",
                        tone: .neutral, onClick: { [weak self] in self?.showChangelog() })
                    return
                }
                try? await Task.sleep(for: Self.announcementRetry)
            }
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
