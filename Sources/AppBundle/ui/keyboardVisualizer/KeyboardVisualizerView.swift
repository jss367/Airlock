import AppKit
import Common
import HotKey
import SwiftUI

@MainActor
func showKeyboardVisualizer() {
    let window = KeyboardVisualizerWindowController.shared
    window.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.window?.makeKeyAndOrderFront(nil)
}

private final class KeyboardVisualizerWindowController: NSWindowController {
    @MainActor static let shared: KeyboardVisualizerWindowController = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 450),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.title = "Keyboard Visualizer"
        window.center()
        window.isReleasedWhenClosed = false
        let controller = KeyboardVisualizerWindowController(window: window)
        controller.updateContent()
        return controller
    }()

    @MainActor func updateContent() {
        window?.contentView = NSHostingView(rootView: KeyboardVisualizerContent())
    }
}

private struct ModifierOption: Identifiable {
    let label: String
    let subtitle: String?
    let rawValue: UInt

    var id: UInt { rawValue }
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: rawValue) }
}

private struct KeyboardVisualizerContent: View {
    @State private var modifierOptions: [ModifierOption] = []
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
                    .fixedSize()
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
            .padding(.horizontal)

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
            .padding(.horizontal)

            Spacer(minLength: 0)

            // Color-coded legend
            HStack(spacing: 20) {
                legendItem(color: .accentColor.opacity(0.18), label: "App Launcher")
                legendItem(color: .orange.opacity(0.15), label: "Command")
                legendItem(color: .gray.opacity(0.08), label: "Unbound")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
        }
        .padding(.top, 12)
        .frame(minWidth: 960, minHeight: 380)
        .onAppear { refreshModifierOptions(); refreshBindings() }
        .onChange(of: selectedRawModifier) { _ in refreshBindings() }
        .onReceive(refreshTimer) { _ in refreshBindings() }
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

    @MainActor
    private func refreshModifierOptions() {
        var seen = Set<UInt>()
        var options: [ModifierOption] = []

        // Always include hyper as the first option
        let hyperRaw = hyperModifiers.rawValue
        options.append(ModifierOption(
            label: "Hyper",
            subtitle: "\u{2325} + \u{2303} + \u{2318} + \u{21E7}",
            rawValue: hyperRaw,
        ))
        seen.insert(hyperRaw)

        // Collect distinct modifier prefixes from config bindings
        if let mainMode = config.modes[mainModeId] {
            for (_, binding) in mainMode.bindings {
                let raw = binding.modifiers.rawValue
                if !seen.contains(raw) {
                    seen.insert(raw)
                    options.append(ModifierOption(
                        label: binding.modifiers.toString(),
                        subtitle: nil,
                        rawValue: raw,
                    ))
                }
            }
        }

        modifierOptions = options
    }

    @MainActor
    private func refreshBindings() {
        bindings = analyzeBindings(modifierPrefix: selectedModifier)
    }
}
