import AppKit

/// Raycast's confetti: a burst from the bottom corners of the display under the pointer.
@MainActor
final class ConfettiCoordinator {
    /// The pill, so it stays owned by `AppCore`.
    private unowned let core: AppCore
    /// One sheet per display with confetti still in the air, keyed by its frame.
    private var panels: [CGRect: ConfettiPanel] = [:]

    init(core: AppCore) {
        self.core = core
    }

    /// A second burst joins the first on its display rather than cutting it short.
    func fire() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            clear()
            core.showMessage("🎉")
            return
        }
        guard let screen = NSScreen.underCursor else { return }
        panel(for: screen).fire()
    }

    private func panel(for screen: NSScreen) -> ConfettiPanel {
        let frame = screen.frame
        if let panel = panels[frame] { return panel }
        let panel = ConfettiPanel(screen: screen)
        panel.onEmpty = { [weak self, weak panel] in
            guard let self, let panel, panels[frame] === panel else { return }
            panels[frame] = nil
            panel.close()
        }
        panels[frame] = panel
        panel.orderFrontRegardless()
        return panel
    }

    private func clear() {
        for panel in panels.values { panel.close() }
        panels.removeAll()
    }
}
