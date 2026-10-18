import Foundation

enum DeepLinkRoute: Equatable, Sendable {
    case launcher
    case builtIn(BuiltInDeepLink)
    case extensionRoute(ExtensionDeepLink.Route)

    init?(url: URL, scheme ownScheme: String?) {
        guard ExtensionDeepLink.claims(url, scheme: ownScheme),
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil
        else { return nil }
        if (parts.host ?? "").isEmpty, parts.path.isEmpty, parts.query == nil {
            self = .launcher
        } else if let scheme = parts.scheme?.lowercased(),
            scheme == "pipcast" || scheme == ownScheme?.lowercased(),
            let link = BuiltInDeepLink(url: url, scheme: scheme)
        {
            self = .builtIn(link)
        } else if let route = ExtensionDeepLink.route(url: url, scheme: ownScheme) {
            self = .extensionRoute(route)
        } else {
            return nil
        }
    }
}
