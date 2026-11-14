import Common
import SwiftUI

// MARK: - Model

/// One row of the shortcuts list: a binding, or several bindings that follow one workspace pattern.
struct Shortcut: Equatable {
    let tokens: [KeyToken]
    let action: String
    /// Lowercased raw key notation (e.g. "option-shift-h") plus the action, so the filter
    /// can match by key names ("shift", "cmd", "backspace") even though we render symbols.
    /// A collapsed row carries the text of every binding it stands for.
    let searchText: String

    func matches(_ query: String) -> Bool {
        searchText.contains(query) || tokens.contains { $0.label.lowercased().contains(query) }
    }
}

struct KeyToken: Identifiable, Equatable {
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

/// The list rows for one mode's bindings, sorted by key notation. Bindings that differ only by
/// the workspace they target, each on the key named like its workspace (`option-1 = 'workspace 1'`,
/// `option-2 = 'workspace 2'`), collapse into one row such as "⌥ 1–9 → workspace <n>".
func keybindingShortcuts(_ bindings: [HotkeyBinding]) -> [Shortcut] {
    let sorted = bindings.sorted { $0.descriptionWithKeyNotation < $1.descriptionWithKeyNotation }
    var groups: [WorkspacePattern: [HotkeyBinding]] = [:]
    for binding in sorted {
        if let pattern = workspacePattern(of: binding) { groups[pattern, default: []].append(binding) }
    }
    var collapsed: Set<WorkspacePattern> = []
    var result: [Shortcut] = []
    for binding in sorted {
        if let pattern = workspacePattern(of: binding), let group = groups[pattern], group.count > 1 {
            if collapsed.insert(pattern).inserted { result.append(collapsedShortcut(pattern, group)) }
        } else {
            let action = actionDescription(binding)
            result.append(Shortcut(
                tokens: keyTokens(fromNotation: binding.descriptionWithKeyNotation),
                action: action,
                searchText: "\(binding.descriptionWithKeyNotation) \(action)".lowercased(),
            ))
        }
    }
    return result
}

func keyTokens(fromNotation raw: String) -> [KeyToken] {
    let parts = notationParts(raw)
    return keyTokens(modifiers: parts.modifiers, keyLabels: parts.keys.map(keyLabel))
}

private struct WorkspacePattern: Hashable {
    let modifiers: [String]
    /// The binding's commands with the workspace name replaced by `workspacePlaceholder`
    let action: String
}

private let workspacePlaceholder = "<n>"

private func actionDescription(_ binding: HotkeyBinding) -> String {
    binding.commands.map { $0.args.description }.joined(separator: ", ")
}

/// Nil unless the binding targets exactly one workspace by name and sits on the key of that name.
/// Then "⌥ 1–9 → workspace <n>" loses nothing: key n goes to workspace n.
private func workspacePattern(of binding: HotkeyBinding) -> WorkspacePattern? {
    let parts = notationParts(binding.descriptionWithKeyNotation)
    guard let key = parts.keys.singleOrNil() else { return nil }
    var targets: Set<String> = []
    var actions: [String] = []
    for command in binding.commands {
        let target: WorkspaceTarget? = switch command.args {
            case let args as WorkspaceCmdArgs: args.target.val
            case let args as MoveNodeToWorkspaceCmdArgs: args.target.val
            default: nil
        }
        let description = command.args.description
        guard let name = target?.workspaceNameOrNil()?.raw else {
            actions.append(description)
            continue
        }
        var words = description.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        // Anything else can't be told apart from a flag or the command name
        guard let index = words.indices.filter({ words[$0] == name }).singleOrNil() else { return nil }
        words[index] = workspacePlaceholder
        targets.insert(name)
        actions.append(words.joined(separator: " "))
    }
    guard let name = targets.singleOrNil(), name.lowercased() == key.lowercased() else { return nil }
    return WorkspacePattern(modifiers: parts.modifiers, action: actions.joined(separator: ", "))
}

private func collapsedShortcut(_ pattern: WorkspacePattern, _ group: [HotkeyBinding]) -> Shortcut {
    let keys = group.compactMap { notationParts($0.descriptionWithKeyNotation).keys.singleOrNil() }
    let searchText = group.map { "\($0.descriptionWithKeyNotation) \(actionDescription($0))" } + [pattern.action]
    return Shortcut(
        tokens: keyTokens(modifiers: pattern.modifiers, keyLabels: keyRangeLabels(keys)),
        action: pattern.action,
        searchText: searchText.joined(separator: " ").lowercased(),
    )
}

/// Labels for a set of keys, with three or more neighboring digits or letters joined into a
/// range: `["1", "2", "3", "a", "c"]` gives `["1–3", "A", "C"]`.
func keyRangeLabels(_ keys: [String]) -> [String] {
    let singles = keys.filter { $0.unicodeScalars.count == 1 }.compactMap { $0.lowercased().unicodeScalars.first }.sorted { $0.value < $1.value }
    let named = keys.filter { $0.unicodeScalars.count != 1 }.sorted()
    var runs: [[Unicode.Scalar]] = []
    for scalar in singles {
        let isAlphanumeric = scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        if let last = runs.last?.last, isAlphanumeric, scalar.value == last.value + 1 {
            runs[runs.count - 1].append(scalar)
        } else if runs.last?.last != scalar {
            runs.append([scalar])
        }
    }
    let labels = runs.flatMap { run in
        let labels = run.map { keyLabel(String($0)) }
        return labels.count >= 3 ? ["\(labels[0])\u{2013}\(labels[labels.count - 1])"] : labels
    }
    return labels + named.map(keyLabel)
}

/// Splits "option-shift-h" into its modifiers, in ⌃⌥⇧⌘ order, and the rest.
private func notationParts(_ raw: String) -> (modifiers: [String], keys: [String]) {
    let parts = raw.split(separator: "-").map(String.init)
    let modifierOrder = ["ctrl", "option", "shift", "cmd"]
    var modifiers = parts.filter { modifierSymbols[$0] != nil }
    modifiers.sort { (modifierOrder.firstIndex(of: $0) ?? 99) < (modifierOrder.firstIndex(of: $1) ?? 99) }
    return (modifiers, parts.filter { modifierSymbols[$0] == nil })
}

private func keyTokens(modifiers: [String], keyLabels: [String]) -> [KeyToken] {
    let labels = modifiers.map { (modifierSymbols[$0] ?? $0, true) } + keyLabels.map { ($0, false) }
    return labels.enumerated().map { KeyToken(id: $0.offset, label: $0.element.0, isModifier: $0.element.1) }
}

private func keyLabel(_ raw: String) -> String {
    if let special = specialKeySymbols[raw] { return special }
    return raw.count == 1 ? raw.uppercased() : raw.capitalized
}

// MARK: - View

/// The searchable list on the Shortcuts tab. Read-only: bindings are edited in the config file
/// or on the keyboard view.
struct KeybindingsListView: View {
    /// Republished on every config reload, so the list follows the config while it is open
    @ObservedObject var model: TrayMenuModel
    @State private var searchText: String = ""

