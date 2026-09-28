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

        // Check if the app is already running and has windows. --new-window can start several
        // processes for one bundle id, so look at every matching process, not the first one
        let runningPids: Set<pid_t> = installedApp.bundleIdentifier.map { bundleId in
            Set(MacApp.allAppsMap.values.filter { $0.rawAppBundleId == bundleId }.map(\.pid))
        } ?? []

        if !runningPids.isEmpty {
            // App is running — find its windows
            let appWindows = Workspace.all
                .flatMap { ws in ws.allLeafWindowsRecursive.filter { runningPids.contains($0.app.pid) } }

            let currentWorkspace = focus.workspace
            let windowOnCurrentWs = appWindows.first { $0.nodeWorkspace == currentWorkspace }

            if let windowOnCurrentWs {
                // Already on current workspace — just focus it
                _ = windowOnCurrentWs.focusWindow()
            } else if let windowToMove = appWindows.first {
                // Move window from another workspace to current. Only use focusWindow() here —
                // the session will call nativeFocus() after layoutWorkspaces() moves the window,
                // avoiding the workspace-pull caused by activating before the move completes.
                _ = windowToMove.bindAsFloatingWindow(to: currentWorkspace)
                _ = windowToMove.focusWindow()
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
        // Without this, a running app is only re-activated and no new window appears
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config)
    }
}
