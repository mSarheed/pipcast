import AppKit

@main
@MainActor
struct WindowDeeplinkTest {
    static var failures = 0

    static func check(_ name: String, _ value: Bool) {
        if !value { failures += 1; print("FAIL: \(name)") }
    }

    static func main() {
        let app = NSRunningApplication.current
        let palette = PaletteCoordinator()
        palette.previousOwnWindow = RetainedWindow()
        palette.targetApp = app
        let mover = WindowMover()
        let settings = AppSettings()
        let coordinator = WindowCommandCoordinator(
            settings: settings, paletteCoordinator: palette, windowMover: mover,
            spaceSwitcher: SpaceSwitcher(), customSizes: CustomWindowSizeStore())
        coordinator.runWindowCommand(id: .sample, targetApp: app)
        check("visible palette uses explicit external app", external(mover.target, matches: app))
        check("external dispatch never restores the captured own window", palette.restoredFocus == false)
        palette.restoredFocus = nil
        coordinator.runWindowCommand(id: .sample, targetApp: app)
        check("hidden palette uses explicit external app", external(mover.target, matches: app))
        check("hidden palette does not restore focus", palette.restoredFocus == nil)

        palette.isVisible = true
        coordinator.runWindowCommand(id: .sample)
        if case .own(let own) = mover.target {
            check("ordinary shortcut retains its own-window target", own === palette.previousOwnWindow)
        } else {
            check("ordinary shortcut retains its own-window target", false)
        }
        check("ordinary shortcut restores palette focus", palette.restoredFocus == true)

        settings.windowManagementEnabled = false
        palette.isVisible = true
        let calls = mover.calls
        coordinator.runWindowCommand(id: .sample, targetApp: app)
        check("disabled window management runs nothing", mover.calls == calls && palette.isVisible)
        settings.windowManagementEnabled = true
        coordinator.runWindowCommand(id: .nextSpace, targetApp: app)
        check("Space commands never reach the window mover", mover.calls == calls)
        check("Space commands do not restore focus", palette.restoredFocus == false)
        print("window deeplink dispatch: \(failures) failures")
        if failures > 0 { exit(1) }
    }
    static func external(_ target: WindowTarget?, matches app: NSRunningApplication) -> Bool {
        guard case .external(let targetApp) = target else { return false }
        return targetApp.processIdentifier == app.processIdentifier
    }
}

@MainActor
final class RetainedWindow: NSWindow {
    override var isVisible: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppSettings {
    var windowManagementEnabled = true
    var windowGap = 0
    var windowCycle = false
}

@MainActor
final class PaletteCoordinator {
    var isVisible = true
    var previousOwnWindow: NSWindow?
    var targetApp: NSRunningApplication?
    var restoredFocus: Bool?
    func hidePalette(restoreFocus: Bool) {
        restoredFocus = restoreFocus
        isVisible = false
    }
}

struct WindowCommand {
    enum ID { case sample, nextSpace }
}

enum SpaceDirection {
    case next
    init?(_ id: WindowCommand.ID) {
        guard id == .nextSpace else { return nil }
        self = .next
    }
}

@MainActor
final class SpaceSwitcher {
    var calls = 0
    func perform(_ direction: SpaceDirection) { calls += 1 }
}

struct CustomWindowSize {}

@MainActor
final class CustomWindowSizeStore {
    func size(id: UUID) -> CustomWindowSize? { nil }
}

@MainActor
final class WindowMover {
    var target: WindowTarget?
    var calls = 0
    func perform(_ id: WindowCommand.ID, target: WindowTarget?, gap: CGFloat, cycle: Bool) {
        self.target = target
        calls += 1
    }
    func perform(_ size: CustomWindowSize, target: WindowTarget?, gap: CGFloat) {
        self.target = target
        calls += 1
    }
}
