import AppKit

/// Raycast's confetti: a burst from the bottom corners of the display under the pointer.
@MainActor
final class ConfettiCoordinator {
    /// The pill, so it stays owned by `AppCore`.
    private unowned let core: AppCore
    private var panel: ConfettiPanel?
    private var show: Task<Void, Never>?

    init(core: AppCore) {
        self.core = core
    }

    /// A second burst replaces the first rather than stacking sheets.
    func fire() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            core.showMessage("🎉")
            return
        }
        guard let screen = NSScreen.underCursor else { return }
        clear()
        let panel = ConfettiPanel(screen: screen)
        self.panel = panel
        panel.orderFrontRegardless()
        show = Task { [weak self] in
            try? await Task.sleep(for: ConfettiPanel.burst)
            panel.ceaseFire()
            try? await Task.sleep(for: ConfettiPanel.lifetime)
            guard !Task.isCancelled else { return }
            self?.clear()
        }
    }

    private func clear() {
        show?.cancel()
        panel?.close()
        panel = nil
    }
}
