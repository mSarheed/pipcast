import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shortcut icons as small PNGs in Caches. docs/features/apple-shortcuts.md#icons
struct AppleShortcutIconCache: Sendable {
    struct Fetch: Equatable, Sendable {
        /// Only icons that changed; one already cached under the same digest is left out.
        var files: [UUID: AppleShortcutIconFile] = [:]
        var failed: Set<UUID> = []
    }

    private static let pixelSize = 128

    let folder: URL

    init(
        folder: URL = AppPaths.caches().appending(path: "AppleShortcutIcons", directoryHint: .isDirectory)
    ) {
        self.folder = folder
    }

    func url(of file: AppleShortcutIconFile) -> URL {
        folder.appending(path: file.fileName, directoryHint: .notDirectory)
    }

    /// Deletes every file the live library no longer names.
    @concurrent func scan(live: [AppleShortcut]) async -> [UUID: AppleShortcutIconFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let (kept, stale) = AppleShortcutIconFile.resolve(fileNames: names, live: live)
        for name in stale {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
        return kept
    }

    /// Reads one at a time, so a large library never holds more than one full-size TIFF.
    @concurrent func fetch(_ ids: [UUID], cached: [UUID: AppleShortcutIconFile]) async -> Fetch {
        var fetch = Fetch()
        for (index, id) in ids.enumerated() {
            guard !Task.isCancelled else { break }
            switch await AppleShortcutIconProvider.icon(of: id) {
            case .icon(let tiff):
                let file = AppleShortcutIconFile(id: id, digest: Self.digest(of: tiff))
                guard file != cached[id] else { continue }
                if write(tiff, to: url(of: file)) { fetch.files[id] = file } else { fetch.failed.insert(id) }
            case .missing:
                fetch.failed.insert(id)
            case .unreachable:
                // One timeout per read, not one per shortcut left.
                fetch.failed.formUnion(ids[index...])
                return fetch
            }
        }
        return fetch
    }

    /// Only once rows point elsewhere: a row decoding a deleted path draws a placeholder.
    @concurrent func remove(_ files: [AppleShortcutIconFile]) async {
        for file in files {
            try? FileManager.default.removeItem(at: url(of: file))
        }
    }

    private func write(_ tiff: Data, to destination: URL) -> Bool {
        guard let png = Self.thumbnail(of: tiff) else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func digest(of data: Data) -> String {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(AppleShortcutIconFile.digestLength))
    }

    private static func thumbnail(of tiff: Data) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize
        ]
        guard let source = CGImageSourceCreateWithData(tiff as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let png = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                png, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return png as Data
    }
}
