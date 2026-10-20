import AppKit
import os

/// Each shortcut's rendered icon, read from Shortcuts Events' public scripting dictionary.
enum AppleShortcutIconProvider {
    private static let bundleID = "com.apple.shortcuts.events"
    private static let log = Logger(subsystem: "io.github.msarheed.pipcast", category: "AppleShortcuts")
    private static let replyTimeout: TimeInterval = 10

    /// Unprompted, Automation that was never asked reads as refused, like an outright denial.
    @concurrent static func canRead(prompting: Bool) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            // Permission can only be determined against a running target.
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            log.error("Shortcuts Events did not launch: \(error.localizedDescription)")
            return false
        }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(
            address, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), prompting)
        if status != noErr { log.info("Automation of Shortcuts Events answered \(status)") }
        return status == noErr
    }

    /// TIFF bytes, or nil when Shortcuts no longer knows the identifier.
    @concurrent static func icon(of id: UUID) async -> Data? {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(iconSpecifier(of: id), forKeyword: keyDirectObject)
        // Consent is asked once, by `canRead`; a send never raises a prompt of its own.
        let options: NSAppleEventDescriptor.SendOptions = [
            .waitForReply, .init(rawValue: UInt(kAEDoNotPromptForUserConsent))
        ]
        guard let reply = try? event.sendEvent(options: options, timeout: replyTimeout),
            let icon = reply.paramDescriptor(forKeyword: keyDirectObject),
            icon.descriptorType == typeTIFF
        else { return nil }
        return icon.data
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
