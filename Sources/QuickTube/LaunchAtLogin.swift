import Foundation
import ServiceManagement

/// Login-item registration through SMAppService; only works from a signed bundle.
@MainActor
enum LaunchAtLogin {
    /// False when running outside a bundle (swift run), where the service has nothing to register.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static var isEnabled: Bool {
        isAvailable && SMAppService.mainApp.status == .enabled
    }

    /// Returns a message for the user when the system refused the change.
    static func setEnabled(_ enabled: Bool) -> String? {
        guard isAvailable else { return "Launch at login needs the installed app (make install)." }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return "Could not change login item: \(error.localizedDescription)"
        }
        // The system may have left the item "requires approval" in Login Items settings.
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            return "Approve QuickTube under System Settings → General → Login Items."
        }
        return nil
    }
}
