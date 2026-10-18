import Foundation

/// Website icons, one file per host in Caches. docs/features/quicklinks.md#website-icons
@MainActor
@Observable
final class QuicklinkFaviconStore {
    typealias Download = @Sendable (URL) async -> Data?

    private(set) var files: [String: URL] = [:]

    private let folder: URL
    @ObservationIgnored private let download: Download
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Bumped by `removeAll`, so a fetch that outlives turning the setting off writes nothing.
    @ObservationIgnored private var generation = 0

    init(
        folder: URL = AppPaths.caches().appending(path: "QuicklinkIcons", directoryHint: .isDirectory),
        download: @escaping Download = QuicklinkFaviconStore.image(at:)
    ) {
        self.folder = folder
        self.download = download
        let stored = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        // Newest first, so a crash mid-refresh keeps the new icon and drops the one it replaced.
        for file in stored.sorted(by: { Self.modified($0) > Self.modified($1) }) {
            guard let host = QuicklinkFavicon.host(fromFileName: file.lastPathComponent) else { continue }
            if files[host] == nil {
                files[host] = file
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func isFetching(_ host: String) -> Bool { inFlight.contains(host) }

    /// False when nothing usable came back; pruning an icon no quicklink uses is the caller's job.
    func fetch(host: String) async -> Bool {
        guard let url = QuicklinkFavicon.requestURL(forHost: host), inFlight.insert(host).inserted
        else { return false }
        let started = generation
        defer { if generation == started { inFlight.remove(host) } }
        guard let data = await download(url), generation == started else { return false }
        let file = folder.appending(
            path: QuicklinkFavicon.fileName(forHost: host, version: UUID()),
            directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            return false
        }
        if let previous = files[host] { try? FileManager.default.removeItem(at: previous) }
        files[host] = file
        return true
    }

    func prune(keeping hosts: Set<String>) {
        for (host, file) in files where !hosts.contains(host) {
            try? FileManager.default.removeItem(at: file)
            files[host] = nil
        }
    }

    func removeAll() {
        generation &+= 1
        inFlight.removeAll()
        try? FileManager.default.removeItem(at: folder)
        if !files.isEmpty { files = [:] }
    }

    private static func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }

    /// Cacheless, never `URLSession.shared`, so the file on disk stays the only copy.
    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    @concurrent nonisolated static func image(at url: URL) async -> Data? {
        let request = URLRequest(url: url, timeoutInterval: 20)
        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse
        else { return nil }
        return QuicklinkFavicon.acceptedImage(data, statusCode: http.statusCode)
    }
}
