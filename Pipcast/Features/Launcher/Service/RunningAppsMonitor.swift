import AppKit

@MainActor
@Observable
final class RunningAppsMonitor {
    @ObservationIgnored private(set) var lastExternalApplication: NSRunningApplication?
    @ObservationIgnored private var activationObserver: NotificationCenter.ObservationToken?
    private(set) var runningBundleIDs: Set<String> = []
    private var runningAppPaths: Set<String> = []
    @ObservationIgnored private var observers: [NotificationToken] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        recordActivation(NSWorkspace.shared.frontmostApplication)
        activationObserver = center.addObserver(
            of: NSWorkspace.shared, for: .didActivateApplication
        ) { [weak self] message in
            self?.recordActivation(message.application)
        }
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append(NotificationToken(token, center: center))
        }
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    private func recordActivation(_ application: NSRunningApplication?) {
        guard let application, application.processIdentifier != NSRunningApplication.current.processIdentifier
        else { return }
        lastExternalApplication = application
    }

    func isRunning(_ app: AppEntry) -> Bool {
        app.kind == .application && app.bundleID != nil && runningAppPaths.contains(app.id)
    }

    /// Helpers and agents fire these too, so republish only on a real change.
    private func refresh() {
        let apps = NSWorkspace.shared.runningApplications
        let bundleIDs = Set(apps.compactMap(\.bundleIdentifier))
        let paths = Set(apps.compactMap { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path })
        if bundleIDs != runningBundleIDs { runningBundleIDs = bundleIDs }
        if paths != runningAppPaths { runningAppPaths = paths }
    }
}
