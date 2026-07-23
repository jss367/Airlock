import Common
import SwiftUI

@MainActor
func showKeybindingsHelp() {
    let window = KeybindingsWindowController.shared
    window.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.window?.makeKeyAndOrderFront(nil)
}

private final class KeybindingsWindowController: NSWindowController {
    @MainActor static let shared: KeybindingsWindowController = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.title = "Airlock Keybindings"
        window.center()
        window.isReleasedWhenClosed = false
        let controller = KeybindingsWindowController(window: window)
        controller.updateContent()
        return controller
    }()

    @MainActor func updateContent() {
        window?.contentView = NSHostingView(rootView: KeybindingsHelpContent())
    }
}

// MARK: - Model

private struct Shortcut {
    let tokens: [KeyToken]
    let action: String
}

private struct KeyToken: Identifiable {
    let id: Int
    let label: String
    let isModifier: Bool
}

private struct ModeSection: Identifiable {
    let id: Int
    let title: String
    let accent: Color
    let shortcuts: [Shortcut]
}

// MARK: - View

private struct KeybindingsHelpContent: View {
    @State private var sections: [ModeSection] = []
    @State private var searchText: String = ""

    private var filteredSections: [ModeSection] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let matches = section.shortcuts.filter { shortcut in
                shortcut.action.lowercased().contains(query) ||
                    shortcut.tokens.contains { $0.label.lowercased().contains(query) }
            }
            guard !matches.isEmpty else { return nil }
            return ModeSection(id: section.id, title: section.title, accent: section.accent, shortcuts: matches)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if sections.isEmpty {
                emptyState
            } else {
                searchField
                Divider()
                content
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadBindings() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
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
                Text("Keybindings")
                    .font(.title2.bold())
                Text("Your Airlock keyboard shortcuts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter shortcuts…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1),
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No keybindings configured.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var content: some View {
        ScrollView {
            let visible = filteredSections
            if visible.isEmpty {
                Text("No shortcuts match “\(searchText)”.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(visible) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
    }

    private func sectionView(_ section: ModeSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(section.accent)
                    .frame(width: 9, height: 9)
                Text(section.title)
                    .font(.headline)
                    .foregroundStyle(section.accent)
                Text("\(section.shortcuts.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(section.accent.opacity(0.15), in: Capsule())
            }

            VStack(spacing: 0) {
                ForEach(Array(section.shortcuts.enumerated()), id: \.offset) { rowIndex, shortcut in
                    shortcutRow(shortcut, accent: section.accent, isEven: rowIndex % 2 == 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1),
            )
        }
    }

    private func shortcutRow(_ shortcut: Shortcut, accent: Color, isEven: Bool) -> some View {
        HStack(alignment: .center, spacing: 6) {
            ForEach(shortcut.tokens) { token in
                keycap(token, accent: accent)
            }
            Spacer(minLength: 16)
            Text(shortcut.action)
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isEven ? Color.clear : accent.opacity(0.05))
    }

    private func keycap(_ token: KeyToken, accent: Color) -> some View {
        Text(token.label)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(token.isModifier ? Color.secondary : accent)
            .frame(minWidth: 22)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                token.isModifier
                    ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                    : AnyShapeStyle(accent.opacity(0.12)),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(token.isModifier ? Color.primary.opacity(0.12) : accent.opacity(0.35), lineWidth: 1),
            )
    }

    // MARK: - Data loading

    @MainActor private func loadBindings() {
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .green, .indigo]
        var result: [ModeSection] = []
        var sectionIndex = 0
        for (modeName, mode) in config.modes.sorted(by: { $0.key < $1.key }) {
            let sorted = mode.bindings.sorted { $0.value.descriptionWithKeyNotation < $1.value.descriptionWithKeyNotation }
            guard !sorted.isEmpty else { continue }
            var shortcuts: [Shortcut] = []
            for entry in sorted {
                let binding = entry.value
                let action = binding.commands.map { $0.args.description }.joined(separator: ", ")
                let tokens = keyTokens(from: binding.descriptionWithKeyNotation)
                shortcuts.append(Shortcut(tokens: tokens, action: action))
            }
            let title = modeName == mainModeId ? "Global" : modeName
            let accent = modeName == mainModeId ? Color.accentColor : palette[sectionIndex % palette.count]
            result.append(ModeSection(id: sectionIndex, title: title, accent: accent, shortcuts: shortcuts))
            sectionIndex += 1
        }
        sections = result
    }

    private func keyTokens(from raw: String) -> [KeyToken] {
        let parts = raw.split(separator: "-").map(String.init)
        let modifierOrder = ["ctrl", "option", "shift", "cmd"]
        var modifiers = parts.filter { modifierSymbols[$0] != nil }
        modifiers.sort { (modifierOrder.firstIndex(of: $0) ?? 99) < (modifierOrder.firstIndex(of: $1) ?? 99) }
        let keys = parts.filter { modifierSymbols[$0] == nil }

        var tokens: [KeyToken] = []
        var tokenId = 0
        for mod in modifiers {
            tokens.append(KeyToken(id: tokenId, label: modifierSymbols[mod] ?? mod, isModifier: true))
            tokenId += 1
        }
        for key in keys {
            tokens.append(KeyToken(id: tokenId, label: keyLabel(key), isModifier: false))
            tokenId += 1
        }
        return tokens
    }

    private func keyLabel(_ raw: String) -> String {
        if let special = specialKeySymbols[raw] { return special }
        return raw.count == 1 ? raw.uppercased() : raw.capitalized
    }
}

private let modifierSymbols: [String: String] = [
    "ctrl": "\u{2303}",   // ⌃
    "option": "\u{2325}", // ⌥
    "shift": "\u{21E7}",  // ⇧
    "cmd": "\u{2318}",    // ⌘
]

private let specialKeySymbols: [String: String] = [
    "enter": "\u{21A9}",  // ↩
    "return": "\u{21A9}",
    "space": "Space",
    "tab": "\u{21E5}",    // ⇥
    "esc": "\u{238B}",    // ⎋
    "escape": "\u{238B}",
    "delete": "\u{232B}", // ⌫
    "backspace": "\u{232B}",
    "left": "\u{2190}",   // ←
    "right": "\u{2192}",  // →
    "up": "\u{2191}",     // ↑
    "down": "\u{2193}",   // ↓
    "minus": "\u{2212}",  // −
    "equal": "=",
    "slash": "/",
    "backslash": "\\",
    "comma": ",",
    "period": ".",
    "semicolon": ";",
    "quote": "'",
    "backtick": "`",
    "leftSquareBracket": "[",
    "rightSquareBracket": "]",
]
