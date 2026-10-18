import Foundation
import Synchronization

@MainActor
@Observable
final class FileSearchSession {
    typealias SearchOperation = @Sendable (String, FileSearchFilter, String?) async -> [FileSearchResult]

    enum State: Equatable {
        case idle
        case searching
        case ready
    }

    private(set) var results: [FileSearchResult] = []
    private(set) var state: State = .idle
    /// The published search: the filter belongs to it, so narrowing re-runs the same words.
    @ObservationIgnored private var request: Request?
    private var revision = 0
    @ObservationIgnored private var pending: (request: Request, revision: Int, debounce: Bool)?
    @ObservationIgnored private var lastRequestTime: ContinuousClock.Instant?
    @ObservationIgnored private var workerTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<[FileSearchResult], Never>?
    @ObservationIgnored private var recentTask: Task<Void, Never>?
    @ObservationIgnored private let searchOperation: SearchOperation
    /// Kept across closes, so the blank screen opens on its rows instead of on nothing.
    @ObservationIgnored private var recent: [FileSearchResult]?
    @ObservationIgnored private var recentStamp = 0

    private struct Request: Equatable {
        static let recent = Request(query: "", filter: .all, folder: nil)

        let query: String
        let filter: FileSearchFilter
        let folder: String?
    }

    init(index: FileIndex) {
        searchOperation = { query, filter, folder in
            await Self.search(index: index, query: query, filter: filter, folder: folder)
        }
    }

    @concurrent
    private static func search(
        index: FileIndex, query: String, filter: FileSearchFilter, folder: String?
    ) async -> [FileSearchResult] {
        let cancelled = Mutex(false)
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return [] }
            let isCancelled: @Sendable () -> Bool = { cancelled.withLock { $0 } }
            guard let prepared = FileSearchQuery.prepare(query) else {
                return index.recent(filter: filter, folder: folder, isCancelled: isCancelled)
            }
            return index.search(prepared, filter: filter, folder: folder, isCancelled: isCancelled)
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    init(searchOperation: @escaping SearchOperation) {
        self.searchOperation = searchOperation
    }

    /// An empty query is a request too: the blank screen lists what changed recently.
    func search(_ rawQuery: String, filter: FileSearchFilter = .all, folder: String? = nil) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = Request(query: query, filter: filter, folder: folder)
        guard request != self.request else { return }
        enqueue(request)
        guard request == .recent, let recent else { return }
        results = recent
        state = .ready
    }

    func results(filter: FileSearchFilter = .all, folder: String? = nil) -> [FileSearchResult] {
        let results = results
        return request?.filter == filter && request?.folder == folder ? results : []
    }

    /// Re-runs the published request; Recent's kept rows follow even behind a typed query.
    func refresh() {
        if let request { enqueue(request) }
        if request != .recent { refreshRecent() }
    }

    /// Only the kept rows move, so a list on screen never shifts under the pointer.
    func refreshRecent() {
        recentTask?.cancel()
        recentTask = Task { [weak self] in await self?.run(.recent) }
    }

    func waitUntilRecentRefreshed() async {
        await recentTask?.value
    }

    func cancel() {
        guard request != nil else { return }
        revision &+= 1
        operationTask?.cancel()
        pending = nil
        request = nil
        results = []
        state = .idle
    }

    /// A trashed row names a file that is gone, so it leaves the published results with it.
    func remove(_ result: FileSearchResult) {
        results.removeAll { $0.id == result.id }
        recent?.removeAll { $0.id == result.id }
    }

    isolated deinit {
        workerTask?.cancel()
        operationTask?.cancel()
        recentTask?.cancel()
    }

    private func enqueue(_ request: Request) {
        revision &+= 1
        operationTask?.cancel()
        if self.request?.filter != request.filter || self.request?.folder != request.folder { results = [] }
        self.request = request
        state = .searching
        let now = ContinuousClock.now
        let debounce = lastRequestTime.map { $0.duration(to: now) < .milliseconds(40) } ?? false
        lastRequestTime = now
        pending = (request, revision, debounce)
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        while let next = pending {
            pending = nil
            let operation = Task { [weak self] in
                if next.debounce, !next.request.query.isEmpty {
                    do {
                        try await Task.sleep(for: .milliseconds(40), tolerance: .zero)
                    } catch { return [FileSearchResult]() }
                }
                guard !Task.isCancelled, let self else { return [] }
                return await run(next.request)
            }
            operationTask = operation
            let found = await operation.value
            operationTask = nil
            guard !operation.isCancelled, revision == next.revision, request == next.request else { continue }
            if results != found { results = found }
            state = .ready
        }
        workerTask = nil
    }

    /// Recent's rows are kept whoever asked; stamped, so a late finisher never replaces newer rows.
    @discardableResult
    private func run(_ request: Request) async -> [FileSearchResult] {
        guard request == .recent else {
            return await searchOperation(request.query, request.filter, request.folder)
        }
        recentStamp &+= 1
        let stamp = recentStamp
        let found = await searchOperation(request.query, request.filter, request.folder)
        if !Task.isCancelled, stamp == recentStamp { recent = found }
        return found
    }
}
