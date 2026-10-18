import AppKit
import SwiftUI

@main
@MainActor
struct ExtensionTabTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    final class Window: NSWindow {
        var acceptsKeys = true
        var shown = true
        override var isKeyWindow: Bool { acceptsKeys }
        override var isVisible: Bool { shown }
    }

    final class MarkedText: NSTextView {
        override func hasMarkedText() -> Bool { true }
    }

    static func main() {
        let app = NSApplication.shared
        let window = Window(
            contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var received: [EventModifiers] = []
        let input = ExtensionTabKeys.InputView { received.append($0); return true }
        window.contentView = input

        func event(
            _ characters: String = "\t", flags: NSEvent.ModifierFlags = [],
            repeating: Bool = false, number: Int? = nil
        ) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: number ?? window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: repeating, keyCode: characters == "x" ? 7 : 48)!
        }

        app.sendEvent(event())
        expect(received == [[]], "the installed monitor routes Tab before AppKit navigation")
        received.removeAll()
        expect(input.route(event()) == nil, "a handled Tab stops before palette navigation")
        _ = input.route(event("\u{19}"))
        expect(received.last == .shift, "native back-tab implies Shift")
        _ = input.route(event(flags: [.shift, .command, .option, .control]))
        expect(
            received.last == [.shift, .command, .option, .control],
            "all shortcut modifiers survive normalization")
        let count = received.count
        _ = input.route(event("x"))
        _ = input.route(event(repeating: true))
        window.acceptsKeys = false
        _ = input.route(event())
        window.acceptsKeys = true
        window.shown = false
        _ = input.route(event())
        window.shown = true
        let other = Window(
            contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        _ = input.route(event(number: other.windowNumber))
        let editor = MarkedText(frame: .zero)
        input.addSubview(editor)
        window.makeFirstResponder(editor)
        let composing = event("\u{19}")
        expect(input.route(composing) === composing, "marked text retains the original event")
        window.makeFirstResponder(nil)
        editor.removeFromSuperview()
        expect(received.count == count, "unrelated keys, repeats and other windows stay untouched")
        input.handle = { received.append($0); return false }
        let plain = event(flags: .shift)
        expect(input.route(plain) === plain, "an unhandled ordinary Tab remains unchanged")
        expect(received.count == count + 1, "a refreshed callback replaces the previous render")
        let nonFormBackTab = event("\u{19}")
        expect(input.route(nonFormBackTab) === nonFormBackTab, "non-Form back-tab stays unchanged")
        input.isForm = true
        expect(input.route(event(repeating: true)) == nil, "Form Tab repeats cannot enter field text")
        expect(input.route(event("\u{19}", repeating: true)) == nil, "Form back-tab repeats are consumed")
        let forwarded = input.route(event("\u{19}", flags: .control))
        expect(
            forwarded?.specialKey == .tab && forwarded?.modifierFlags == [.control, .shift],
            "unbound back-tab reaches existing navigation as Shift-Tab")
        input.stop()
        app.sendEvent(event())
        expect(received.count == count + 3, "teardown removes the monitor")
        window.contentView = nil
        window.close()
        other.close()
        print(failures == 0 ? "Extension Tab input passed" : "\(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
