import SwiftUI

struct ExtensionTabKeys: NSViewRepresentable {
    var isForm = false
    let handle: (EventModifiers) -> Bool

    func makeNSView(context: Context) -> InputView { InputView(isForm: isForm, handle: handle) }

    func updateNSView(_ view: InputView, context: Context) {
        view.isForm = isForm
        view.handle = handle
    }

    final class InputView: NSView {
        var isForm: Bool
        var handle: (EventModifiers) -> Bool
        private var monitor: Any?

        init(isForm: Bool = false, handle: @escaping (EventModifiers) -> Bool) {
            self.isForm = isForm
            self.handle = handle
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return route(event)
            }
        }

        func route(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.isKeyWindow, window.isVisible,
                event.specialKey == .tab || event.specialKey == .backTab,
                (window.firstResponder as? NSTextView)?.hasMarkedText() != true
            else { return event }
            if event.isARepeat { return isForm ? nil : event }
            var modifiers: EventModifiers = []
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if event.specialKey == .backTab { modifiers.insert(.shift) }
            if handle(modifiers) { return nil }
            guard isForm, event.specialKey == .backTab else { return event }
            return NSEvent.keyEvent(
                with: .keyDown, location: event.locationInWindow,
                modifierFlags: event.modifierFlags.union(.shift), timestamp: event.timestamp,
                windowNumber: event.windowNumber, context: nil,
                characters: "\t", charactersIgnoringModifiers: "\t",
                isARepeat: false, keyCode: event.keyCode) ?? event
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        isolated deinit { stop() }
    }
}
