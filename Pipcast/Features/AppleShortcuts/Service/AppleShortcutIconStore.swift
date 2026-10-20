import Foundation

/// Each shortcut's own icon file, and when to read it again. docs/features/apple-shortcuts.md#icons
@MainActor
final class AppleShortcutIconStore {
    struct Request: Equatable, Sendable {
        var sweep = false
        /// Only the Settings pane sets it, so the Automation prompt never lands over the palette.
        var prompting = false

        func merged(_ other: Request) -> Request {
            Request(sweep: sweep || other.sweep, prompting: prompting || other.prompting)
        }
    }

    struct Effects: Sendable {
        var scan: @Sendable ([AppleShortcut]) async -> [UUID: AppleShortcutIconFile]
        var access: @Sendable (_ prompting: Bool) async -> AppleShortcutIconProvider.Access
        var fetch:
            @Sendable ([UUID], [UUID: AppleShortcutIconFile]) async -> AppleShortcutIconCache.Fetch
        var remove: @Sendable ([AppleShortcutIconFile]) async -> Void

        static func live(_ cache: AppleShortcutIconCache) -> Effects {
            Effects(
                scan: { await cache.scan(live: $0) },
                access: { await AppleShortcutIconProvider.access(prompting: $0) },
                fetch: { await cache.fetch($0, cached: $1) },
                remove: { await cache.remove($0) })
        }
    }

    var onChange: () -> Void = {}
    /// Nil until this launch has scanned the folder.
    private(set) var files: [UUID: AppleShortcutIconFile]?
    var isReading: Bool { task != nil }

    private let cache: AppleShortcutIconCache
    private let effects: Effects
    private var live: [AppleShortcut] = []
    private var queued: Request?
    private var task: Task<Void, Never>?
    /// Skipped by ordinary reads until a sweep, so one bad shortcut can't cost every open.
    private var failed: Set<UUID> = []
    private var refused = false

    init(cache: AppleShortcutIconCache = AppleShortcutIconCache(), effects: Effects? = nil) {
        self.cache = cache
        self.effects = effects ?? .live(cache)
    }

    func url(of id: UUID) -> URL? {
        files?[id].map(cache.url(of:))
    }

    /// An empty library drops whatever was asked, so a prompt can't outlive the read it was for.
    func read(_ live: [AppleShortcut], _ request: Request) {
        self.live = live
        guard !live.isEmpty else {
            queued = nil
            return
        }
        queued = queued?.merged(request) ?? request
        start()
    }

    /// The files stay: turning the feature back on shows them before any Apple event.
    func cancel() {
        task?.cancel()
        queued = nil
        live = []
    }

    /// One read at a time; whatever was asked meanwhile runs, merged, once it ends.
    private func start() {
        guard task == nil, let request = queued else { return }
        queued = nil
        let live = live
        if let files,
            AppleShortcutIconFile.pending(
                live: live, cached: files, failed: failed, sweep: request.sweep
            ).isEmpty
        {
            return
        }
        guard request.prompting || !refused else { return }
        task = Task {
            await perform(request, live: live)
            task = nil
            start()
        }
    }

    private func perform(_ request: Request, live: [AppleShortcut]) async {
        var cached = files ?? [:]
        if files == nil {
            cached = await effects.scan(live)
            guard !Task.isCancelled else { return }
            apply(cached)
        }
        let pending = AppleShortcutIconFile.pending(
            live: live, cached: cached, failed: failed, sweep: request.sweep)
        guard !pending.isEmpty else { return }
        let access = await effects.access(request.prompting)
        guard !Task.isCancelled else { return }
        switch access {
        case .granted: refused = false
        case .refused: refused = true
        case .unavailable: break
        }
        guard access == .granted else { return }
        let fetch = await effects.fetch(pending, cached)
        guard !Task.isCancelled else { return }
        failed = request.sweep ? fetch.failed : failed.union(fetch.failed)
        guard !fetch.files.isEmpty else { return }
        apply((files ?? [:]).merging(fetch.files) { $1 })
        await effects.remove(fetch.files.keys.compactMap { cached[$0] })
    }

    private func apply(_ updated: [UUID: AppleShortcutIconFile]) {
        guard updated != files else { return }
        files = updated
        onChange()
    }
}
