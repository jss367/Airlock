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

            if let window = windowOnCurrentWs ?? appWindows.first {
                return summonAppWindow(window, to: currentWorkspace, io: io)
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

/// Existing-window path, separate from app discovery and launching so it can be tested with synthetic windows.
@MainActor
func summonAppWindow(_ window: Window, to workspace: Workspace, io: CmdIo) -> Bool {
    if window.nodeWorkspace == workspace {
        _ = window.focusWindow()
        return true
    }
    guard config.enableWindowManagement else {
        return reportWindowManagementIsOff(io, "Summoning an app window to another workspace")
    }
    // The session focuses natively after layout moves the window, avoiding a premature workspace pull.
    _ = window.bindAsFloatingWindow(to: workspace)
    _ = window.focusWindow()
    return true
}
