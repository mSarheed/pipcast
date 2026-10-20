import AppKit
import Carbon.HIToolbox
@preconcurrency import IOKit.hidsystem
import Synchronization

// Snapshot the mutable C global `mach_task_self_`, so actor code never reads it raw.
private let machTaskSelf = mach_task_self_

/// C entry point on the tap's own thread: decode, decide under the worker's lock, apply out here.
private func hyperKeyEventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let worker = Unmanaged<HyperKeyTap.Worker>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        worker.reenable()
        return Unmanaged.passUnretained(event)
    }

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let isSynthetic = event.getIntegerValueField(.eventSourceUserData) == HyperKeyTap.syntheticTag
    let flags = event.flags.rawValue

    let decision = worker.decide(
        type: type, keyCode: keyCode, flagsRaw: flags,
        isAutorepeat: isAutorepeat, isSynthetic: isSynthetic)
    switch decision {
    case .pass:
        return Unmanaged.passUnretained(event)
    case .suppress:
        return nil
    case .rewrite(let flags, let keyCode, let asFlagsChanged):
        if asFlagsChanged { event.type = .flagsChanged }
        if let keyCode {
            event.setIntegerValueField(.keyboardEventKeycode, value: keyCode)
        }
        event.flags = CGEventFlags(rawValue: flags)
        return Unmanaged.passUnretained(event)
    }
}

@MainActor
final class HyperKeyTap {
    /// What the callback should do; `asFlagsChanged` converts in place.
    enum Decision: Sendable {
        case pass
        case suppress
        case rewrite(flags: UInt64, keyCode: Int64? = nil, asFlagsChanged: Bool = false)
    }

    /// Main-actor work a decision asks for, queued so the callback never waits on main.
    fileprivate enum Effect: Sendable {
        case unmappedCapsLock
        case quickPress(HyperKeyPhysicalKey)
    }

    /// Marker on events this tap posts, so it never reacts to its own synthetics.
    nonisolated static let syntheticTag: Int64 = 0x5459_4354

    /// Device-level modifier bits from IOLLEvent.h. See docs/features/hotkeys.md#the-hyper-key.
    private enum DeviceFlag {
        static let leftControl: UInt64 = 0x0000_0001
        static let leftShift: UInt64 = 0x0000_0002
        static let rightShift: UInt64 = 0x0000_0004
        static let leftCommand: UInt64 = 0x0000_0008
        static let rightCommand: UInt64 = 0x0000_0010
        static let leftOption: UInt64 = 0x0000_0020
        static let rightOption: UInt64 = 0x0000_0040
        static let rightControl: UInt64 = 0x0000_2000
    }

    private(set) var route: HyperKeyRoute?

    var onUnmappedCapsLock: (() -> Void)?

    private let settings: AppSettings
    private var includesShift = false
    private var worker: Worker?
    private var hidConnect: io_connect_t = IO_OBJECT_NULL

    init(settings: AppSettings) {
        self.settings = settings
    }

    // Isolated so teardown can release the main-actor IOKit connection.
    isolated deinit {
        worker?.stop()
        if hidConnect != IO_OBJECT_NULL { IOServiceClose(hidConnect) }
    }

    var isInstalled: Bool { worker != nil }
    var isEnabled: Bool? { worker?.isEnabled }
    var runLoopSourceIsValid: Bool? { worker?.runLoopSourceIsValid }

    /// Include Shift travels with the route because the tap's thread cannot read settings.
    func setRoute(_ route: HyperKeyRoute?, includesShift: Bool) {
        self.route = route
        self.includesShift = includesShift
        worker?.configure(route: route, includesShift: includesShift)
    }

    func cancelHold() {
        worker?.cancelHold()
    }

    private func perform(_ effect: Effect) {
        switch effect {
        case .unmappedCapsLock:
            onUnmappedCapsLock?()
        case .quickPress(let key):
            fireQuickPress(settings.hyperKeyQuickPress, for: key)
        }
    }

    private func fireQuickPress(_ action: HyperKeyQuickPress, for key: HyperKeyPhysicalKey) {
        // Secure Input hides the key that made this press a chord, so a short hold proves nothing.
        guard !IsSecureEventInputEnabled() else { return }
        switch action {
        case .none:
            break
        case .originalKey:
            if key == .capsLock { setCapsLockState(!capsLockState()) }
        case .escape:
            postKey(CGKeyCode(kVK_Escape))
        }
    }

