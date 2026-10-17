import Foundation

enum DictionarySuggestions {
    static let limit = 8

    static func accepts(_ term: String) -> Bool {
        (2...128).contains(term.utf16.count)
            && !term.contains(where: \.isWhitespace)
            && term.unicodeScalars.contains(where: CharacterSet.letters.contains)
    }

    static func words(from candidates: [String], for term: String) -> [String] {
        var seen: Set<String> = [term.lowercased()]
        var words: [String] = []
        for candidate in candidates {
            let word = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard accepts(word), seen.insert(word.lowercased()).inserted else { continue }
            words.append(word)
            if words.count == limit { break }
        }
        return words
    }
}
