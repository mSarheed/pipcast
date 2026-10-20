import AppKit
import Carbon.HIToolbox
import Synchronization

@MainActor
final class AppSettings {
    var quickPressReads = 0
    var hyperKeyQuickPress: HyperKeyQuickPress {
        quickPressReads += 1
        return .none
    }
}

// The immutable callback handles are invoked only on their recorded worker run loop.
struct TapRecord: @unchecked Sendable {
    let port: CFMachPort
    let callback: CGEventTapCallBack
    let userInfo: UnsafeMutableRawPointer?
    var runLoop: CFRunLoop?
    var isEnabled = true
    var enables = 0
}

private struct TapFixture {
    var records: [TapRecord] = []
    var failNext = false
    var wrongConfiguration = false
    var servicedOnMain = false
}

private let fixture = Mutex(TapFixture())

// Module-local overloads exercise the shipped worker without installing a global input filter.
extension CGEvent {
    static func tapCreate(
        tap: CGEventTapLocation, place: CGEventTapPlacement, options: CGEventTapOptions,
        eventsOfInterest: CGEventMask, callback: CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer?
    ) -> CFMachPort? {
        let mask: CGEventMask =
            1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue
            | 1 << CGEventType.flagsChanged.rawValue
        let fail = fixture.withLock { fixture in
            fixture.wrongConfiguration =
                fixture.wrongConfiguration
                || tap != .cgSessionEventTap || place != .headInsertEventTap
                || options != .defaultTap || eventsOfInterest != mask
            defer { fixture.failNext = false }
            return fixture.failNext
        }
        guard !fail else { return nil }
        var context = CFMachPortContext()
        guard let port = CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, &context, nil)
        else { return nil }
        fixture.withLock {
            $0.records.append(TapRecord(port: port, callback: callback, userInfo: userInfo))
        }
        return port
    }

    static func tapEnable(tap: CFMachPort, enable: Bool) {
        fixture.withLock { fixture in
            guard let index = fixture.records.firstIndex(where: { $0.port === tap }) else { return }
            fixture.records[index].isEnabled = enable
            if enable { fixture.records[index].enables += 1 }
        }
    }

    static func tapIsEnabled(tap: CFMachPort) -> Bool {
        fixture.withLock { $0.records.first { $0.port === tap }?.isEnabled ?? false }
    }
}

// Records which run loop services each tap, in installation order.
func CFRunLoopRun() {
    fixture.withLock { fixture in
        fixture.servicedOnMain = fixture.servicedOnMain || Thread.isMainThread
        if let index = fixture.records.firstIndex(where: { $0.runLoop == nil }) {
            fixture.records[index].runLoop = CFRunLoopGetCurrent()
        }
    }
    CoreFoundation.CFRunLoopRun()
}

private struct Gate: Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
}

struct KeyEvent: Sendable {
    var type: CGEventType = .keyDown
    var keyCode = kVK_ANSI_A
    var flags: UInt64 = 0
    var isAutorepeat = false
}

struct Outcome: Sendable {
    let type: CGEventType
    let keyCode: Int
    let flags: UInt64
}

@main
@MainActor
struct HyperKeyTapTests {
    static var passes = 0
    static var failures = 0

    static let hyperFlags =
        CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue | 0x1 | 0x20 | 0x8
    static let shiftFlags = CGEventFlags.maskShift.rawValue | 0x2

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func waitFor(_ message: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        expect(condition(), message)
    }

