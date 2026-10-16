import Foundation

enum DictionaryResult: Identifiable, Sendable {
    case definition(DictionaryEntry)
    case suggestion(String)

    var id: String {
        switch self {
        case .definition(let entry): entry.term
        case .suggestion(let word): word
        }
    }
}
