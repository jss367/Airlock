import SwiftUI

/// An optional on/off feature stored as a boolean key in the config file. The Features menu
/// and the Feature Settings window both list these, so the two always offer the same toggles.
struct BoolFeature: Identifiable {
    let title: String
    let summary: String
    var table: String? = nil
    let key: String
    let isOn: @MainActor () -> Bool

    var id: String { (table.map { $0 + "." } ?? "") + key }
}

@MainActor let behaviorFeatures: [BoolFeature] = [
    BoolFeature(
        title: "Workspace app switching",
        summary: "Your app switching keys (⌘Tab and ⌘` by default) cycle only the apps and windows in the current workspace. Turn this off to give those keys back to macOS.",
        key: "enable-workspace-app-switching", isOn: { config.enableWorkspaceAppSwitching },
    ),
    BoolFeature(
        title: "Keyboard shortcuts",
        summary: "The other key bindings in your config, such as switching workspaces and moving windows. Turn this off to give those keys back to macOS.",
        key: "enable-keyboard-shortcuts", isOn: { config.enableKeyboardShortcuts },
    ),
    BoolFeature(
        title: "Quick switcher",
        summary: "A searchable panel of the windows in the current workspace, opened with ⌥Space unless you rebind it.",
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
        key: "focus-workspace-on-mouse-click", isOn: { config.focusWorkspaceOnMouseClick },
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

/// Toggles for Airlock's optional features. Each change is written to the config file and
/// the config is reloaded. The menu reads the live `config`, which the reload's light session
/// republishes through `TrayMenuModel`, so the checkmarks follow edits made in the file too.
@MainActor @ViewBuilder
func featuresMenu() -> some View {
    Menu("Features") {
        Picker("Prevent focus stealing", selection: preventFocusStealingBinding()) {
            ForEach(PreventFocusStealingMode.allCases, id: \.self) { mode in
                Text(mode.menuTitle).tag(mode)
            }
        }
        ForEach(behaviorFeatures) { feature in
            Toggle(feature.title, isOn: binding(for: feature))
        }
        Divider()
        ForEach(appFeatures) { feature in
            Toggle(feature.title, isOn: binding(for: feature))
        }
    }
}

@MainActor
func binding(for feature: BoolFeature) -> Binding<Bool> {
    Binding(
        get: { feature.isOn() },
        set: { setFeature(table: feature.table, key: feature.key, value: $0 ? "true" : "false") },
    )
}

@MainActor
func preventFocusStealingBinding() -> Binding<PreventFocusStealingMode> {
    Binding(
        get: { config.preventFocusStealing },
        set: { setFeature(key: "prevent-focus-stealing", value: "'\($0.rawValue)'") },
    )
}

/// Works while Airlock is paused too. The reload keeps the paused state (see `reloadConfig`),
/// so the new value lands in `config` and takes effect on resume.
@MainActor
private func setFeature(table: String? = nil, key: String, value: String) {
    Task {
        do {
            try setConfigValue(table: table, key: key, value: value)
            try await runLightSession(.menuBarButton, .forceRun) { _ = try await reloadConfig() }
        } catch {
            MessageModel.shared.message = Message(description: "Airlock Config Error", body: error.localizedDescription)
        }
    }
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
