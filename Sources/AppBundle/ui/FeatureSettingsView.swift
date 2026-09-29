import Common
import SwiftUI

@MainActor
func showFeatureSettings() {
    let window = FeatureSettingsWindowController.shared
    window.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.window?.makeKeyAndOrderFront(nil)
}

private final class FeatureSettingsWindowController: NSWindowController {
    @MainActor static let shared: FeatureSettingsWindowController = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.title = "Airlock Feature Settings"
        window.center()
        window.isReleasedWhenClosed = false
        // The view observes TrayMenuModel, which every config reload and enable/disable republishes,
        // so the switches stay current without rebuilding the content on reopen
        window.contentView = NSHostingView(rootView: FeatureSettingsContent(model: .shared))
        return FeatureSettingsWindowController(window: window)
    }()
}

private struct FeatureSettingsContent: View {
    @ObservedObject var model: TrayMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.isEnabled { pausedBanner }
                    section("Behavior") {
                        FeatureRow(
                            title: "Prevent focus stealing",
                            summary: "Stops apps from taking focus on their own. Across workspaces blocks jumps to another workspace. Always blocks every focus change you didn't start.",
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
                        }
                    }
                    section("App") {
                        ForEach(Array(appFeatures.enumerated()), id: \.element.id) { index, feature in
                            if index > 0 { Divider() }
                            featureRow(feature)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "switch.2")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing,
                    ),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous),
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Features")
                    .font(.title2.bold())
                Text("Changes are saved to your config file")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            runningStatus
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var runningStatus: some View {
        HStack(spacing: 10) {
            Label(
                model.isEnabled ? "Running" : "Paused",
                systemImage: model.isEnabled ? "circle.fill" : "pause.circle.fill",
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(model.isEnabled ? Color.green : Color.secondary)
            Button(model.isEnabled ? "Pause Airlock" : "Resume Airlock") {
                setAirlockEnabled(!model.isEnabled)
            }
            .controlSize(.large)
        }
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

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1),
            )
        }
    }

    private func featureRow(_ feature: BoolFeature) -> some View {
        FeatureRow(title: feature.title, summary: feature.summary) {
            Toggle(feature.title, isOn: binding(for: feature))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

private struct FeatureRow<Control: View>: View {
    let title: String
    let summary: String
    var titleFont: Font = .body.weight(.medium)
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(titleFont)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            control()
        }
    }
}

@MainActor
private func setAirlockEnabled(_ isOn: Bool) {
    Task {
        try? await runLightSession(.menuBarButton, .forceRun) { () throws in
            _ = try await EnableCommand(args: EnableCmdArgs(rawArgs: [], targetState: isOn ? .on : .off))
                .run(.defaultEnv, .emptyStdin)
        }
    }
}
