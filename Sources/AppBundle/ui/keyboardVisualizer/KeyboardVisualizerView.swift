import AppKit
import Combine
import Common
import HotKey
import SwiftUI

private struct ModifierOption: Identifiable, Equatable {
    let label: String
    let subtitle: String?
    let rawValue: UInt

    var id: UInt { rawValue }
}

/// The keyboard view of the Shortcuts tab. It exists only while shown: the Settings window drops
/// its content on close, which stops the refresh timer.
struct KeyboardVisualizerView: View {
    // Read up front, not in onAppear: a segmented control that gains its segments after its first layout keeps the wrong size
    @State private var modifierOptions: [ModifierOption] = currentModifierOptions()
    @State private var selectedRawModifier: UInt = hyperModifiers.rawValue
    @State private var bindings: [String: KeyBindingInfo] = [:]
    @State private var selectedKey: PhysicalKey? = nil

    private let baseKeySize: CGFloat = 48
    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var selectedModifier: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: selectedRawModifier)
    }

    private var selectedModifierSubtitle: String? {
        modifierOptions.first(where: { $0.rawValue == selectedRawModifier })?.subtitle
    }

    var body: some View {
        VStack(spacing: 12) {
            // Modifier selector
            VStack(spacing: 2) {
                HStack {
                    Text("Modifier:")
                        .font(.headline)
                    Picker("", selection: $selectedRawModifier) {
                        ForEach(modifierOptions) { opt in
                            Text(opt.label).tag(opt.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    // A new control for a new set of segments, for the same reason
                    .id(modifierOptions.map(\.rawValue))
                    Spacer()
                }

                if let subtitle = selectedModifierSubtitle {
                    HStack {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 20)

            // Keyboard layout
            VStack(spacing: 4) {
                ForEach(KeyboardLayout.qwerty) { row in
                    HStack(spacing: 3) {
                        ForEach(row.keys) { key in
                            let info = key.id.hasPrefix("_") ? KeyBindingInfo.unbound : (bindings[key.id] ?? .unbound)
                            KeyCapView(key: key, bindingInfo: info, baseKeySize: baseKeySize) {
                                selectedKey = key
                            }
                            .help(tooltipText(for: info))
                        }
                    }
                }
            }
            .padding(.horizontal, 20)

            // Color-coded legend
            HStack(spacing: 20) {
                legendItem(color: .accentColor.opacity(0.18), label: "App Launcher")
                legendItem(color: .orange.opacity(0.15), label: "Command")
                legendItem(color: .gray.opacity(0.08), label: "Unbound")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
        .onAppear { refreshBindings() }
        .onChange(of: selectedRawModifier) { refreshBindings() }
        .onReceive(refreshTimer) { _ in refresh() }
        .sheet(item: $selectedKey) { key in
            AppPickerView(
                keyNotation: key.id,
                modifierPrefix: selectedModifier,
            ) {
                selectedKey = nil
                refreshBindings()
            }
        }
    }

    // MARK: - Legend

    @ViewBuilder
    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.gray.opacity(0.4), lineWidth: 0.5),
                )
                .frame(width: 16, height: 16)
            Text(label)
        }
    }

    // MARK: - Tooltips

    private func tooltipText(for info: KeyBindingInfo) -> String {
        switch info {
            case .appLauncher(let appName, let appPath):
                return appPath.isEmpty ? appName : "\(appName) (\(appPath))"
            case .otherCommand(let description):
                return description
            case .unbound:
                return "Click to assign an app"
        }
    }

    // MARK: - Data

    /// The config can change while the keyboard is shown: a reload, or a binding added here
    @MainActor
    private func refresh() {
        let options = currentModifierOptions()
        if options != modifierOptions {
            modifierOptions = options
            if !options.contains(where: { $0.rawValue == selectedRawModifier }) { selectedRawModifier = hyperModifiers.rawValue }
        }
        refreshBindings()
    }

    @MainActor
    private func refreshBindings() {
        bindings = analyzeBindings(modifierPrefix: selectedModifier)
    }
}

/// Hyper, then every modifier combination the main mode's bindings use, fewest modifiers first.
@MainActor
private func currentModifierOptions() -> [ModifierOption] {
    let hyper = ModifierOption(label: "Hyper", subtitle: "\u{2325} + \u{2303} + \u{2318} + \u{21E7}", rawValue: hyperModifiers.rawValue)
    let used = Set((config.modes[mainModeId]?.bindings ?? [:]).values.map(\.modifiers.rawValue)).subtracting([hyper.rawValue])
    let others = used
        .sorted { ($0.nonzeroBitCount, $0) < ($1.nonzeroBitCount, $1) }
        .map { ModifierOption(label: modifierSymbols(NSEvent.ModifierFlags(rawValue: $0)), subtitle: nil, rawValue: $0) }
    return [hyper] + others
}

/// "⌥⇧" for option-shift, in the order macOS writes modifiers
private func modifierSymbols(_ modifiers: NSEvent.ModifierFlags) -> String {
    let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "\u{2303}"), (.option, "\u{2325}"), (.shift, "\u{21E7}"), (.command, "\u{2318}")]
    let result = symbols.filter { modifiers.contains($0.0) }.map(\.1).joined()
    return result.isEmpty ? "None" : result
}
