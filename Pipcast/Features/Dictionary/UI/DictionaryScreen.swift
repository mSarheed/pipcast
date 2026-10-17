import SwiftUI

struct DictionaryScreen: PaletteScreen {
    let session: DictionarySession
    let coordinator: DictionaryCoordinator
    let vm: PaletteState

    private var term: String { vm.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The page on screen: it stays up while the next term resolves, and ↵ acts on what is shown.
    private var entry: DictionaryEntry? { session.lookup?.entry }

    var rows: [DictionaryResult] {
        if let entry { return [.definition(entry)] }
        return (session.lookup?.suggestions ?? []).map(DictionaryResult.suggestion)
    }

    var primaryActionTitle: String { entry == nil ? "Define Word" : "Copy Definition" }

    func ownsVerticalKeys(at selection: Int) -> Bool { vm.isComposing }

    private func result(at selection: Int) -> DictionaryResult? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let result = result(at: selection) else { return nil }
        return PopoverMenuContent(
            header: result.id,
            items: [
                PopoverMenuItem(
                    title: primaryActionTitle, systemImage: entry == nil ? "text.magnifyingglass" : "doc.on.doc",
                    shortcut: "↵"
                ) {
                    activate(result)
                },
                PopoverMenuItem(title: "Copy Word", systemImage: "character.cursor.ibeam", shortcut: "⌥↵") {
                    coordinator.copyWord(result.id)
                },
                PopoverMenuItem(title: "Open in Dictionary", systemImage: "book", shortcut: "⌘↵") {
                    coordinator.openInDictionary(result.id)
                }
            ])
    }

    func activate(at selection: Int) {
        guard !vm.isComposing, let result = result(at: selection) else { return }
        activate(result)
    }

    private func activate(_ result: DictionaryResult) {
        switch result {
        case .definition(let entry): coordinator.copy(entry)
        case .suggestion(let word): vm.rewriteQuery(word)
        }
    }

    func secondary(at selection: Int) -> Bool {
        guard !vm.isComposing, let result = result(at: selection) else { return false }
        coordinator.openInDictionary(result.id)
        return true
    }

    func alternate(at selection: Int) -> Bool {
        guard !vm.isComposing, let result = result(at: selection) else { return false }
        coordinator.copyWord(result.id)
        return true
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        if term.isEmpty { return AnyView(EmptyResults(text: "Type a word to define")) }
        if let entry { return AnyView(DictionaryEntryView(entry: entry)) }
        if !rows.isEmpty {
            return AnyView(DictionarySuggestionsView(
                words: rows.map(\.id), selection: selection, scroll: scroll,
                onActivate: { word in activate(.suggestion(word)) }))
        }
        if session.lookup?.term == term { return AnyView(EmptyResults(text: "No definition found")) }
        return AnyView(Color.clear)
    }
}
