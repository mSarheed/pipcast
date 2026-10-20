import Foundation

/// Root searches that ran something, newest first, walked back shell-style with ↑.
struct LauncherQueryHistory: Equatable, Sendable {
    static let defaultCapacity = 50
    /// Longer than any search worth retyping: a paste this long is content, not a query.
    static let maximumLength = 200
    /// An unbroken run this long that mixes cases and digits, or is hex, reads as a key or token.
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

    /// The next older entry for a field holding `query`; a held key may only continue a walk.
    mutating func recallOlder(from query: String, startingWalk: Bool = true) -> String? {
        guard let next = olderIndex(from: query, startingWalk: startingWalk) else {
            if !isWalking(on: query) { recalledIndex = nil }
            return nil
        }
        recalledIndex = next
        return entries[next]
    }

    /// Whether ↑ on a field holding `query` would recall anything, without moving the walk.
    func canRecallOlder(from query: String, startingWalk: Bool = true) -> Bool {
        olderIndex(from: query, startingWalk: startingWalk) != nil
    }

    private func olderIndex(from query: String, startingWalk: Bool) -> Int? {
        let next: Int
        if let index = recalledIndex, isWalking(on: query) {
            next = index + 1
        } else if startingWalk, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            next = 0
        } else {
            return nil
        }
        return entries.indices.contains(next) ? next : nil
    }

    private func isWalking(on query: String) -> Bool {
        guard let index = recalledIndex, entries.indices.contains(index) else { return false }
        return entries[index] == query
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
            !text.contains("://"), !text.hasPrefix("/"), !text.hasPrefix("~")
        else { return false }
        let hasDigit = text.contains(where: \.isNumber)
        if text.allSatisfy(\.isHexDigit) { return hasDigit && text.contains(where: \.isLetter) }
        return hasDigit && text.contains(where: \.isUppercase) && text.contains(where: \.isLowercase)
    }
}
