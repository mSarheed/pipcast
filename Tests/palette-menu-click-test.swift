import AppKit
import SwiftUI

@MainActor
final class PaletteState {
    var menuOpen = false { didSet { onMenuOpenChanged?(menuOpen) } }
    var onMenuOpenChanged: ((Bool) -> Void)?
    var isComposing = false
    var isControlListOpen = false
    var searchFieldFrame = CGRect.zero
    var mode = PaletteMode.launcher

    func notePointerMoved(to: CGPoint) {}
    func disarmHoverHighlight(pointerAt: CGPoint) {}
    func noteCommandHeld(_ held: Bool) {}
}

enum PaletteMode {
    case launcher, clipboard, quicklinkEditor
    var isNativeEditor: Bool { self == .quicklinkEditor }
}

@MainActor
enum ASCIIKeyboardLayout {
    static func character(for event: NSEvent) -> String? { nil }
}

@MainActor
private final class PressView: NSView {
    var received: [NSEvent.EventType] = []
    var activations = 0
    private var pressed = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        received.append(event.type)
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        received.append(event.type)
        if pressed { activations += 1 }
        pressed = false
    }

    override func mouseDragged(with event: NSEvent) { received.append(event.type) }
    override func rightMouseDown(with event: NSEvent) { received.append(event.type) }
    override func rightMouseUp(with event: NSEvent) { received.append(event.type) }
    override func rightMouseDragged(with event: NSEvent) { received.append(event.type) }
}

@main
@MainActor
struct PaletteMenuClickTests {
    private static var failures = 0

    private static func check(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        _ = NSApplication.shared
        let state = PaletteState()
        let panel = PalettePanel(rootView: Color.clear)
        panel.paletteState = state
        let view = PressView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = view
        panel.setFrameOrigin(CGPoint(x: -10000, y: -10000))
        panel.orderFront(nil)
        panel.becomeKey()
        panel.displayIfNeeded()
        defer { panel.orderOut(nil) }

        func send(_ type: NSEvent.EventType, clicks: Int = 1) {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: CGPoint(x: 50, y: 50), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)
            else {
                check(false, "mouse event creation")
                return
            }
            panel.sendEvent(event)
        }

