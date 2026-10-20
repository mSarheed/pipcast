struct ExtensionSearchState: Sendable {
    struct Screen: Equatable, Sendable {
        var query = ""
        var selection = 0
    }

    /// A covered screen's search, and the `searchText` it last rendered to compare on return.
    private struct Parent: Sendable {
        var screen = Screen()
        var controlledText: String?
    }

    /// Replies arrive within a few keystrokes; a screen that never echoes must not grow forever.
    private static let echoLimit = 32

    private var parents: [Parent] = []
    private var restored: Screen?
    private var depth = 1
    /// The `searchText` the screen last rendered; nil while it leaves the field uncontrolled.
    private var controlledText: String?
    /// Texts sent to `onSearchTextChange`, oldest first, each a value its reply may yet render.
    private var pendingEchoes: [String] = []
    /// The text just shown from `searchText`, whose field change is no edit to record.
    private var unrecorded: String?
    /// The text shown from `searchText` until the next edit: the extension already holds it.
    private var unsent: String?
    /// The extension's text the user cleared; putting it straight back would trap Escape.
    private var cleared: String?
    /// Without `onSearchTextChange` the extension never hears a typed text, so none can echo.
    private var hasSearchHandler = false

    mutating func navigate(to depth: Int, current: Screen) -> Screen? {
        guard depth >= 1, depth != self.depth else { return nil }
        let oldDepth = self.depth
        self.depth = depth
        restored = nil
        pendingEchoes = []
        unrecorded = nil
        unsent = nil
        cleared = nil
        if depth > oldDepth {
            parents.removeLast(max(0, parents.count - (oldDepth - 1)))
            parents.append(Parent(screen: current, controlledText: controlledText))
            while parents.count < depth - 1 { parents.append(Parent()) }
            controlledText = nil
            return Screen()
        }
        let parent = parents.indices.contains(depth - 1) ? parents[depth - 1] : Parent()
        parents.removeLast(max(0, parents.count - (depth - 1)))
        restored = parent.screen
        controlledText = parent.controlledText
        return parent.screen
    }

    mutating func queryChanged(to query: String) {
        if restored?.query != query { restored = nil }
        cleared = query.isEmpty ? unsent : nil
        if query != unsent { unsent = nil }
        guard query != unrecorded else {
            unrecorded = nil
            return
        }
        unrecorded = nil
        guard hasSearchHandler else { return }
        pendingEchoes.append(query)
        if pendingEchoes.count > Self.echoLimit { pendingEchoes.removeFirst() }
    }

    /// False for the field echoing a text the extension set: a native field reports no such edit.
    func forwardsSearchText(_ text: String) -> Bool {
        text != unsent
    }

    /// An action may ask for the value the user cleared, which is no refill to hold back.
    mutating func actionDispatched() {
        cleared = nil
    }

    /// Its own `clearSearchBar()` empties the field, not the user, so nothing is held back after.
    mutating func extensionClearsSearchBar() {
        unsent = nil
    }

    func landingSelection(for query: String, rowCount: Int) -> Int {
        guard let restored, restored.query == query else { return 0 }
        return min(max(restored.selection, 0), max(rowCount - 1, 0))
    }

    /// The text the field must now show, or nil to leave what the user is typing alone.
    mutating func searchTextRendered(
        _ text: String?, hasSearchHandler: Bool, query: String
    ) -> String? {
        // A keystroke landed before the last apply was recorded; it is sent first, then compared.
        guard unrecorded == nil || unrecorded == query else { return nil }
        let mounts = hasSearchHandler && !self.hasSearchHandler && !query.isEmpty
        self.hasSearchHandler = hasSearchHandler
        // The field folds line breaks, so a clipboard's trailing newline must compare as settled.
        let singleLine = text.map { $0.split(whereSeparator: \.isNewline).joined(separator: " ") }
        let shown = textToShow(singleLine, query: query)
        if let shown {
            unrecorded = shown
            unsent = shown
            cleared = nil
        } else if mounts, pendingEchoes.last != query {
            // The handler's mount sends what was typed during launch, like a keystroke.
            pendingEchoes.append(query)
        }
        return shown
    }

    private mutating func textToShow(_ text: String?, query: String) -> String? {
        guard let text else {
            controlledText = nil
            return nil
        }
        let previous = controlledText
        controlledText = text
        guard text != previous else { return nil }
        if let echo = pendingEchoes.firstIndex(of: text) {
            // Replies repeating this one commit nothing, so they would never come to be dropped.
            let repeats = pendingEchoes[(echo + 1)...].prefix { $0 == text }.count
            pendingEchoes.removeFirst(echo + 1 + repeats)
            // Only the newest reply says what the command settled on; an older one is superseded.
            let isNewest = pendingEchoes.isEmpty || pendingEchoes.last == text
            return isNewest && text != query ? text : nil
        }
        // A first render's empty value would wipe what was typed while the command launched.
        guard text != query, previous != nil || !text.isEmpty else { return nil }
        guard !query.isEmpty || text != cleared else { return nil }
        return text
    }
}
