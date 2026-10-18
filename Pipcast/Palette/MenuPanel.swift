import AppKit

/// The ⌘K menu's own window, so glass renders against the desktop and nothing clips it.
final class MenuPanel: NSPanel {
    weak var paletteState: PaletteState?
    var onKeyDown: ((NSEvent) -> Bool)?
    var onResignKey: ((_ stayedInPalette: Bool) -> Void)?

    override var canBecomeKey: Bool { true }

    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        animationBehavior = .none
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// Mirrors `PalettePanel`: rows light on real pointer movement, never on a scroll under it.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved: paletteState?.notePointerMoved(to: NSEvent.mouseLocation)
        case .keyDown, .scrollWheel:
            paletteState?.disarmHoverHighlight(pointerAt: NSEvent.mouseLocation)
        case .flagsChanged:
            paletteState?.noteCommandHeld(event.modifierFlags.contains(.command))
        default: break
        }
        if event.type == .keyDown {
            let isReturn = event.specialKey == .carriageReturn || event.specialKey == .enter
            let isEscape = event.charactersIgnoringModifiers == "\u{1B}"
            if isReturn || isEscape, (firstResponder as? NSTextView)?.hasMarkedText() == true {
                super.sendEvent(event)
                return
            }
            if onKeyDown?(event) == true { return }
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        paletteState?.noteCommandHeld(false)
        guard onKeyDown != nil else { return }
        let presentation = paletteState?.menuPresentationToken
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, onKeyDown != nil, !isKeyWindow,
                paletteState?.menuPresentationToken == presentation
            else { return }
            onResignKey?(parent?.isKeyWindow == true)
        }
    }

}
