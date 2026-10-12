import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            NSLog("Album Visualiser: launch at login \(on ? "enable" : "disable") failed: \(error)")
            return false
        }
    }

    /// Turns it on the first time the app runs (spec: on by default).
    static func enableOnFirstRun(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: "launchAtLogin.initialised") else { return }
        defaults.set(true, forKey: "launchAtLogin.initialised")
        set(true)
    }
}
