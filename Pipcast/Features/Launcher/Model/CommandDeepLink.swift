import Foundation

/// A built-in command's link is its entry id with the `:` read as `/`: `pipcast://command/about`.
enum CommandDeepLink {
    static func url(entryID: String, scheme: String) -> URL? {
        guard action(entryID: entryID) != nil, let colon = entryID.firstIndex(of: ":") else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = String(entryID[..<colon])
        components.path = "/" + entryID[entryID.index(after: colon)...]
        return components.url
    }

    static func action(for url: URL) -> HotKeyAction? {
        if isRaycastConfetti(url) { return CommandID.confetti.hotKeyAction }
        guard let host = url.host(), !host.isEmpty else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count == 1 else { return nil }
        return action(entryID: host + ":" + path[0])
    }

    /// Raycast's own confetti links, which scripts and extensions fire to celebrate.
    static func isRaycastConfetti(_ url: URL) -> Bool {
        let path = ([url.host() ?? ""] + url.pathComponents)
            .filter { !$0.isEmpty && $0 != "/" }
            .map { $0.lowercased() }
        return path == ["confetti"] || path == ["extensions", "raycast", "raycast", "confetti"]
    }

    /// Exactly what a shortcut can bind, so a link never reaches what a chord may not.
    static func action(entryID: String) -> HotKeyAction? {
        if let command = CommandID(rawValue: entryID) { return command.hotKeyAction }
        if let command = WindowCommandCatalog.command(forEntryID: entryID) {
            return .windowCommand(id: command.id)
        }
        return SystemActionCatalog.action(forEntryID: entryID).map { .systemAction(id: $0.id) }
    }
}
