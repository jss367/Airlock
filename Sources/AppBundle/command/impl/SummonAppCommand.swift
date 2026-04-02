import AppKit
import Common

struct SummonAppCommand: Command {
    let args: SummonAppCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        let appName = args.appName.val
        let installedApps = discoverInstalledApps()

        guard let installedApp = installedApps.first(where: { $0.name.localizedCaseInsensitiveCompare(appName) == .orderedSame }) else {
            return io.err("App '\(appName)' not found among installed applications")
        }

        if args.newWindow {
            launchNewInstance(installedApp)
            return true
        }

        // Check if the app is already running and has windows
        let runningApp: MacApp? = installedApp.bundleIdentifier.flatMap { bundleId in
            MacApp.allAppsMap.values.first { $0.rawAppBundleId == bundleId }
        }

        if let runningApp {
            // App is running — find its windows
            let appWindows = Workspace.all
                .flatMap { ws in ws.allLeafWindowsRecursive.filter { $0.app.pid == runningApp.pid } }

            let currentWorkspace = focus.workspace
            let windowOnCurrentWs = appWindows.first { $0.nodeWorkspace == currentWorkspace }

            if let windowOnCurrentWs {
                // Already on current workspace — just focus it
                windowOnCurrentWs.nativeFocus()
            } else if let windowToMove = appWindows.first {
                // Move a window from another workspace to current
                _ = windowToMove.bindAsFloatingWindow(to: currentWorkspace)
                windowToMove.nativeFocus()
            } else {
                // Running but no windows — launch a new instance
                launchNewInstance(installedApp)
            }
        } else {
            launchNewInstance(installedApp)
        }

        return true
    }

    private func launchNewInstance(_ app: InstalledApp) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config)
    }
}