    // MARK: - Tap lifecycle

    /// False when Accessibility is missing: only a trusted process may modify events.
    @discardableResult
    func install() -> Bool {
        guard worker == nil else { return true }
        let worker = Worker(route: route, includesShift: includesShift) { [weak self] effect in
            self?.perform(effect)
        }
        guard worker.install() else { return false }
        self.worker = worker
        let thread = Thread { worker.run() }
        thread.name = "io.github.msarheed.pipcast.hyper-key"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func tearDown() {
        worker?.stop()
        worker = nil
    }

    /// Called when the system disables the tap; any half-tracked hold is stale by then.
    func reenable() {
        worker?.reenable()
    }

    // MARK: - Synthetics & caps state

    /// Synthesize a bare key press for Quick Press, tagged so `decide` ignores it.
    private func postKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        for event in [down, up] {
            // The session source still carries our injected chord, and a modified Escape is eaten.
            event?.flags = []
            event?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Remapping takes Caps Lock's own function away, so a latched lock would stay stuck on.
    func unlatchCapsLock() {
        setCapsLockState(false)
    }

    /// The IOHIDSystem connection for the Caps Lock LED and lock state.
    private func hidConnection() -> io_connect_t {
        if hidConnect != IO_OBJECT_NULL { return hidConnect }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { return IO_OBJECT_NULL }
        var connect: io_connect_t = IO_OBJECT_NULL
        IOServiceOpen(service, machTaskSelf, UInt32(kIOHIDParamConnectType), &connect)
        IOObjectRelease(service)
        hidConnect = connect
        return connect
    }

    private func capsLockState() -> Bool {
        let connect = hidConnection()
        guard connect != IO_OBJECT_NULL else { return false }
        var on = false
        IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &on)
        return on
    }

    private func setCapsLockState(_ on: Bool) {
        let connect = hidConnection()
        guard connect != IO_OBJECT_NULL else { return }
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), on)
    }

    // MARK: - Worker

    /// One installed tap, serviced on its own thread so a busy main thread never holds up typing.
    fileprivate final class Worker: Sendable {
        // Core Foundation allows cross-thread control; only the worker runs the source.
        private struct Installation: @unchecked Sendable {
            let port: CFMachPort
            let source: CFRunLoopSource
            var runLoop: CFRunLoop?
        }

        private struct State {
            var isActive = true
            var installation: Installation?
            var chord: Chord
        }

        private let state: Mutex<State>
        private let perform: @MainActor @Sendable (Effect) -> Void

        init(
            route: HyperKeyRoute?, includesShift: Bool,
            perform: @escaping @MainActor @Sendable (Effect) -> Void
        ) {
            state = Mutex(State(chord: Chord(route: route, includesShift: includesShift)))
            self.perform = perform
        }

        var isActive: Bool { state.withLock { $0.isActive } }

        /// Asked outside the lock, so the health tick never makes a keystroke wait on WindowServer.
        var isEnabled: Bool? {
            let installation = state.withLock { $0.installation }
            return installation.map { CGEvent.tapIsEnabled(tap: $0.port) }
        }

        var runLoopSourceIsValid: Bool? {
            state.withLock { $0.installation.map { CFRunLoopSourceIsValid($0.source) } }
        }

        /// Created by the caller so a refusal is reported at once; `run` services it.
        func install() -> Bool {
            let mask: CGEventMask =
                (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.keyUp.rawValue)
                | (1 << CGEventType.flagsChanged.rawValue)
            guard
                let port = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .defaultTap,
                    eventsOfInterest: mask,
                    callback: hyperKeyEventTapCallback,
                    userInfo: Unmanaged.passUnretained(self).toOpaque())
            else { return false }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                CFMachPortInvalidate(port)
                return false
            }
            state.withLock { $0.installation = Installation(port: port, source: source) }
            return true
        }

        func run() {
            autoreleasepool {
                defer { finish() }
                guard let runLoop = CFRunLoopGetCurrent() else { return }
                let installation = state.withLock { state -> Installation? in
                    guard state.isActive else { return nil }
                    state.installation?.runLoop = runLoop
                    return state.installation
                }
                guard let installation else { return }
                CFRunLoopAddSource(runLoop, installation.source, .defaultMode)
                CFRunLoopRun()
                CFRunLoopRemoveSource(runLoop, installation.source, .defaultMode)
            }
        }

        /// Disables the tap at once, so input stops passing through it before the worker exits.
        func stop() {
            let installation = state.withLock { state -> Installation? in
                state.isActive = false
                state.chord.cancelHold()
                return state.installation
            }
            guard let installation else { return }
            CGEvent.tapEnable(tap: installation.port, enable: false)
            guard let runLoop = installation.runLoop else { return }
            // A queued stop also covers closing before the worker enters its run loop.
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(runLoop)
        }

        /// Enabled under the lock, so a stopped worker can never be revived.
        func reenable() {
            state.withLock { state in
                guard state.isActive, let port = state.installation?.port else { return }
                state.chord.cancelHold()
                CGEvent.tapEnable(tap: port, enable: true)
            }
        }

        func configure(route: HyperKeyRoute?, includesShift: Bool) {
            state.withLock { state in
                if route != state.chord.route { state.chord.cancelHold() }
                state.chord.route = route
                state.chord.includesShift = includesShift
            }
        }

        func cancelHold() {
            state.withLock { $0.chord.cancelHold() }
        }

        func decide(
            type: CGEventType, keyCode: Int, flagsRaw: UInt64, isAutorepeat: Bool, isSynthetic: Bool
        ) -> Decision {
            let (decision, effect) = state.withLock { state -> (Decision, Effect?) in
                guard state.isActive else { return (.pass, nil) }
                return state.chord.decide(
                    type: type, keyCode: keyCode, flagsRaw: flagsRaw,
                    isAutorepeat: isAutorepeat, isSynthetic: isSynthetic, now: .now)
            }
            if let effect {
                Task { @MainActor [weak self] in
                    guard let self, isActive else { return }
                    perform(effect)
                }
            }
            return decision
        }

        private func finish() {
            let installation = state.withLock { state -> Installation? in
                defer { state.installation = nil }
                state.isActive = false
                return state.installation
            }
            guard let installation else { return }
            CGEvent.tapEnable(tap: installation.port, enable: false)
            CFMachPortInvalidate(installation.port)
        }
    }

    // MARK: - Chord

    /// The worker's copy of the route and the press it is tracking, guarded by the worker's lock.
    fileprivate struct Chord {
        var route: HyperKeyRoute?
        var includesShift: Bool

        private var hyperActive = false
        private var hyperDownAt: ContinuousClock.Instant?
        private var otherKeyPressed = false
        private var effect: Effect?

        private static let quickPressWindow: Duration = .milliseconds(250)

        /// F18 carries fn like every F-key; a `flagsChanged` with it reads as a real fn press.
        private static let functionKeyFlagRaw = CGEventFlags.maskSecondaryFn.rawValue

        init(route: HyperKeyRoute?, includesShift: Bool) {
            self.route = route
            self.includesShift = includesShift
        }

        // MARK: Hyper chord flags

        /// The flags OR'd in while Hyper is held: the generic masks plus left-side device bits.
        private var hyperFlagsRaw: UInt64 {
            var raw =
                CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue
                | DeviceFlag.leftControl | DeviceFlag.leftOption | DeviceFlag.leftCommand
            if includesShift {
                raw |= CGEventFlags.maskShift.rawValue | DeviceFlag.leftShift
            }
            return raw
        }

        /// The Hyper key's own flag residue, scrubbed from every rewritten event.
        private var strippedFlagsRaw: UInt64 {
            guard let key = route?.key else { return 0 }
            if key == .capsLock { return CGEventFlags.maskAlphaShift.rawValue }
            guard let own = key.ownFlag, hyperFlagsRaw & own.rawValue == 0 else { return 0 }
            return own.rawValue | Self.deviceBits(for: own)
        }

        private static func deviceBits(for flag: CGEventFlags) -> UInt64 {
            switch flag {
            case .maskControl: return DeviceFlag.leftControl | DeviceFlag.rightControl
            case .maskShift: return DeviceFlag.leftShift | DeviceFlag.rightShift
            case .maskAlternate: return DeviceFlag.leftOption | DeviceFlag.rightOption
            case .maskCommand: return DeviceFlag.leftCommand | DeviceFlag.rightCommand
            default: return 0
            }
        }

        private func hyperized(_ flagsRaw: UInt64) -> UInt64 {
            (flagsRaw & ~strippedFlagsRaw) | hyperFlagsRaw
        }

        // MARK: Event decisions

        mutating func decide(
            type: CGEventType, keyCode: Int, flagsRaw: UInt64, isAutorepeat: Bool,
            isSynthetic: Bool, now: ContinuousClock.Instant
        ) -> (Decision, Effect?) {
            effect = nil
            let decision = evaluate(
                type: type, keyCode: keyCode, flagsRaw: flagsRaw,
                isAutorepeat: isAutorepeat, isSynthetic: isSynthetic, now: now)
            return (decision, effect)
        }

        private mutating func evaluate(
            type: CGEventType, keyCode: Int, flagsRaw: UInt64, isAutorepeat: Bool,
            isSynthetic: Bool, now: ContinuousClock.Instant
        ) -> Decision {
            guard !isSynthetic, let route else { return .pass }

            if keyCode == route.tapKeyCode {
                return decideHyperKeyEvent(
                    route: route, type: type, flagsRaw: flagsRaw, isAutorepeat: isAutorepeat,
                    now: now)
            }
            // A latch carries no release, so it passes as Caps Lock and the keyboard is repaired.
            if route.remap != nil, keyCode == kVK_CapsLock, type == .flagsChanged {
                effect = .unmappedCapsLock
                return .pass
            }
            guard hyperActive else { return .pass }
            // Any other key or modifier going down under Hyper makes this a combo, not a tap.
            if type == .keyDown || type == .flagsChanged { otherKeyPressed = true }
            return .rewrite(flags: hyperized(flagsRaw))
        }

        /// docs/features/hotkeys.md#press-tracking-reads-the-event
        private mutating func decideHyperKeyEvent(
            route: HyperKeyRoute, type: CGEventType, flagsRaw: UInt64, isAutorepeat: Bool,
            now: ContinuousClock.Instant
        ) -> Decision {
            guard let modifier = route.modifier else {
                return decideFunctionKeyEvent(
                    type: type, flagsRaw: flagsRaw, isAutorepeat: isAutorepeat, now: now)
            }
            guard type == .flagsChanged else { return .pass }
            let isDown = ModifierKey.held(in: flagsRaw, globeDown: false).contains(modifier)
            return .rewrite(flags: transition(isDown: isDown, flagsRaw: flagsRaw, now: now))
        }

        /// F18 arrives as keyDown/keyUp; both ends become Left Control `flagsChanged` transitions.
        private mutating func decideFunctionKeyEvent(
            type: CGEventType, flagsRaw: UInt64, isAutorepeat: Bool, now: ContinuousClock.Instant
        ) -> Decision {
            let flagsRaw = flagsRaw & ~Self.functionKeyFlagRaw
            switch type {
            case .keyDown:
                if isAutorepeat { return .suppress }
                let flags = transition(isDown: true, flagsRaw: flagsRaw, now: now)
                return .rewrite(flags: flags, keyCode: Int64(kVK_Control), asFlagsChanged: true)
            case .keyUp:
                let flags = transition(isDown: false, flagsRaw: flagsRaw, now: now)
                return .rewrite(flags: flags, keyCode: Int64(kVK_Control), asFlagsChanged: true)
            default:
                return .pass
            }
        }

        private mutating func transition(
            isDown: Bool, flagsRaw: UInt64, now: ContinuousClock.Instant
        ) -> UInt64 {
            if isDown {
                if !hyperActive { beginHold(now: now) }
                return hyperized(flagsRaw)
            }
            if hyperActive { endHold(now: now) }
            return flagsRaw & ~strippedFlagsRaw
        }

        // MARK: Hold state machine

        private mutating func beginHold(now: ContinuousClock.Instant) {
            hyperActive = true
            hyperDownAt = now
            otherKeyPressed = false
        }

        private mutating func endHold(now: ContinuousClock.Instant) {
            let isQuick =
                !otherKeyPressed && hyperDownAt.map { now - $0 < Self.quickPressWindow } ?? false
            hyperActive = false
            hyperDownAt = nil
            guard isQuick, let key = route?.key, key.hasOriginalFunction else { return }
            effect = .quickPress(key)
        }

        mutating func cancelHold() {
            hyperActive = false
            hyperDownAt = nil
            otherKeyPressed = false
        }
    }
}
