import ServiceManagement

enum LaunchAtLogin {
    @concurrent static func isEnabled() async -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("Pipcast: launch-at-login change failed: \(error.localizedDescription)")
        }
    }
}
