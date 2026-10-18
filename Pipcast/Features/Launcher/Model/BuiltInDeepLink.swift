import Foundation

enum BuiltInDeepLink: Equatable, Sendable {
    case command(CommandID)
    case systemAction(SystemAction.ID)
    case windowCommand(WindowCommand.ID)

    init?(entryID: String) {
        if let command = CommandID(rawValue: entryID), !command.isQueryDriven {
            self = .command(command)
        } else if let action = SystemActionCatalog.action(forEntryID: entryID) {
            self = .systemAction(action.id)
        } else if let command = WindowCommandCatalog.command(forEntryID: entryID) {
            self = .windowCommand(command.id)
        } else {
            return nil
        }
    }

    init?(url: URL, scheme: String) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme?.lowercased() == scheme.lowercased(),
            let host = parts.host, parts.user == nil, parts.password == nil, parts.port == nil,
            parts.query == nil, parts.fragment == nil,
            parts.path.hasPrefix("/"), !parts.path.dropFirst().contains("/")
        else { return nil }
        self.init(entryID: host + ":" + parts.path.dropFirst())
    }

    var entryID: String {
        switch self {
        case .command(let command): command.rawValue
        case .systemAction(let id): SystemActionCatalog.action(id: id).entryID
        case .windowCommand(let id): WindowCommandCatalog.command(id: id)!.entryID
        }
    }

    var action: HotKeyAction {
        switch self {
        case .command(let command): .command(command)
        case .systemAction(let id): .systemAction(id: id)
        case .windowCommand(let id): .windowCommand(id: id)
        }
    }

    func url(scheme: String) -> URL? {
        URL(string: scheme + "://" + entryID.replacingOccurrences(of: ":", with: "/"))
    }
}