    private nonisolated static func schedule(
        _ index: Int, _ body: @escaping @Sendable (TapRecord) -> Void
    ) {
        fixture.withLock { fixture in
            let record = fixture.records[index]
            guard let runLoop = record.runLoop else { return }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { body(record) }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private nonisolated static func invoke(_ record: TapRecord, _ key: KeyEvent) -> Outcome? {
        let event = CGEvent(
            keyboardEventSource: nil, virtualKey: CGKeyCode(key.keyCode), keyDown: key.type != .keyUp)!
        if key.type == .flagsChanged { event.type = .flagsChanged }
        event.flags = CGEventFlags(rawValue: key.flags)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: key.isAutorepeat ? 1 : 0)
        let proxy = OpaquePointer(Unmanaged.passUnretained(record.port).toOpaque())
        guard let result = record.callback(proxy, key.type, event, record.userInfo) else { return nil }
        let delivered = result.takeUnretainedValue()
        return Outcome(
            type: delivered.type,
            keyCode: Int(delivered.getIntegerValueField(.keyboardEventKeycode)),
            flags: delivered.flags.rawValue)
    }

    /// Blocks main until the worker answers, so every decision is made without it.
    static func deliver(_ index: Int, _ key: KeyEvent) -> Outcome? {
        let result = Mutex<Outcome?>(nil)
        let completed = DispatchSemaphore(value: 0)
        schedule(index) { record in
            let outcome = invoke(record, key)
            result.withLock { $0 = outcome }
            completed.signal()
        }
        expect(
            completed.wait(timeout: .now() + 2) == .success,
            "the worker answers while the main thread is blocked")
        return result.withLock { $0 }
    }

    static func notify(_ index: Int, _ type: CGEventType) {
        let completed = DispatchSemaphore(value: 0)
        schedule(index) { record in
            _ = invoke(record, KeyEvent(type: type))
            completed.signal()
        }
        expect(completed.wait(timeout: .now() + 2) == .success, "the notification is handled")
    }

    static func expectSignal(_ semaphore: DispatchSemaphore, _ message: String) {
        expect(semaphore.wait(timeout: .now() + 2) == .success, message)
    }

    static func record(_ index: Int) -> TapRecord {
        fixture.withLock { $0.records[index] }
    }

    static func isClosed(_ index: Int) -> Bool {
        fixture.withLock { !CFMachPortIsValid($0.records[index].port) }
    }

    nonisolated static let f18Down = KeyEvent(keyCode: kVK_F18)
    nonisolated static let f18Up = KeyEvent(type: .keyUp, keyCode: kVK_F18)
    nonisolated static let letter = KeyEvent()

    static func main() async {
        let settings = AppSettings()
        let tap = HyperKeyTap(settings: settings)
        var unmapped = 0
        tap.onUnmappedCapsLock = { unmapped += 1 }
        let capsLock = HyperKeyPhysicalKey.capsLock.route(secureInputCompatible: false)
        tap.setRoute(capsLock, includesShift: false)

        expect(tap.install(), "a trusted install reports success")
        expect(tap.install(), "a repeated install keeps the existing tap")
        expect(fixture.withLock { $0.records.count == 1 }, "a repeated install creates no second tap")
        await waitFor("the worker services the tap", { record(0).runLoop != nil })
        expect(fixture.withLock { !$0.servicedOnMain }, "the tap is never serviced on main")
        expect(tap.isEnabled == true, "diagnostics read the live tap")
        expect(tap.runLoopSourceIsValid == true, "diagnostics read the live source")

        let plain = deliver(0, letter)
        expect(plain?.type == .keyDown && plain?.flags == 0, "ordinary typing passes unchanged")
        let down = deliver(0, f18Down)
        expect(
            down?.type == .flagsChanged && down?.keyCode == kVK_Control && down?.flags == hyperFlags,
            "the Hyper key becomes a Control transition carrying the chord")
        expect(
            deliver(0, KeyEvent(keyCode: kVK_F18, isAutorepeat: true)) == nil,
            "the held key's autorepeat is swallowed")
        let combo = deliver(0, letter)
        expect(combo?.type == .keyDown && combo?.flags == hyperFlags, "a key under Hyper gets the chord")
        let up = deliver(0, f18Up)
        expect(
            up?.type == .flagsChanged && up?.keyCode == kVK_Control && up?.flags == 0,
            "the release ends the chord")
        expect(deliver(0, letter)?.flags == 0, "typing after the release is plain again")
        expect(settings.quickPressReads == 0, "a combo is not a quick press")

        _ = deliver(0, f18Down)
        _ = deliver(0, f18Up)
        expect(settings.quickPressReads == 0, "the quick press is queued while main is blocked")
        await waitFor("the quick press reaches main", { settings.quickPressReads == 1 })

        let latch = deliver(0, KeyEvent(type: .flagsChanged, keyCode: kVK_CapsLock))
        expect(latch?.type == .flagsChanged && latch?.keyCode == kVK_CapsLock, "a raw latch passes")
        expect(unmapped == 0, "the repair is queued while main is blocked")
        await waitFor("the repair reaches main", { unmapped == 1 })

        _ = deliver(0, f18Down)
        notify(0, .tapDisabledByTimeout)
        expect(record(0).enables == 1, "an active tap recovers from timeout")
        expect(deliver(0, letter)?.flags == 0, "timeout recovery drops the half-held chord")
        notify(0, .tapDisabledByUserInput)
        expect(record(0).enables == 2, "an active tap recovers from user-input disable")

        tap.setRoute(capsLock, includesShift: true)
        _ = deliver(0, f18Down)
        expect(deliver(0, letter)?.flags == hyperFlags | shiftFlags, "Include Shift reaches the worker")
        _ = deliver(0, f18Up)
        expect(deliver(0, letter)?.flags == 0, "the release clears the shifted chord")

        let fn = CGEventFlags.maskSecondaryFn.rawValue
        tap.setRoute(capsLock, includesShift: false)
        let fnDown = deliver(0, KeyEvent(keyCode: kVK_F18, flags: fn))
        expect(fnDown?.flags == hyperFlags, "the Hyper press drops F18's fn bit")
        let fnUp = deliver(0, KeyEvent(type: .keyUp, keyCode: kVK_F18, flags: fn))
        expect(fnUp?.type == .flagsChanged && fnUp?.flags == 0, "the Hyper release drops F18's fn bit")

        let rightControl: UInt64 = CGEventFlags.maskControl.rawValue | 0x2000
        tap.setRoute(HyperKeyPhysicalKey.capsLock.route(secureInputCompatible: true), includesShift: false)
        let held = deliver(0, KeyEvent(type: .flagsChanged, keyCode: kVK_RightControl, flags: rightControl))
        expect(held?.flags == hyperFlags | 0x2000, "Right Control's device bit starts the chord")
        expect(
            deliver(0, KeyEvent(flags: rightControl))?.flags == hyperFlags | 0x2000,
            "a key under compatible Hyper gets the chord")
        let released = deliver(0, KeyEvent(type: .flagsChanged, keyCode: kVK_RightControl))
        expect(released?.flags == 0, "Right Control's release ends the chord")
        expect(deliver(0, letter)?.flags == 0, "typing after a modifier release is plain again")

        let rightShift: UInt64 = CGEventFlags.maskShift.rawValue | 0x4
        tap.setRoute(HyperKeyPhysicalKey.rightShift.route(secureInputCompatible: false), includesShift: false)
        let shifted = deliver(0, KeyEvent(type: .flagsChanged, keyCode: kVK_RightShift, flags: rightShift))
        expect(shifted?.flags == hyperFlags, "a modifier Hyper key scrubs its own flag")
        expect(
            deliver(0, KeyEvent(flags: rightShift))?.flags == hyperFlags,
            "keys under a modifier Hyper key lose that modifier")
        expect(
            deliver(0, KeyEvent(type: .flagsChanged, keyCode: kVK_RightShift))?.flags == 0,
            "the modifier's release ends the chord")
        tap.setRoute(capsLock, includesShift: true)

        _ = deliver(0, KeyEvent(type: .flagsChanged, keyCode: kVK_CapsLock))
        tap.tearDown()
        expect(!tap.isInstalled, "teardown forgets the tap")
        expect(record(0).isEnabled == false, "teardown disables the tap before the worker exits")
        await waitFor("the worker invalidates the port", { isClosed(0) })
        expect(unmapped == 1, "a closed tap discards its queued repair")
        expect(tap.isEnabled == nil && tap.runLoopSourceIsValid == nil, "diagnostics see no tap")

        tap.setRoute(capsLock, includesShift: false)
        tap.install()
        await waitFor("a reinstall services a new tap", { fixture.withLock { $0.records.count == 2 } })
        await waitFor("the new tap has a worker", { record(1).runLoop != nil })
        _ = deliver(1, f18Down)
        expect(deliver(1, letter)?.flags == hyperFlags, "a reinstall starts from the current route")
        let gate = Gate()
        let late = Mutex<Outcome?>(nil)
        let completed = DispatchSemaphore(value: 0)
        let enablesBeforeClose = record(1).enables
        let readsBeforeClose = settings.quickPressReads
        schedule(1) { record in
            gate.entered.signal()
            _ = gate.resume.wait(timeout: .now() + 5)
            _ = invoke(record, KeyEvent(type: .tapDisabledByTimeout))
            _ = invoke(record, KeyEvent(type: .tapDisabledByUserInput))
            let outcome = invoke(record, letter)
            _ = invoke(record, f18Up)
            late.withLock { $0 = outcome }
            completed.signal()
        }
        expectSignal(gate.entered, "the late events are pending")
        tap.tearDown()
        gate.resume.signal()
        expectSignal(completed, "the late events complete")
        expect(record(1).enables == enablesBeforeClose, "late notifications cannot revive a closed tap")
        expect(late.withLock { $0?.flags } == 0, "a closing tap stops rewriting")
        await waitFor("the stopped worker exits", { isClosed(1) })
        try? await Task.sleep(for: .milliseconds(20))
        expect(settings.quickPressReads == readsBeforeClose, "a closed tap fires no quick press")

        fixture.withLock { $0.failNext = true }
        expect(!tap.install(), "a refused tap reports missing Accessibility")
        expect(!tap.isInstalled, "a refused tap is not installed")
        expect(tap.install(), "the next attempt installs")
        await waitFor("the retried tap has a worker", { record(2).runLoop != nil })
        tap.tearDown()
        await waitFor("the retried tap tears down", { isClosed(2) })

        var disposable: HyperKeyTap? = HyperKeyTap(settings: settings)
        let isReleased = { [weak disposable] in disposable == nil }
        disposable?.install()
        await waitFor("the disposable tap has a worker", { record(3).runLoop != nil })
        disposable = nil
        expect(isReleased(), "the worker does not retain its owner")
        await waitFor("owner deinit stops the worker", { isClosed(3) })

        for _ in 0..<100 {
            tap.install()
            tap.tearDown()
        }
        await waitFor(
            "rapid install and teardown leaves no valid ports",
            { fixture.withLock { $0.records.allSatisfy { !CFMachPortIsValid($0.port) } } })
        expect(fixture.withLock { !$0.wrongConfiguration }, "the tap keeps its session signature")
        expect(fixture.withLock { !$0.servicedOnMain }, "no tap is ever serviced on main")
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
