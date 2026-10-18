import SwiftUI

/// A quicklink's bare glyph: its website icon in full colour, else its symbol.
struct QuicklinkGlyph: View {
    let symbol: String
    let websiteIcon: URL?
    let size: CGFloat

    var body: some View {
        if let websiteIcon {
            Image(nsImage: IconCache.artwork(atPath: websiteIcon.path, extent: 1))
                .resizable()
                .frame(width: size, height: size)
        } else {
            SymbolImage(name: symbol, size: size)
        }
    }

    /// The launcher's tile, so a row's favicon sits where its symbol's tile would.
    @MainActor
    static func rowIcon(symbol: String, websiteIcon: URL?) -> NSImage {
        guard let websiteIcon else { return IconCache.symbolIcon(named: symbol) }
        return IconCache.artwork(atPath: websiteIcon.path, extent: IconCache.appIconExtent)
    }
}
