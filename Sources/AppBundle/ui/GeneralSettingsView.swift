import AppKit
import Common
import SwiftUI

/// The General tab of the Settings window: running state and the feature switches.
struct GeneralSettingsPane: View {
    @ObservedObject var model: TrayMenuModel
    @State private var monitorCount = connectedMonitorCount

    var body: some View {
        SettingsPane {
            runningStatus
            if !model.isEnabled { pausedBanner }
            SettingsSection(title: "Behavior") {
                SettingsRow(
                    title: "Prevent focus stealing",
                    summary: "Stops apps from taking focus on their own. Across workspaces blocks jumps to another workspace. Always blocks every focus change you didn't start.",
                    disabledReason: unmetReason(preventFocusStealingRequirement, config),
                ) {
                    Picker("Prevent focus stealing", selection: preventFocusStealingBinding()) {
                        ForEach(PreventFocusStealingMode.allCases, id: \.self) { mode in
                            Text(mode.menuTitle).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                ForEach(behaviorFeatures) { feature in
                    Divider()
                    featureRow(feature)
                    if feature.key == "enable-workspace-app-switching" {
                        Divider()
                        appSwitchingScopeRow
                    }
                }
            }
            multiMonitorSection
            SettingsSection(title: "App") {
                ForEach(Array(appFeatures.enumerated()), id: \.element.id) { index, feature in
                    if index > 0 { Divider() }
                    featureRow(feature)
                }
            }
            Text("Changes are saved to your config file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }

    private var appSwitchingScopeRow: some View {
        SettingsRow(
            title: "App switching scope",
            summary: "Which windows ⌘Tab and ⌘` cycle through. With All workspaces, picking a window on another workspace switches to that workspace.",
            disabledReason: unmetReason(.workspaceAppSwitching, config),
        ) {
            Picker("App switching scope", selection: appSwitchingScopeBinding()) {
                ForEach(AppSwitchingScope.allCases, id: \.self) { scope in
                    Text(scope.menuTitle).tag(scope)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    /// The `[multi-monitor]` table. Each picker can also leave its key unset, which keeps the value above
    private var multiMonitorSection: some View {
        SettingsSection(title: "With more than one monitor") {
            Text("While more than one monitor is connected, these replace the settings above. \(multiMonitorStatus)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            SettingsRow(
                title: "Prevent focus stealing",
                summary: "Replaces Prevent focus stealing above.",
                disabledReason: unmetReason(preventFocusStealingRequirement, config),
            ) {
                Picker("Prevent focus stealing with more than one monitor", selection: multiMonitorBinding(key: "prevent-focus-stealing", \.preventFocusStealing)) {
                    Text("Same as above").tag(PreventFocusStealingMode?.none)
                    ForEach(PreventFocusStealingMode.allCases, id: \.self) { mode in
                        Text(mode.menuTitle).tag(PreventFocusStealingMode?.some(mode))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Divider()
            SettingsRow(
                title: "App switching scope",
                summary: "Replaces App switching scope above.",
                disabledReason: unmetReason(.workspaceAppSwitching, config),
            ) {
                Picker("App switching scope with more than one monitor", selection: multiMonitorBinding(key: "app-switching-scope", \.appSwitchingScope)) {
                    Text("Same as above").tag(AppSwitchingScope?.none)
                    ForEach(AppSwitchingScope.allCases, id: \.self) { scope in
                        Text(scope.menuTitle).tag(AppSwitchingScope?.some(scope))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            monitorCount = connectedMonitorCount
        }
    }

    private var multiMonitorStatus: String {
        monitorCount > 1
            ? "\(monitorCount) monitors are connected, so they apply now."
            : "One monitor is connected, so they don't apply now."
    }

    private var runningStatus: some View {
        HStack(spacing: 10) {
            Label(
                model.isEnabled ? "\(airlockAppName) is running" : "\(airlockAppName) is paused",
                systemImage: model.isEnabled ? "circle.fill" : "pause.circle.fill",
            )
            .font(.title3.weight(.medium))
            .foregroundStyle(model.isEnabled ? Color.green : Color.secondary)
            Spacer()
            Button(model.isEnabled ? "Pause \(airlockAppName)" : "Resume \(airlockAppName)") {
                setAirlockEnabled(!model.isEnabled)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 4)
    }

    private var pausedBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Airlock is paused. Every window is visible and none of these features run. Changes you make here are saved and take effect when you resume.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func featureRow(_ feature: BoolFeature) -> some View {
        SettingsRow(title: feature.title, summary: feature.summary, disabledReason: unmetReason(feature.requirement, config)) {
            Toggle(feature.title, isOn: binding(for: feature))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

@MainActor
private func setAirlockEnabled(_ isOn: Bool) {
    Task {
        await withErrorReporting("Pausing or resuming Airlock", userMessage: "Airlock could not change its running state.") {
            try await runEnableCommandFromUi(isOn ? .on : .off)
        }
    }
}
