import Foundation
import ServiceManagement

/// Registers Chinchilla itself as a login item (the modern API — shows up
/// in System Settings → Login Items where the user can always override).
/// Without this, everything "persistent" (Everyday-mode watchdog, desktop
/// widget, menu bar) silently dies at reboot.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}
