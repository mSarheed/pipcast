import SwiftUI

/// Something new waits behind the control it sits on; it goes once that has been opened.
struct UnreadDot: View {
    private static let diameter: CGFloat = 7

    var body: some View {
        Circle()
            .fill(Theme.Colors.brand)
            .frame(width: Self.diameter, height: Self.diameter)
            .accessibilityLabel("New")
    }
}
