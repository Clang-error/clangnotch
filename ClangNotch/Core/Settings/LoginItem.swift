import Foundation
import ServiceManagement

/// Wraps macOS login-item registration for the main app via SMAppService.
/// Source of truth is the system status, not UserDefaults, so the toggle stays
/// in sync even if the user changes it from System Settings > General > Login Items.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            debugLog("LoginItem toggle failed: \(error)")
        }
    }
}
