import AppKit
import Common
import HotKey

// The Shortcuts list edits bindings through a sheet (ShortcutEditorView.swift). This file holds what
// the sheet works with: the draft, its checks, the key recorder, and the list of suggested commands.

// MARK: - Draft

/// A binding as the editor holds it. `commands` are command lines, one per command.
struct ShortcutDraft: Equatable {
    var mode: String
    var binding: String
    var commands: [String]

    var address: BindingAddress { BindingAddress(mode: mode.trimmingCharacters(in: .whitespaces), binding: binding.trimmingCharacters(in: .whitespaces)) }
    /// Blank command rows are left out. The editor always shows one, to type the first command into
    var writtenCommands: [String] { commands.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

/// What the editor was opened on. `original` is nil for a new binding.
struct ShortcutEditorTarget: Identifiable {
    let id = UUID()
    let original: BindingAddress?
    let draft: ShortcutDraft
}

/// What keeps a draft from being saved, by the field to show it under
struct ShortcutDraftProblems: Equatable {
    var mode: String? = nil
    var binding: String? = nil
    /// By index into `ShortcutDraft.commands`
    var commands: [Int: String] = [:]

    var isEmpty: Bool { mode == nil && binding == nil && commands.isEmpty }
}

/// `existingModes` are the modes the config has. Any other mode name is a new mode, which the
/// config writer can only create under a bare TOML key.
func shortcutDraftProblems(_ draft: ShortcutDraft, existingModes: Set<String>, keyMapping: [String: Key]) -> ShortcutDraftProblems {
    var problems = ShortcutDraftProblems()
    let address = draft.address
    if address.mode.isEmpty {
        problems.mode = "Name the mode."
    } else if !existingModes.contains(address.mode), tomlKey(address.mode) != address.mode {
        problems.mode = "Use letters, digits, '-' and '_' in a mode name."
    }
    if address.binding.isEmpty {
        problems.binding = "Record a shortcut, or type one like ctrl-option-k."
    } else if case .failure = parseBinding(address.binding, .emptyRoot, keyMapping) {
        problems.binding = "'\(address.binding)' isn't a key Airlock can bind. Write it like ctrl-option-k."
    }
    for (index, command) in draft.commands.enumerated() where !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if case .failure(let message) = parseConfigCommand(command) {
            // The parser answers a bad command with its whole usage text. The first line says what is wrong
            problems.commands[index] = message.split(separator: "\n").first.map(String.init) ?? message
        }
    }
    if draft.writtenCommands.isEmpty, problems.commands.isEmpty {
        problems.commands[0] = "Type a command, or pick one from the list."
    }
    return problems
}

/// What the draft's key already runs in its mode, when that is some other binding than the one being
/// edited. Saving replaces it, so the editor says so first. Nil when the key is free.
@MainActor
func shortcutDraftReplaces(_ draft: ShortcutDraft, original: BindingAddress?) -> String? {
    let keyMapping = config.keyMapping.resolve()
    guard case .success(let (modifiers, key)) = parseBinding(draft.address.binding, .emptyRoot, keyMapping) else { return nil }
    if let original, original.mode == draft.address.mode,
       case .success(let (originalModifiers, originalKey)) = parseBinding(original.binding, .emptyRoot, keyMapping),
       originalModifiers == modifiers, originalKey == key
    {
        return nil
    }
    let combo = HotkeyBinding(modifiers, key, [], descriptionWithKeyNotation: draft.address.binding).descriptionWithKeyCode
    return config.modes[draft.address.mode]?.bindings[combo].map { $0.commands.map { $0.args.description }.joined(separator: ", ") }
}

/// The commands of `binding` as its config file writes them, for the editor to start from. A parsed
/// command prints back normalized, which would rewrite a hand-formatted script on the first save.
@MainActor
func editableCommandTexts(of binding: HotkeyBinding, mode: String) -> [String] {
    let address = BindingAddress(mode: mode, binding: binding.descriptionWithKeyNotation)
    let keyMapping = config.keyMapping.resolve()
    for url in [configUrl, defaultConfigUrl] {
        if let text = try? String(contentsOf: url, encoding: .utf8), let commands = bindingCommandTexts(inToml: text, address, keyMapping: keyMapping), !commands.isEmpty {
            return commands
        }
    }
    return binding.commands.map { $0.args.description }
}

// MARK: - Recording

/// The config notation of a pressed key, modifiers in ⌃⌥⇧⌘ order: `ctrl-option-shift-cmd-k`.
/// Nil for a key the config has no name for.
func recordedBindingNotation(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, keyMapping: [String: Key]) -> String? {
    guard let key = Key(carbonKeyCode: UInt32(keyCode)), let name = configKeyNotation(for: key, in: keyMapping) else { return nil }
    let names: [(NSEvent.ModifierFlags, String)] = [(.control, "ctrl"), (.option, "option"), (.shift, "shift"), (.command, "cmd")]
    return (names.filter { modifiers.contains($0.0) }.map(\.1) + [name]).joined(separator: "-")
}

/// Records the next key press in the Settings window as a binding. Esc alone cancels.
/// Airlock's own hotkeys are off while it records, see `isRecordingShortcut`, so every way out of
/// recording has to go through `stop()`: a key, Esc, the button, the sheet closing, the window
/// losing focus or closing.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    var onRecord: (String) -> Void = { _ in }
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording else { return }
        isRecording = true
        setRecordingShortcut(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let isEscape = event.keyCode == Key.escape.carbonKeyCode && modifiers.isEmpty
            if !isEscape, let notation = recordedBindingNotation(keyCode: event.keyCode, modifiers: modifiers, keyMapping: config.keyMapping.resolve()) {
                onRecord(notation)
            }
            stop()
            return nil
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification, settingsWindowWillClose] {
            // Synchronously: the Settings window drops its views, and this recorder with them, right after it posts
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            })
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        setRecordingShortcut(false)
    }
}