        var slots: [Int] = []
        panel.onNumberSlot = { slots.append($0) }
        func numberKey(_ keyCode: UInt16, flags: NSEvent.ModifierFlags = .command,
                       repeated: Bool = false) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, characters: "&", charactersIgnoringModifiers: "&",
                isARepeat: repeated, keyCode: keyCode)
            else { fatalError("key event creation") }
            panel.sendEvent(event)
        }
        numberKey(18)
        numberKey(29)
        check(slots == [0, 9], "physical digits dispatch synchronously despite layout characters")
        for flags: NSEvent.ModifierFlags in [[], [.command, .shift], [.command, .option],
                                            [.command, .control]] {
            numberKey(19, flags: flags)
        }
        numberKey(19, repeated: true)
        state.menuOpen = true
        numberKey(19)
        state.menuOpen = false
        state.isControlListOpen = true
        numberKey(19)
        state.isControlListOpen = false
        state.mode = .quicklinkEditor
        numberKey(19)
        check(slots == [0, 9], "modifiers, repeats, menus and other screens cannot activate slots")
        state.mode = .clipboard
        numberKey(19)
        check(slots == [0, 9, 1], "clipboard retains physical pinned slots")
        state.mode = .launcher
        let editor = NSTextView(frame: .zero)
        panel.contentView?.addSubview(editor)
        panel.makeFirstResponder(editor)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        check(editor.hasMarkedText(), "fixture has real AppKit marked text")
        numberKey(20)
        check(slots == [0, 9, 1], "IME composition keeps number keys from launching results")
        editor.unmarkText()
        numberKey(20)
        check(slots == [0, 9, 1, 2], "numbered activation resumes after composition")
        panel.makeFirstResponder(nil)
        editor.removeFromSuperview()
        panel.onNumberSlot = nil

        var dismissals = 0
        func openMenu() {
            state.menuOpen = true
            panel.onDismissMenu = { [weak panel, weak state] in
                dismissals += 1
                state?.menuOpen = false
                panel?.onDismissMenu = nil
            }
            view.received.removeAll()
        }

        send(.leftMouseDown)
        send(.leftMouseUp)
        check(view.activations == 1, "an ordinary click reaches its control")

        openMenu()
        send(.leftMouseDown)
        check(dismissals == 1 && !state.menuOpen, "the press dismisses immediately")
        send(.leftMouseDragged)
        send(.leftMouseUp)
        check(view.received.isEmpty, "the entire dismissal press stays out of the content view")
        check(view.activations == 1, "a dismissing click cannot activate the underlying control")

        send(.leftMouseDown, clicks: 2)
        send(.leftMouseUp, clicks: 2)
        check(view.received == [.leftMouseDown, .leftMouseUp], "the next double-click pair arrives intact")
        check(view.activations == 2, "the next click activates exactly once")

        openMenu()
        send(.rightMouseDown)
        send(.rightMouseDragged)
        send(.rightMouseUp)
        check(dismissals == 2, "right-click dismisses once")
        check(view.received.isEmpty, "right-click dismissal cannot open an underlying row menu")

        send(.rightMouseDown)
        send(.rightMouseUp)
        check(view.received == [.rightMouseDown, .rightMouseUp], "an ordinary right-click still arrives")

        openMenu()
        send(.leftMouseDown)
        send(.leftMouseDown, clicks: 2)
        send(.leftMouseUp, clicks: 2)
        check(view.received == [.leftMouseDown, .leftMouseUp], "a missed release cannot eat the next press")
        check(view.activations == 3, "the next press works even if dismissal released outside the window")

        if let scroll = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0),
            let event = NSEvent(cgEvent: scroll)
        {
            openMenu()
            panel.sendEvent(event)
            check(state.menuOpen, "scrolling other screens preserves their menu policy")
            state.mode = .quicklinkEditor
            panel.sendEvent(event)
            check(
                !state.menuOpen && dismissals == 4,
                "scrolling a native form dismisses its menu before the anchor moves")
        } else {
            check(false, "scroll event creation")
        }

        let field = NSTextField(frame: NSRect(x: 80, y: 100, width: 250, height: 32))
        view.addSubview(field)
        let textArea = NSTextView(frame: NSRect(x: 80, y: 160, width: 250, height: 78))
        view.addSubview(textArea)
        for mode: PaletteMode in [.launcher, .quicklinkEditor] {
            state.mode = mode
            check(
                panel.cursor(at: NSPoint(x: 100, y: 116)) === NSCursor.iBeam,
                "editable fields use the text cursor independently of the screen")
            check(
                panel.cursor(at: NSPoint(x: 100, y: 180)) === NSCursor.iBeam,
                "textareas use the text cursor independently of the screen")
            check(
                panel.cursor(at: NSPoint(x: 50, y: 50)) === NSCursor.arrow,
                "bare content retains the arrow")
        }
        field.isEditable = false
        textArea.isEditable = false
        check(
            panel.cursor(at: NSPoint(x: 100, y: 116)) === NSCursor.arrow,
            "noneditable text fields retain the arrow")
        check(
            panel.cursor(at: NSPoint(x: 100, y: 180)) === NSCursor.arrow,
            "noneditable text views retain the arrow")
        state.mode = .launcher
        state.searchFieldFrame = CGRect(x: 350, y: 40, width: 250, height: 23)
        check(
            panel.cursor(at: NSPoint(x: 400, y: view.bounds.height - 50)) === NSCursor.iBeam,
            "the search rectangle still supplies its stable cursor")

        let hosting = NSHostingView(
            rootView: ScrollView {
                TextField("Extension placeholder", text: .constant(""))
                    .textFieldStyle(.plain)
                    .frame(width: 360, height: 32)
                    .padding(20)
            })
        panel.contentView = hosting
        panel.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        if let field = textField(in: hosting) {
            let rect = field.convert(field.bounds, to: nil)
            let point = NSPoint(x: rect.midX, y: rect.midY)
            state.searchFieldFrame = .zero
            check(
                panel.cursor(at: point) === NSCursor.iBeam,
                "a SwiftUI text field receives the text cursor through its native rectangle")
            field.isHidden = true
            check(panel.cursor(at: point) === NSCursor.arrow, "hidden fields never claim the cursor")
        } else {
            check(false, "SwiftUI mounts its native text field")
        }

        let composition = NSTextView(frame: view.bounds)
        panel.contentView = composition
        check(panel.makeFirstResponder(composition), "the native editor takes focus")
        composition.setMarkedText(
            "にほん", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        check(state.isComposing, "native marked text reaches the palette composition guard")
        composition.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(!state.isComposing, "committing marked text releases the palette composition guard")

        testSearchSpace(panel: panel, state: state)

        print("Palette menu click tests: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func testSearchSpace(panel: PalettePanel, state: PaletteState) {
        let editor = AliasActivationEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        panel.contentView = editor
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editor)
        state.menuOpen = false
        var calls = 0
        var consumes = true
        panel.acceptsSearchSpace = { text in
            check(text == "c", "the handler receives the editor's actual text")
            calls += 1
            return consumes
        }
        func sendSpace(modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeated, keyCode: 49)
            else { check(false, "Space event creation"); return }
            panel.sendEvent(event)
        }
        func reset(selection: NSRange = NSRange(location: 1, length: 0)) {
            editor.unmarkText()
            editor.string = "c"
            editor.setSelectedRange(selection)
        }
        reset()
        sendSpace()
        check(calls == 1 && editor.returns == 1 && editor.string == "c",
              "accepted Space delivers Return without inserting text")
        reset(selection: NSRange(location: 0, length: 0))
        sendSpace()
        check(calls == 1, "Space inside the query edits normally")
        reset(selection: NSRange(location: 0, length: 1))
        sendSpace()
        check(calls == 1, "Space replacing selected text never activates")
        reset()
        sendSpace(modifiers: .shift)
        check(calls == 1, "modified Space never activates")
        reset()
        sendSpace(repeated: true)
        check(calls == 1, "key repeat never activates")
        reset()
        editor.setMarkedText("c", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 0, length: 1))
        check(editor.hasMarkedText(), "composition fixture owns marked text")
        sendSpace()
        check(calls == 1, "IME Space never reaches alias activation")
        reset()
        state.menuOpen = true
        sendSpace()
        check(calls == 1, "an open menu owns Space")
        state.menuOpen = false
        reset()
        consumes = false
        sendSpace()
        check(calls == 2 && editor.string == "c ", "declined Space reaches native text editing")
        panel.acceptsSearchSpace = nil
    }

    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { textField(in: $0) }.first
    }
}

@MainActor
private final class AliasActivationEditor: NSTextView {
    var returns = 0

    override func insertNewline(_ sender: Any?) {
        returns += 1
    }
}
