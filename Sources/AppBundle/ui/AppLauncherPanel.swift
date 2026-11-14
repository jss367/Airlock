import AppKit
import Common

// The `app-launcher` command opens the Quick Switcher panel in its apps scope (QuickSwitcherView.swift).
// This file holds what selecting an app does, and how the launcher behaves around Pause

@MainActor
protocol AppLauncherPresentation: AnyObject {
    var isVisible: Bool { get }
    func dismiss(restoreFocus: Bool)
}

/// The open launcher panel, if any
@MainActor var appLauncherPresentation: (any AppLauncherPresentation)?

@MainActor
func dismissAppLauncherForPause() {
    if let panel = appLauncherPresentation, panel.isVisible { panel.dismiss(restoreFocus: true) }
}

/// A queued selection after Pause must close quietly without restoring stale focus or launching.
@MainActor
func beginAppLauncherSelection(isEnabled: Bool, dismiss: (Bool) -> Void) -> Bool {
    dismiss(isEnabled)
    return isEnabled
}

/// A selection accepted before Pause can still be waiting in its session's native-focus query.
@MainActor
func runAppLauncherWindowAction(_ window: Window, action: () -> Void) {
    guard sessionCoordinator.isEnabled, window.isBound else { return }
    action()
}

/// Shared by current-workspace focus and cross-workspace summon. Admission is captured by the
/// selection caller before Task starts, and rechecked after the session's awaited initial query.
@MainActor
func runAppLauncherWindowSession(_ window: Window, admission: RunSessionGuard, action: @MainActor () -> Void) async throws {
    try await runLightSession(.menuBarButton, admission) {
        runAppLauncherWindowAction(window, action: action)
    }
}

/// What selecting an app does
enum AppLauncherAction {
    /// The app has a window on the workspace: focus it
    case focus(Window)
    /// The app only has windows on other workspaces: bring one over
    case summon(Window)
    /// Not running, or running without windows: launch it
    case launch
}

/// `runningPids` are the app's processes. summon-app --new-window can start several for one
/// bundle id, so every one of them counts
@MainActor
func appLauncherAction(runningPids: Set<pid_t>, workspace: Workspace) -> AppLauncherAction {
    guard !runningPids.isEmpty else { return .launch }
    let appWindows = Workspace.all.flatMap { $0.allLeafWindowsRecursive.filter { runningPids.contains($0.app.pid) } }
    if let window = appWindows.first(where: { $0.nodeWorkspace == workspace }) { return .focus(window) }
    if let window = appWindows.first { return .summon(window) }
    return .launch
}

/// Open the app the user picked in the panel. `dismiss` closes the panel, restoring focus to
/// Airlock's focused window if its argument is true
@MainActor
func openAppFromLauncher(url: URL, bundleIdentifier: String?, dismiss: (_ restoreFocus: Bool) -> Void) {
    let runningPids = bundleIdentifier.map { bundleId in
        MacApp.allAppsMap.values.filter { $0.rawAppBundleId == bundleId }.map(\.pid).toSet()
    } ?? []
    let workspace = focus.workspace
    let action = appLauncherAction(runningPids: runningPids, workspace: workspace)
    let isLaunch = if case .launch = action { true } else { false }
    // A launched app takes focus itself. Restoring focus first would race its activation
    guard beginAppLauncherSelection(isEnabled: sessionCoordinator.isEnabled, dismiss: { dismiss($0 && !isLaunch) }) else { return }

    switch action {
        case .focus(let window):
            // Through Airlock's own focus, not only macOS's: otherwise prevent-focus-stealing
            // sees a steal and reverts it
            guard let admission: RunSessionGuard = .isServerEnabled else { return }
            Task {
                await withErrorReporting("Focusing an app window", userMessage: "Airlock could not focus the app window.") {
                    try await runAppLauncherWindowSession(window, admission: admission) { _ = window.focusWindow() }
                }
            }
        case .summon(let window):
            // Inside a session so the layout and Airlock's own focus get updated, not only macOS's
            guard let admission: RunSessionGuard = .isServerEnabled else { return }
            Task {
                await withErrorReporting("Summoning an app window", userMessage: "Airlock could not bring the app window to this workspace.") {
                    try await runAppLauncherWindowSession(window, admission: admission) {
                        _ = window.bindAsFloatingWindow(to: workspace)
                        _ = window.focusWindow()
                    }
                }
            }
        case .launch:
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
