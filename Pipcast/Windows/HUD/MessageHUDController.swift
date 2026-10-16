import AppKit
import SwiftUI

@MainActor
final class MessageHUDController {
    private let presenter: HUDPresenter
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        presenter = HUDPresenter(
            anchor: .edgeInset(Theme.Size.hudEdgeOffset),
            dwell: Theme.Duration.messageHUD,
            screen: { settings.openOnCursorScreen ? .underCursor : .primary })
    }

    /// `onClick` makes the pill a button that goes away once it has been acted on.
    func show(message: String, tone: DialogTone = .success, onClick: (() -> Void)? = nil) {
        let action = onClick.map { onClick in
            // Weak: the presenter's panel hosts this closure, so a strong capture would be a cycle.
            { [weak presenter] in
                presenter?.dismiss()
                onClick()
            }
        }
        presenter.show(
            MessageHUDView(message: message, accessory: .tone(tone), onClick: action)
                .environment(\.metrics, metrics),
            dwell: onClick == nil ? .standard : .seconds(Theme.Duration.actionHUD),
            interactive: onClick != nil)
    }

    /// Stays up until the work it reports ends and something replaces it, or `dismiss()` runs.
    func showProgress(message: String, onCancel: (() -> Void)? = nil) {
        presenter.show(
            MessageHUDView(message: message, accessory: .progress, onCancel: onCancel)
                .environment(\.metrics, metrics),
            dwell: .none,
            interactive: onCancel != nil)
    }

    /// One pill serves every message, so a new one would replace whatever is up.
    var isShowing: Bool { presenter.isShowing }

    func dismiss() {
        presenter.dismiss()
    }

    private var metrics: InterfaceMetrics { settings.interfaceSize.metrics }
}
