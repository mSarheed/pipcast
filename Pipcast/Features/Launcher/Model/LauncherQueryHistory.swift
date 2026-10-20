import Foundation

/// Root searches that ran something, newest first, walked back shell-style with ↑.
struct LauncherQueryHistory: Equatable, Sendable {
    static let defaultCapacity = 50
    /// Longer than any search worth retyping: a paste this long is content, not a query.
    static let maximumLength = 200
    /// An unbroken run this long that mixes cases and digits reads as a key or token.
    static let credentialLength = 32

    let capacity: Int
    private(set) var entries: [String] = []
    /// The entry ↑ last put in the field, trusted only while the field still holds it.
    private(set) var recalledIndex: Int?

    init(capacity: Int = defaultCapacity) {
        self.capacity = max(capacity, 0)
    }

    mutating func record(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        recalledIndex = nil
        guard Self.isRecordable(text) else { return }
        entries.removeAll { $0 == text }
        entries.insert(text, at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    /// The next older entry for a field holding `query`, or nil when ↑ has nothing to recall.
    mutating func recallOlder(from query: String) -> String? {
        let next: Int
        if let index = recalledIndex, entries.indices.contains(index), entries[index] == query {
            next = index + 1
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            next = 0
        } else {
            recalledIndex = nil
            return nil
        }
        guard entries.indices.contains(next) else { return nil }
        recalledIndex = next
        return entries[next]
    }

    mutating func clear() {
        entries = []
        recalledIndex = nil
    }

    static func isRecordable(_ text: String) -> Bool {
        !text.isEmpty && text.count <= maximumLength && !text.contains(where: \.isNewline)
            && !looksLikeCredential(text)
    }

    private static func looksLikeCredential(_ text: String) -> Bool {
        guard text.count >= credentialLength, !text.contains(where: \.isWhitespace),
            !text.contains("://")
        else { return false }
        return text.contains(where: \.isUppercase) && text.contains(where: \.isLowercase)
            && text.contains(where: \.isNumber)
    }
}
