import Foundation

/// One cached icon, named by its shortcut and its pixels, so a changed icon is a new path.
struct AppleShortcutIconFile: Hashable, Sendable {
    static let digestLength = 16
    private static let pathExtension = "png"

    let id: UUID
    let digest: String

    var fileName: String { "\(id.uuidString.lowercased())-\(digest).\(Self.pathExtension)" }

    init(id: UUID, digest: String) {
        self.id = id
        self.digest = digest
    }

    init?(fileName: String) {
        let suffix = "." + Self.pathExtension
        guard fileName.hasSuffix(suffix) else { return nil }
        let stem = fileName.dropLast(suffix.count)
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        let digest = stem[stem.index(after: dash)...]
        guard digest.count == Self.digestLength, digest.allSatisfy(\.isHexDigit),
            digest == digest.lowercased(),
            let id = UUID(uuidString: String(stem[..<dash]))
        else { return nil }
        self.init(id: id, digest: String(digest))
    }

    /// The icon each live shortcut keeps from a folder scan, and every other file in it.
    static func resolve(
        fileNames: [String], live: [AppleShortcut]
    ) -> (kept: [UUID: AppleShortcutIconFile], stale: [String]) {
        let liveIDs = Set(live.map(\.id))
        var kept: [UUID: AppleShortcutIconFile] = [:]
        // Sorted so a superseded duplicate resolves the same way every launch; the sweep fixes it.
        for name in fileNames.sorted() {
            guard let file = AppleShortcutIconFile(fileName: name), liveIDs.contains(file.id),
                kept[file.id] == nil
            else { continue }
            kept[file.id] = file
        }
        let keptNames = Set(kept.values.map(\.fileName))
        return (kept, fileNames.filter { !keptNames.contains($0) })
    }

    /// A sweep re-reads every icon, a failed one too: a new glyph keeps the shortcut's identifier.
    static func pending(
        live: [AppleShortcut], cached: [UUID: AppleShortcutIconFile], failed: Set<UUID>, sweep: Bool
    ) -> [UUID] {
        live.map(\.id).filter { sweep || (cached[$0] == nil && !failed.contains($0)) }
    }
}