    var body: some View {
        let sections = modeSections()
        VStack(alignment: .leading, spacing: 0) {
            if sections.isEmpty {
                emptyState
            } else {
                searchField
                if !config.enableKeyboardShortcuts { shortcutsOffNotice }
                Divider()
                content(sections)
            }
        }
    }

    private func filtered(_ sections: [ModeSection]) -> [ModeSection] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let matches = section.shortcuts.filter { $0.matches(query) }
            guard !matches.isEmpty else { return nil }
            return ModeSection(id: section.id, title: section.title, accent: section.accent, shortcuts: matches)
        }
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

    private var shortcutsOffNotice: some View {
        SettingsNotice(text: "Keyboard shortcuts are off in General. Only the app switching keys and the quick switcher are active.")
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

    private func content(_ sections: [ModeSection]) -> some View {
        ScrollView {
            let visible = filtered(sections)
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

    @MainActor private func modeSections() -> [ModeSection] {
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .green, .indigo]
        var result: [ModeSection] = []
        for (modeName, mode) in config.modes.sorted(by: { $0.key < $1.key }) {
            var shortcuts = keybindingShortcuts(Array(mode.bindings.values))
            // Registered on its own, outside the modes. See `registerQuickSwitcherHotkey`
            if modeName == mainModeId, config.quickSwitcher.enabled {
                let notation = config.quickSwitcher.binding
                shortcuts.insert(Shortcut(tokens: keyTokens(fromNotation: notation), action: "Quick Switcher", searchText: "\(notation) quick switcher".lowercased()), at: 0)
            }
            guard !shortcuts.isEmpty else { continue }
            let title = modeName == mainModeId ? "Global" : modeName
            let accent = modeName == mainModeId ? Color.accentColor : palette[result.count % palette.count]
            result.append(ModeSection(id: result.count, title: title, accent: accent, shortcuts: shortcuts))
        }
        return result
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
