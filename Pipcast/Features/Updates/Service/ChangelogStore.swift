import Foundation

/// The changelog shipped inside this build, and how far the user has caught up with it.
@MainActor
@Observable
final class ChangelogStore {
    let changelog: Changelog
    /// Nil for a build whose marketing version is off-shape; it then reads every entry as history.
    let running: AppVersion?
    /// Drives the dot, which stays until the notes are opened.
    private(set) var hasNews: Bool

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var state: State

    private struct State: Codable {
        var lastSeen: AppVersion?
        /// Separate from `lastSeen`: the HUD is said once, the dot waits to be acted on.
        var lastAnnounced: AppVersion?
    }

    /// `isFirstLaunch` is read before onboarding writes its marker, or every launch looks like one.
    init(
        bundle: Bundle = .main, isFirstLaunch: Bool,
        directory: URL = AppPaths.applicationSupport()
    ) {
        let changelog = Self.load(from: bundle)
        let running = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(AppVersion.init)
        let fileURL = directory.appendingPathComponent("changelog.json")
        let state = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        self.changelog = changelog
        self.running = running
        self.fileURL = fileURL
        self.state = state
        hasNews = running.map {
            changelog.hasNews(for: $0, lastSeen: state.lastSeen, isFirstLaunch: isFirstLaunch)
        } ?? false
        // Recorded now, so the next update has a version to compare against.
        if state.lastSeen == nil, !hasNews { markSeen() }
    }

    var entries: [Changelog.Entry] {
        running.map(changelog.entries(upTo:)) ?? changelog.entries
    }

    /// The entry this build was released as; a beta's is the release it leads to.
    var current: Changelog.Entry? {
        running.flatMap(changelog.entry(for:))
    }

    /// Ordered, not equal: an announcement for a later version also covers a downgraded copy.
    var isAnnouncementDue: Bool {
        guard hasNews, let running else { return false }
        return state.lastAnnounced.map { $0 < running.release } ?? true
    }

    func markAnnounced() {
        guard let running else { return }
        state.lastAnnounced = Self.later(state.lastAnnounced, running.release)
        persist()
    }

    func markSeen() {
        hasNews = false
        guard let running else { return }
        state.lastSeen = Self.later(state.lastSeen, running.release)
        persist()
    }

    /// Only ever forward: reading notes in a downgraded copy must not unread a newer version's.
    private static func later(_ recorded: AppVersion?, _ version: AppVersion) -> AppVersion {
        recorded.map { max($0, version) } ?? version
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The file is copied in by the build, so a missing one is a broken bundle, not a user state.
    private static func load(from bundle: Bundle) -> Changelog {
        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return Changelog(entries: []) }
        return Changelog(markdown: text)
    }
}
