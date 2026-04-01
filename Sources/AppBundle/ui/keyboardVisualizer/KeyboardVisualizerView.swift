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

private class KeyboardVisualizerWindowController: NSWindowController {
    @MainActor static let shared: KeyboardVisualizerWindowController = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 450),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
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
    let rawValue: UInt

    var id: UInt { rawValue }
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: rawValue) }
}

private struct KeyboardVisualizerContent: View {
    @State private var modifierOptions: [ModifierOption] = []
    @State private var selectedRawModifier: UInt = hyperModifiers.rawValue
    @State private var bindings: [String: KeyBindingInfo] = [:]

    private let baseKeySize: CGFloat = 48

    private var selectedModifier: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: selectedRawModifier)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Modifier selector
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
            .padding(.horizontal)

            // Keyboard layout
            VStack(spacing: 4) {
                ForEach(KeyboardLayout.qwerty) { row in
                    HStack(spacing: 3) {
                        ForEach(row.keys) { key in
                            let info = key.id.hasPrefix("_") ? KeyBindingInfo.unbound : (bindings[key.id] ?? .unbound)
                            KeyCapView(key: key, bindingInfo: info, baseKeySize: baseKeySize)
                        }
                    }
                }
            }
            .padding(.horizontal)

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .frame(minWidth: 960, minHeight: 350)
        .onAppear { refreshModifierOptions(); refreshBindings() }
        .onChange(of: selectedRawModifier) { _ in refreshBindings() }
    }

    @MainActor
    private func refreshModifierOptions() {
        var seen = Set<UInt>()
        var options: [ModifierOption] = []

        // Always include hyper as the first option
        let hyperRaw = hyperModifiers.rawValue
        options.append(ModifierOption(label: "Hyper", rawValue: hyperRaw))
        seen.insert(hyperRaw)

        // Collect distinct modifier prefixes from config bindings
        if let mainMode = config.modes[mainModeId] {
            for (_, binding) in mainMode.bindings {
                let raw = binding.modifiers.rawValue
                if !seen.contains(raw) {
                    seen.insert(raw)
                    options.append(ModifierOption(label: binding.modifiers.toString(), rawValue: raw))
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
