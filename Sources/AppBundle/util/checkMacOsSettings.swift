import AppKit
import Foundation

private let ignoreAutoSwooshKey = "airlock-ignore-auto-swoosh"

/// The Dock setting "When switching to an application, switch to a Space that has open windows
/// for the application". It interferes with workspace management.
/// The welcome window offers to disable it, see `WelcomeWindow.swift`
func isAutoSwooshEnabled() -> Bool {
    guard let dockDefaults = UserDefaults(suiteName: "com.apple.dock") else { return false }
    // workspaces-auto-swoosh defaults to true when unset
    return dockDefaults.object(forKey: "workspaces-auto-swoosh") as? Bool ?? true
}

/// The setting is on and the user hasn't chosen "Don't Ask Again"
func autoSwooshNeedsAttention(_ defaults: UserDefaults = .standard, isEnabled: Bool = isAutoSwooshEnabled()) -> Bool {
    isEnabled && !defaults.bool(forKey: ignoreAutoSwooshKey)
}

func ignoreAutoSwoosh(_ defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: ignoreAutoSwooshKey)
}

/// Returns false if the setting couldn't be changed. The failure is already reported to the user
@MainActor
func disableAutoSwoosh() -> Bool {
    let task = Process()
    task.executableURL = URL(filePath: "/usr/bin/defaults")
    task.arguments = ["write", "com.apple.dock", "workspaces-auto-swoosh", "-bool", "NO"]
    let killDock = Process()
    killDock.executableURL = URL(filePath: "/usr/bin/killall")
    killDock.arguments = ["Dock"]
    do {
        try runSettingsProcess(task)
        try runSettingsProcess(killDock)
        return true
    } catch {
        reportAppError(error, operation: "Updating macOS Space switching", userMessage: "Airlock could not finish updating the macOS setting. Check Desktop & Dock in System Settings.")
        return false
    }
}

/// Only wait after a successful launch, and stop the sequence if a settings command fails.
func runSettingsProcess(_ process: Process) throws {
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw NSError(
            domain: "Airlock.SettingsProcess",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(process.executableURL?.lastPathComponent ?? "Settings command") exited with status \(process.terminationStatus)."],
        )
    }
}
