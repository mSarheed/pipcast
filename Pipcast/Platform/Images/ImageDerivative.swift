import Foundation

/// A smaller copy of an immutable image blob, kept beside it so a tile never decodes the original.
struct ImageDerivative: Sendable {
    static let edges = [256, 1080]

    /// Serial each, so a copy's delete waits out the copy in flight; a page of rows shares three.
    private static let rowLanes = (0..<3).map {
        DispatchQueue(label: "io.github.msarheed.pipcast.image-derivative.row-\($0)", qos: .userInitiated)
    }
    /// Its own lane, so the selected entry's preview never waits behind a page of row copies.
    private static let previewLane = DispatchQueue(
        label: "io.github.msarheed.pipcast.image-derivative.preview", qos: .userInitiated)

    let url: URL
    let edge: Int

    /// Where this copy is made and deleted; the same copy always lands on the same lane.
    var queue: DispatchQueue {
        if edge == Self.edges.last { return Self.previewLane }
        let hash = url.lastPathComponent.utf8.reduce(UInt32(2_166_136_261)) {
            ($0 ^ UInt32($1)) &* 16_777_619
        }
        return Self.rowLanes[Int(hash % UInt32(Self.rowLanes.count))]
    }

    /// Returns once every lane has run what was queued on it before the call.
    static func drain() {
        for lane in rowLanes + [previewLane] { lane.sync {} }
    }

    /// Nil past the largest edge, where only the original is sharp enough.
    static func covering(_ original: URL, maxPixel: Int) -> ImageDerivative? {
        edges.first { $0 >= maxPixel }.map { ImageDerivative(original, edge: $0) }
    }

    static func all(of original: URL) -> [ImageDerivative] {
        edges.map { ImageDerivative(original, edge: $0) }
    }

    static func removeCopies(of original: URL) {
        for copy in all(of: original) {
            copy.queue.async { try? FileManager.default.removeItem(at: copy.url) }
        }
    }

    /// Copies whose blob is gone, which a quit before `removeCopies` ran leaves behind.
    static func removeOrphans(in directory: URL) {
        let sweep = rowLanes[0]
        // Swept on the lane `drain` waits on first, so the deletes it hands on are queued by then.
        sweep.async {
            let folder = directory.appending(path: ".thumbnails", directoryHint: .isDirectory)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                guard let edge = name.lastIndex(of: "-") else { continue }
                let blob = directory.appending(path: String(name[..<edge]))
                guard !FileManager.default.fileExists(atPath: blob.path) else { continue }
                let copy = folder.appending(path: name)
                let lane = all(of: blob).first { $0.url == copy }?.queue ?? sweep
                if lane === sweep {
                    try? FileManager.default.removeItem(at: copy)
                } else {
                    lane.async { try? FileManager.default.removeItem(at: copy) }
                }
            }
        }
    }

    static func folder(beside original: URL) -> URL {
        original.deletingLastPathComponent()
            .appending(path: ".thumbnails", directoryHint: .isDirectory)
    }

    /// Keyed by the whole file name, so `a.jpg` and `a.png` never share a copy.
    private init(_ original: URL, edge: Int) {
        url = Self.folder(beside: original)
            .appending(path: "\(original.lastPathComponent)-\(edge).png", directoryHint: .notDirectory)
        self.edge = edge
    }
}
