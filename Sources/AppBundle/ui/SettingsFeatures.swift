import SwiftUI

/// An optional on/off feature stored as a boolean key in the config file. The General tab of
/// the Settings window lists these.
struct BoolFeature: Identifiable {
    let title: String
    let summary: String
    var table: String? = nil
    let key: String
    var requirement: FeatureRequirement? = nil
    let isOn: @MainActor () -> Bool

    var id: String { (table.map { $0 + "." } ?? "") + key }
}

/// Another setting a feature depends on. While that setting is off the feature does nothing,
/// so Settings disables its control and shows `unmetReason` instead of leaving a dead switch.
enum FeatureRequirement {
    case windowManagement
    case focusFlash

    func isMet(_ config: Config) -> Bool {
        switch self {
            case .windowManagement: config.enableWindowManagement
            case .focusFlash: config.focusFlash.enabled
        }
    }

    var unmetReason: String {
        switch self {
            case .windowManagement: "Requires Window management, which is off."
            case .focusFlash: "Focus flash is off in General, so these have no effect."
        }
    }
}

/// Why a control with this requirement can't be used right now, or nil if it can.
func unmetReason(_ requirement: FeatureRequirement?, _ config: Config) -> String? {
    requirement.flatMap { $0.isMet(config) ? nil : $0.unmetReason }
}

/// `shouldAllowFocusChange` allows every focus change while window management is off.
let preventFocusStealingRequirement: FeatureRequirement = .windowManagement

@MainActor let behaviorFeatures: [BoolFeature] = [
    BoolFeature(
        title: "Window management",
        summary: "Automatically tiles windows and hides windows in other workspaces. Turn this off to leave windows where you put them while keeping keyboard shortcuts for moving them between monitors.",
        key: "enable-window-management", isOn: { config.enableWindowManagement },
    ),
    BoolFeature(
        title: "Workspace app switching",
        summary: "Your app switching keys (⌘Tab and ⌘` by default) cycle only the apps and windows in the current workspace. Turn this off to give those keys back to macOS.",
        key: "enable-workspace-app-switching", requirement: .windowManagement, isOn: { config.enableWorkspaceAppSwitching },
    ),
    BoolFeature(
        title: "Keyboard shortcuts",
        summary: "The other key bindings in your config, such as switching workspaces and moving windows. Turn this off to give those keys back to macOS.",
        key: "enable-keyboard-shortcuts", isOn: { config.enableKeyboardShortcuts },
    ),
    BoolFeature(
        title: "Quick switcher",
        summary: "A searchable panel of every workspace and window, opened with ⌥Space unless you rebind it. Picking a window on another workspace switches you there.",
        table: "quick-switcher", key: "enabled", isOn: { config.quickSwitcher.enabled },
    ),
    BoolFeature(
        title: "Focus flash",
        summary: "Draws a pulsing outline around the focused window after a workspace switch, so you can see where focus landed.",
        table: "focus-flash", key: "enabled", isOn: { config.focusFlash.enabled },
    ),
    BoolFeature(
        title: "Focus workspace on mouse click",
        summary: "Clicking another monitor focuses the workspace shown there. Turn this off if your first click on a control only focuses its window.",
        key: "focus-workspace-on-mouse-click", requirement: .windowManagement, isOn: { config.focusWorkspaceOnMouseClick },
    ),
    BoolFeature(
        title: "Unhide apps hidden with ⌘H",
        summary: "Brings hidden apps straight back, which turns off macOS's Hide command. Useful if you press ⌘H by accident.",
        key: "automatically-unhide-macos-hidden-apps", isOn: { config.automaticallyUnhideMacosHiddenApps },
    ),
]

@MainActor let appFeatures: [BoolFeature] = [
    BoolFeature(
        title: "Start at login",
        summary: "Launches Airlock when you log in to your Mac.",
        key: "start-at-login", isOn: { config.startAtLogin },
    ),
    BoolFeature(
        title: "Auto-reload config",
        summary: "Reloads the config file every time you save it, so edits apply without a manual reload.",
        key: "auto-reload-config", isOn: { config.autoReloadConfig },
    ),
]

/// Each change is written to the config file and the config is reloaded. The getter reads the
/// live `config`, which the reload republishes through `TrayMenuModel`, so the switches follow
/// edits made in the file too.
@MainActor
func binding(for feature: BoolFeature) -> Binding<Bool> {
    Binding(
        get: { feature.isOn() },
        set: { setSettingsValue(table: feature.table, key: feature.key, value: $0 ? "true" : "false") },
    )
}

@MainActor
func preventFocusStealingBinding() -> Binding<PreventFocusStealingMode> {
    Binding(
        get: { config.preventFocusStealing },
        set: { setSettingsValue(key: "prevent-focus-stealing", value: "'\($0.rawValue)'") },
    )
}

/// `value` is already TOML-encoded. Works while Airlock is paused too, see `reloadConfigFromUi`.
@MainActor
func setSettingsValue(table: String? = nil, key: String, value: String) {
    Task {
        do {
            try await writeSettingsValue(table: table, key: key, value: value)
        } catch {
            reportSettingsWriteFailure(error)
        }
    }
}

/// An awaitable writer lets appearance edits stop overriding config after a failed submission.
@MainActor
func writeSettingsValue(table: String? = nil, key: String, value: String) async throws {
    try setConfigValue(table: table, key: key, value: value)
    try await reloadSettingsConfigAfterWrite()
}

/// A pause/resume intent can supersede a reload before it reads the already-written file.
/// Retry only the read/apply step, using the current state and latest file rather than rewriting
/// an older edit. Each retry requires a new enable generation; unchanged cancellations fail,
/// and task cancellation stops the recovery. Never create or replay an enable intent here.
@MainActor
func reloadSettingsConfigAfterWrite(
    coordinator: SessionCoordinator = sessionCoordinator,
    reload: @MainActor () async throws -> Void = { try await reloadConfigFromUi(.menuBarButton) },
) async throws {
    while true {
        try Task.checkCancellation()
        let intent = coordinator.latestEnableIntent
        do {
            try await reload()
            return
        } catch is CancellationError {
            try Task.checkCancellation()
            guard !coordinator.isCurrent(intent) else { throw CancellationError() }
            await Task.yield()
        }
    }
}

@MainActor
func reportSettingsWriteFailure(_ error: Error) {
    logAppError(error, operation: "Updating settings")
    MessageModel.shared.message = Message(description: "Airlock Config Error", body: error.localizedDescription)
}

extension PreventFocusStealingMode {
    var menuTitle: String {
        switch self {
            case .off: "Off"
            case .crossWorkspace: "Across workspaces"
            case .always: "Always"
        }
    }
}