// MARK: - Suggestions

/// A command the editor offers by a plain name, so binding a key doesn't take knowing the command syntax
struct CommandSuggestion: Identifiable, Equatable {
    let title: String
    let command: String

    var id: String { command }

    /// Every word of `query` must be in the title or the command
    func matches(_ query: String) -> Bool {
        let haystack = "\(title) \(command)".lowercased()
        return query.lowercased().split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}

/// `modes` other than main, `workspaces`, and `apps` come from the running config and system.
func commandSuggestions(modes: [String], workspaces: [String], apps: [String]) -> [CommandSuggestion] {
    let sides = ["left", "right"]
    var result: [CommandSuggestion] = [
        CommandSuggestion(title: "Focus the window on the left", command: "focus left"),
        CommandSuggestion(title: "Focus the window below", command: "focus down"),
        CommandSuggestion(title: "Focus the window above", command: "focus up"),
        CommandSuggestion(title: "Focus the window on the right", command: "focus right"),
    ]
    result += ["left", "down", "up", "right"].map { CommandSuggestion(title: "Move the window \($0)", command: "move \($0)") }
    result += [
        CommandSuggestion(title: "Place the window on the left half", command: "window-frame left-half"),
        CommandSuggestion(title: "Place the window on the right half", command: "window-frame right-half"),
        CommandSuggestion(title: "Center the window", command: "window-frame center"),
        CommandSuggestion(title: "Give the window a comfortable size", command: "window-frame comfortable"),
        CommandSuggestion(title: "Make the window fill the workspace", command: "fullscreen"),
        CommandSuggestion(title: "Make the window larger", command: "resize smart +50"),
        CommandSuggestion(title: "Make the window smaller", command: "resize smart -50"),
        CommandSuggestion(title: "Close the window", command: "close"),
        CommandSuggestion(title: "Close every other window on the workspace", command: "close-all-windows-but-current"),
        CommandSuggestion(title: "Minimize the window", command: "macos-native-minimize"),
        CommandSuggestion(title: "Float or tile the window", command: "layout floating tiling"),
        CommandSuggestion(title: "Tile the workspace", command: "layout tiles horizontal vertical"),
        CommandSuggestion(title: "Stack the workspace as an accordion", command: "layout accordion horizontal vertical"),
        CommandSuggestion(title: "Make the tiled windows the same size", command: "balance-sizes"),
        CommandSuggestion(title: "Reset the workspace layout", command: "flatten-workspace-tree"),
    ]
    result += sides.map { CommandSuggestion(title: "Move the window to the monitor on the \($0)", command: "move-node-to-monitor --focus-follows-window \($0)") }
    result += sides.map { CommandSuggestion(title: "Focus the monitor on the \($0)", command: "focus-monitor \($0)") }
    result += [
        CommandSuggestion(title: "Move the workspace to the next monitor", command: "move-workspace-to-monitor --wrap-around next"),
        CommandSuggestion(title: "Go back to the previous workspace", command: "workspace-back-and-forth"),
        CommandSuggestion(title: "Go to the window that asked for attention", command: "focus-attention"),
        CommandSuggestion(title: "Open the Workspace Overview", command: "workspace-overview"),
        CommandSuggestion(title: "Open the App Launcher", command: "app-launcher"),
        CommandSuggestion(title: "Pause or resume Airlock", command: "enable toggle"),
        CommandSuggestion(title: "Reload the config", command: "reload-config"),
        CommandSuggestion(title: "Return to the main mode", command: "mode \(mainModeId)"),
    ]
    // A name with whitespace or a quote would need quoting that depends on the name
    let plain = { (name: String) in !name.isEmpty && name.allSatisfy { !$0.isWhitespace && $0 != "'" && $0 != "\"" } }
    result += modes.filter(plain).map { CommandSuggestion(title: "Enter the \($0) mode", command: "mode \($0)") }
    result += workspaces.filter(plain).map { CommandSuggestion(title: "Go to workspace \($0)", command: "workspace \($0)") }
    result += workspaces.filter(plain).map { CommandSuggestion(title: "Move the window to workspace \($0)", command: "move-node-to-workspace \($0)") }
    result += apps.filter(canRepresentAppName).map { CommandSuggestion(title: "Open \($0)", command: summonAppCommand(appName: $0)) }
    result.append(CommandSuggestion(title: "Run a shell command, such as opening a folder", command: "exec-and-forget open ~/Downloads"))
    return result
}

@MainActor
func currentCommandSuggestions(apps: [String]) -> [CommandSuggestion] {
    let workspaces = (Array(config.persistentWorkspaces) + Workspace.all.map(\.name)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    return commandSuggestions(modes: config.modes.keys.filter { $0 != mainModeId }.sorted(), workspaces: workspaces, apps: apps)
}
