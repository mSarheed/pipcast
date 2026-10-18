import Foundation
import ImageIO

/// The host a website icon is fetched for. docs/features/quicklinks.md#website-icons
enum QuicklinkFavicon {
    /// Read off the saved template, so a placeholder in the host fetches nothing.
    static func host(of link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest = Substring(trimmed)
        var hasScheme = false
        for scheme in ["https://", "http://"] where rest.lowercased().hasPrefix(scheme) {
            rest = rest.dropFirst(scheme.count)
            hasScheme = true
            break
        }
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.contains("{"), !authority.contains("}"),
            case .web(let url)? = QuicklinkDestination.detect(
                hasScheme ? "https://" + authority : String(authority)),
            let host = url.host(), !host.isEmpty
        else { return nil }
        return host.lowercased()
    }

    /// Only the host leaves the machine: no scheme, path, query or credentials.
    static func requestURL(forHost host: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/s2/favicons"
        components.queryItems = [
            URLQueryItem(name: "domain", value: host), URLQueryItem(name: "sz", value: "64")
        ]
        return components.url
    }

    /// Google answers an unknown site with a 404 carrying its own globe, which must not be kept.
    static func acceptedImage(_ data: Data, statusCode: Int) -> Data? {
        guard statusCode == 200, let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { return nil }
        return data
    }

    /// A new name per fetch, since every icon cache is keyed by path and would serve the old one.
    static func fileName(forHost host: String, version: UUID) -> String {
        "\(host)@\(version.uuidString).png"
    }

    /// `@` never appears in a parsed host, so the last one always separates it from the version.
    static func host(fromFileName name: String) -> String? {
        guard name.hasSuffix(".png"), let separator = name.lastIndex(of: "@") else { return nil }
        let host = name[..<separator]
        return host.isEmpty ? nil : String(host)
    }
}
