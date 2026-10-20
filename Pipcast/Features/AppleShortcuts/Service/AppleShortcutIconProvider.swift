import AppKit
import os

/// Each shortcut's rendered icon, read from Shortcuts Events' public scripting dictionary.
enum AppleShortcutIconProvider {
    enum Access: Sendable {
        case granted
        /// Denied, or never asked: only the Settings pane may ask.
        case refused
        /// Shortcuts Events missing or not answering, which says nothing about permission.
        case unavailable
    }

    enum Reply: Sendable {
        case icon(Data)
        case missing
        /// The send itself failed, so every later send would fail the same way.
        case unreachable
    }

    private static let bundleID = "com.apple.shortcuts.events"
    private static let log = Logger(subsystem: "io.github.msarheed.pipcast", category: "AppleShortcuts")
    private static let replyTimeout: TimeInterval = 10

    @concurrent static func access(prompting: Bool) async -> Access {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return .unavailable }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            // Permission can only be determined against a running target.
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            log.error("Shortcuts Events did not launch: \(error.localizedDescription)")
            return .unavailable
        }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = target.aeDesc else { return .unavailable }
        let status = AEDeterminePermissionToAutomateTarget(
            address, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), prompting)
        if status != noErr { log.info("Automation of Shortcuts Events answered \(status)") }
        switch Int(status) {
        case Int(noErr): return .granted
        case errAEEventNotPermitted, errAEEventWouldRequireUserConsent: return .refused
        default: return .unavailable
        }
    }

    @concurrent static func icon(of id: UUID) async -> Reply {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(iconSpecifier(of: id), forKeyword: keyDirectObject)
        // Consent is asked once, by `access`; a send never raises a prompt of its own.
        let options: NSAppleEventDescriptor.SendOptions = [
            .waitForReply, .init(rawValue: UInt(kAEDoNotPromptForUserConsent))
        ]
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: options, timeout: replyTimeout)
        } catch {
            log.error("Shortcuts Events did not answer: \(error.localizedDescription)")
            return .unreachable
        }
        // Shortcuts answers an unknown identifier inside the reply, not as a failed send.
        guard let icon = reply.paramDescriptor(forKeyword: keyDirectObject),
            icon.descriptorType == typeTIFF
        else { return .missing }
        return .icon(icon.data)
    }

    /// `icon of shortcut id "…"`, which only answers to the identifier's uppercase spelling.
    private static func iconSpecifier(of id: UUID) -> NSAppleEventDescriptor {
        let shortcut = objectSpecifier(
            of: FourCharCode("srct"), form: FourCharCode(formUniqueID),
            key: NSAppleEventDescriptor(string: id.uuidString), in: .null())
        return objectSpecifier(
            of: FourCharCode(cProperty), form: FourCharCode(formPropertyID),
            key: NSAppleEventDescriptor(typeCode: FourCharCode("sico")), in: shortcut)
    }

    private static func objectSpecifier(
        of desiredClass: FourCharCode, form: FourCharCode, key: NSAppleEventDescriptor,
        in container: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        let fields = [
            (keyAEDesiredClass, NSAppleEventDescriptor(typeCode: desiredClass)),
            (keyAEKeyForm, NSAppleEventDescriptor(enumCode: form)),
            (keyAEKeyData, key), (keyAEContainer, container)
        ]
        for (keyword, value) in fields { record.setDescriptor(value, forKeyword: AEKeyword(keyword)) }
        return record.coerce(toDescriptorType: typeObjectSpecifier) ?? record
    }
}

extension FourCharCode {
    fileprivate init(_ code: StaticString) {
        self = code.withUTF8Buffer { $0.reduce(0) { $0 << 8 | FourCharCode($1) } }
    }
}
