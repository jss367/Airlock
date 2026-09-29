import AppKit
import Common
import ServiceManagement

@MainActor
func syncStartAtLogin() {
    let service = SMAppService.mainApp
    do {
        if config.startAtLogin {
            if isDebug {
                print("'start-at-login = true' has no effect in debug builds")
            } else {
                try service.register()
            }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    } catch {
        reportAppError(error, operation: "Updating start at login", userMessage: "Airlock could not update start at login. Check Login Items in System Settings.")
    }
}
