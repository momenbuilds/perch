import Foundation
import ServiceManagement

/// "Open at Login" for the bundled app. No-ops when running the bare executable from
/// `swift run`, which has nothing for the system to register.
enum LoginItem {
    static var isEnabled: Bool {
        guard #available(macOS 13.0, *), Bundle.main.bundleIdentifier != nil else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func set(enabled: Bool) {
        guard #available(macOS 13.0, *), Bundle.main.bundleIdentifier != nil else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("Perch: login item update failed — \(error.localizedDescription)")
        }
    }
}
