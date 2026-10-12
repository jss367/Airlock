import AppKit
import Common
import ServiceManagement

/// Tests count the syncs instead of changing the test runner's login item
@MainActor var startAtLoginSyncCountForTests = 0

@MainActor
func syncStartAtLogin() {
    if isUnitTest {
        startAtLoginSyncCountForTests += 1
        return
    }
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
