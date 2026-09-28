import SwiftUI

/// Toggles for Airlock's optional features. Each change is written to the config file and
/// the config is reloaded. The menu reads the live `config`, which the reload's light session
/// republishes through `TrayMenuModel`, so the checkmarks follow edits made in the file too.
@MainActor @ViewBuilder
func featuresMenu() -> some View {
    if let token: RunSessionGuard = .isServerEnabled {
        Menu("Features") {
            Picker("Prevent focus stealing", selection: Binding(
                get: { config.preventFocusStealing },
                set: { setFeature(key: "prevent-focus-stealing", value: "'\($0.rawValue)'", token) },
            )) {
                ForEach(PreventFocusStealingMode.allCases, id: \.self) { mode in
                    Text(mode.menuTitle).tag(mode)
                }
            }
            featureToggle("Quick switcher", config.quickSwitcher.enabled, table: "quick-switcher", key: "enabled", token)
            featureToggle("Focus flash", config.focusFlash.enabled, table: "focus-flash", key: "enabled", token)
            featureToggle("Focus workspace on mouse click", config.focusWorkspaceOnMouseClick, key: "focus-workspace-on-mouse-click", token)
            featureToggle("Unhide apps hidden with ⌘H", config.automaticallyUnhideMacosHiddenApps, key: "automatically-unhide-macos-hidden-apps", token)
            Divider()
            featureToggle("Start at login", config.startAtLogin, key: "start-at-login", token)
            featureToggle("Auto-reload config", config.autoReloadConfig, key: "auto-reload-config", token)
        }
    }
}

@MainActor
private func featureToggle(_ title: String, _ isOn: Bool, table: String? = nil, key: String, _ token: RunSessionGuard) -> some View {
    Toggle(title, isOn: Binding(
        get: { isOn },
        set: { setFeature(table: table, key: key, value: $0 ? "true" : "false", token) },
    ))
}

@MainActor
private func setFeature(table: String? = nil, key: String, value: String, _ token: RunSessionGuard) {
    Task {
        do {
            try setConfigValue(table: table, key: key, value: value)
            try await runLightSession(.menuBarButton, token) { _ = try await reloadConfig() }
        } catch {
            MessageModel.shared.message = Message(description: "Airlock Config Error", body: error.localizedDescription)
        }
    }
}

extension PreventFocusStealingMode {
    fileprivate var menuTitle: String {
        switch self {
            case .off: "Off"
            case .crossWorkspace: "Across workspaces"
            case .always: "Always"
        }
    }
}
