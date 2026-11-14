import AppKit
import Common
import Foundation
import SwiftUI

@MainActor
public func menuBar(viewModel: TrayMenuModel) -> some Scene {
    MenuBarExtra {
        let hints = currentMenuShortcutHints()
        if let token: RunSessionGuard = .isServerEnabled {
            let workspaces = menuWorkspaces(viewModel.workspaces)
            ForEach(workspaces.shown, id: \.name) { workspace in
                workspaceMenuItem(workspace, token, hints.workspaces[workspace.name])
            }
            if !workspaces.empty.isEmpty {
                Menu("Empty Workspaces") {
                    ForEach(workspaces.empty, id: \.name) { workspace in
                        workspaceMenuItem(workspace, token, hints.workspaces[workspace.name])
                    }
                }
            }
            Button("Rename Current Workspace…") {
                renameWorkspaceFromMenu(viewModel.workspaces.first(where: \.isFocused)?.name ?? focus.workspace.name, token)
            }
            Divider()
        }
        // Paused Airlock can't act on their selections
        Button("Quick Switcher") {
            toggleQuickSwitcher()
        }
        .keyboardShortcut(hints.quickSwitcher)
        .disabled(!viewModel.isEnabled)
        Button("Workspace Overview") {
            toggleMissionControl()
        }
        .keyboardShortcut(hints.workspaceOverview)
        .disabled(!viewModel.isEnabled)
        Divider()
        let wasEnabled = viewModel.isEnabled
        Button(wasEnabled ? "Pause \(airlockAppName)" : "Resume \(airlockAppName)") {
            let requestedState: EnableCmdArgs.State = wasEnabled ? .off : .on
            Task {
                await withErrorReporting("Pausing or resuming Airlock", userMessage: "Airlock could not change its running state.") {
                    try await runEnableCommandFromUi(requestedState)
                }
            }
        }
        .keyboardShortcut(hints.pauseOrResume)
        Divider()
        Button("Settings…") {
            showSettings()
        }.keyboardShortcut(",", modifiers: .command)
        openConfigButton()
        reloadConfigButton(menuShortcut: hints.reloadConfig)
        Divider()
        CheckForUpdatesButton()
        Button("About \(airlockAppName)") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(options: [
                .applicationName: airlockAppName,
                .applicationVersion: airlockAppVersion,
                .version: gitShortHash,
            ])
        }
        Button("Copy Version (\(airlockAppVersion) \(gitShortHash))") {
            "\(airlockAppName) v\(airlockAppVersion) \(gitHash)".copyToClipboard()
        }
        Button("Quit \(airlockAppName)") {
            Task {
                defer { terminateApp() }
                await withErrorReporting("Restoring windows before quitting") {
                    try await terminationHandler.beforeTermination()
                }
            }
        }.keyboardShortcut("Q", modifiers: .command)
    } label: {
        if viewModel.isEnabled {
            MenuBarLabel().environmentObject(viewModel)
        } else {
            Image(systemName: "pause.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}

// MARK: - Workspaces

/// The top level of the menu lists the workspaces in use: those with windows, shown on a monitor,
/// or focused. The rest, mostly idle `persistent-workspaces`, go into a submenu.
func menuWorkspaces(_ workspaces: [WorkspaceViewModel]) -> (shown: [WorkspaceViewModel], empty: [WorkspaceViewModel]) {
    let isInUse = { (workspace: WorkspaceViewModel) in !workspace.isEffectivelyEmpty || workspace.isVisible || workspace.isFocused }
    return (workspaces.filter(isInUse), workspaces.filter { !isInUse($0) })
}

/// A checkmark item that switches to the workspace when clicked.
@MainActor
private func workspaceMenuItem(_ workspace: WorkspaceViewModel, _ token: RunSessionGuard, _ shortcut: KeyboardShortcut?) -> some View {
    let isFocused = Binding(
        get: { workspace.isFocused },
        set: { _ in
            Task {
                await withErrorReporting("Switching workspace", userMessage: "Airlock could not switch workspace.") {
                    try await runLightSession(.menuBarButton, token) { focusWorkspaceFromUi(Workspace.get(byName: workspace.name)) }
                }
            }
        },
    )
    return Toggle(isOn: isFocused) {
        Text(workspace.name + workspace.suffix).font(.system(.body, design: .monospaced))
    }
    .keyboardShortcut(shortcut)
}

@MainActor
private func renameWorkspaceFromMenu(_ currentName: String, _ token: RunSessionGuard) {
    Task {
        guard let newName = showRenameDialog(currentName: currentName) else { return }
        await withErrorReporting("Renaming workspace", userMessage: "Airlock could not rename the workspace.") {
            try await runLightSession(.menuBarButton, token) {
                // The dialog already checked the name, which leaves the config file as the likely cause
                if try await !Workspace.rename(Workspace.get(byName: currentName), to: newName) {
                    MessageModel.shared.message = Message(
                        description: "Can't Rename Workspace",
                        body: "Can't rename workspace '\(currentName)' to '\(newName)'. The config file couldn't be updated, or the name was taken in the meantime",
                    )
                }
            }
        }
    }
}

// MARK: - Shortcut hints

/// Key equivalents shown next to menu items. Every one is a binding from the user's config that
/// is registered right now, so the menu teaches keys that also work with the menu closed.
struct MenuShortcutHints: Equatable {
    var quickSwitcher: KeyboardShortcut? = nil
    var workspaceOverview: KeyboardShortcut? = nil
    var pauseOrResume: KeyboardShortcut? = nil
    var reloadConfig: KeyboardShortcut? = nil
    /// By workspace name
    var workspaces: [String: KeyboardShortcut] = [:]
}

@MainActor
func currentMenuShortcutHints() -> MenuShortcutHints {
    menuShortcutHints(
        bindings: Array(hotkeyBindings(for: hotkeyDispatchMode).values),
        quickSwitcherBinding: isQuickSwitcherHotkeyRegistered ? config.quickSwitcher.binding : nil,
        isEnabled: sessionCoordinator.isEnabled,
    )
}

/// `bindings` are the registered ones. `quickSwitcherBinding` is nil while its hotkey isn't registered.
/// Only a binding that runs exactly the menu item's action counts, so pressing the hint does what the item does.
func menuShortcutHints(bindings: [HotkeyBinding], quickSwitcherBinding: String?, isEnabled: Bool) -> MenuShortcutHints {
    var hints = MenuShortcutHints(quickSwitcher: quickSwitcherBinding.flatMap(menuKeyboardShortcut))
    // Sorted, so the pick among several bindings for one action doesn't change between menu openings
    for binding in bindings.sorted(by: { $0.descriptionWithKeyNotation > $1.descriptionWithKeyNotation }) {
        guard let command = binding.commands.singleOrNil(), let shortcut = menuKeyboardShortcut(binding.descriptionWithKeyNotation) else { continue }
        switch command.args {
            // Both names are accepted during the Workspace Overview command rename.
            case _ where ["mission-control", "workspace-overview"].contains(command.args.kind.rawValue):
                hints.workspaceOverview = shortcut
            case is ReloadConfigCmdArgs:
                hints.reloadConfig = shortcut
            case let args as EnableCmdArgs where args.targetState.val == .toggle || args.targetState.val == (isEnabled ? .off : .on):
                hints.pauseOrResume = shortcut
            // With --auto-back-and-forth the key leaves the workspace it is already on. The menu item doesn't
            case let args as WorkspaceCmdArgs where !args.autoBackAndForth:
                if let name = args.target.val.workspaceNameOrNil()?.raw { hints.workspaces[name] = shortcut }
            default:
                break
        }
    }
    return hints
}

/// The menu key equivalent for a binding written in config notation, such as "option-space".
/// Nil for keys a menu can't show (keypad and function keys) and for the two shortcuts the menu owns.
func menuKeyboardShortcut(_ notation: String) -> KeyboardShortcut? {
    let parts = notation.split(separator: "-").map(String.init)
    guard let keyName = parts.last else { return nil }
    var modifiers: EventModifiers = []
    for part in parts.dropLast() {
        switch part {
            case "cmd": modifiers.insert(.command)
            case "option": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            default: return nil
        }
    }
    let key: KeyEquivalent? = menuKeyEquivalents[keyName] ?? keyName.lowercased().singleOrNil().map { KeyEquivalent($0) }
    guard let key, !(modifiers == .command && (key == "," || key == "q")) else { return nil }
    return KeyboardShortcut(key, modifiers: modifiers)
}

private let menuKeyEquivalents: [String: KeyEquivalent] = [
    "space": .space,
    "tab": .tab,
    "enter": .return,
    "esc": .escape,
    "backspace": .delete,
    "forwardDelete": .deleteForward,
    "left": .leftArrow,
    "right": .rightArrow,
    "up": .upArrow,
    "down": .downArrow,
    "home": .home,
    "end": .end,
    "pageUp": .pageUp,
    "pageDown": .pageDown,
    "minus": "-",
    "equal": "=",
    "comma": ",",
    "period": ".",
    "slash": "/",
    "backslash": "\\",
    "semicolon": ";",
    "quote": "'",
    "backtick": "`",
    "leftSquareBracket": "[",
    "rightSquareBracket": "]",
]

// MARK: - Config file

/// `showShortcutGroup` is the message window's form, a button under its ⌘ , hint. The menu gives ⌘ , to Settings.
@MainActor @ViewBuilder
func openConfigButton(showShortcutGroup: Bool = false) -> some View {
    let editor = getTextEditorToOpenConfig()
    let button = Button(showShortcutGroup ? "Open config in '\(editor.lastPathComponent)'" : "Open Config File") {
        let fallbackConfig: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: configDotfileName)
        switch findCustomConfigUrl() {
            case .file(let url):
                url.open(with: editor)
            case .noCustomConfigExists:
                do {
                    try FileManager.default.copyItem(atPath: defaultConfigUrl.path, toPath: fallbackConfig.path)
                    fallbackConfig.open(with: editor)
                } catch {
                    reportAppError(error, operation: "Creating the configuration file", userMessage: "Airlock could not create your configuration file.")
                }
            case .ambiguousConfigError:
                fallbackConfig.open(with: editor)
        }
    }
    if showShortcutGroup {
        shortcutGroup(label: Text("⌘ ,"), content: button.keyboardShortcut(",", modifiers: .command))
    } else {
        button
    }
}

/// `showShortcutGroup` is the message window's form, a button under its ⌘ R hint. The menu shows
/// `menuShortcut`, the user's own binding for reloading, if there is one.
@MainActor @ViewBuilder
func reloadConfigButton(showShortcutGroup: Bool = false, menuShortcut: KeyboardShortcut? = nil) -> some View {
    if let token: RunSessionGuard = .isServerEnabled {
        let button = Button(showShortcutGroup ? "Reload config" : "Reload Config") {
            Task {
                await withErrorReporting("Reloading configuration", userMessage: "Airlock could not reload the configuration.") {
                    try await runLightSession(.menuBarButton, token) { _ = try await reloadConfig() }
                }
            }
        }
        if showShortcutGroup {
            shortcutGroup(label: Text("⌘ R"), content: button.keyboardShortcut("R", modifiers: .command))
        } else {
            button.keyboardShortcut(menuShortcut)
        }
    }
}

func shortcutGroup(label: some View, content: some View) -> some View {
    GroupBox {
        VStack(alignment: .trailing, spacing: 6) {
            label
                .foregroundStyle(Color.secondary)
            content
        }
    }
}

/// Asks for a new workspace name. Returns nil if the user cancels.
@MainActor
func showRenameDialog(currentName: String) -> String? {
    let dialog = RenameDialog(currentName: currentName)
    NSApp.activate(ignoringOtherApps: true)
    return dialog.alert.runModal() == .alertFirstButtonReturn ? dialog.acceptedName : nil
}

/// The rename alert. The name is checked as it is typed: Rename stays off until `Workspace.rename`
/// would take the name, and a taken or invalid name says why under the field.
@MainActor
final class RenameDialog: NSObject, NSTextFieldDelegate {
    let alert = NSAlert()
    let textField: NSTextField
    let problemLabel = NSTextField(wrappingLabelWithString: "")
    let renameButton: NSButton
    private let currentName: String

    init(currentName: String) {
        self.currentName = currentName
        alert.messageText = "Rename Workspace"
        alert.informativeText = "Enter a new name for workspace '\(currentName)':"
        renameButton = alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 260
        problemLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        problemLabel.textColor = .systemRed
        // Room for two lines, so the alert doesn't have to resize while typing
        problemLabel.frame = NSRect(x: 0, y: 0, width: width, height: 30)
        textField = NSTextField(frame: NSRect(x: 0, y: 36, width: width, height: 24))
        textField.stringValue = currentName
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        accessory.addSubview(textField)
        accessory.addSubview(problemLabel)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = textField
        super.init()
        textField.delegate = self
        validate()
    }

    /// The typed name, or nil while it has a problem
    var acceptedName: String? {
        let name = textField.stringValue.trimmingCharacters(in: .whitespaces)
        return workspaceRenameProblem(currentName: currentName, newName: name) == nil ? name : nil
    }

    func controlTextDidChange(_ notification: Notification) { validate() }

    func validate() {
        let problem = workspaceRenameProblem(currentName: currentName, newName: textField.stringValue.trimmingCharacters(in: .whitespaces))
        renameButton.isEnabled = problem == nil
        problemLabel.stringValue = problem?.message ?? ""
    }
}

/// Why `Workspace.rename` would refuse a name
enum WorkspaceRenameProblem: Equatable {
    case empty
    case unchanged
    case taken(String)
    case invalid(String)

    /// Shown under the text field. Nil where a disabled Rename button says enough
    var message: String? {
        switch self {
            case .empty, .unchanged: nil
            case .taken(let name): "A workspace named '\(name)' already exists."
            case .invalid(let reason): reason
        }
    }
}

/// The checks `Workspace.rename` makes before it touches the config file, with the reason for each.
/// `newName` is the name as it would be used, already trimmed.
@MainActor
func workspaceRenameProblem(currentName: String, newName: String) -> WorkspaceRenameProblem? {
    if newName.isEmpty { return .empty }
    if newName == currentName { return .unchanged }
    if case .failure(let reason) = WorkspaceName.parse(newName) { return .invalid(reason) }
    if let reason = unwritableNameReason(newName) { return .invalid(reason) }
    if let reason = unwritableNameReason(currentName) { return .invalid("Workspace '\(currentName)' can't be renamed. \(reason)") }
    if Workspace.all.contains(where: { $0.name == newName }) { return .taken(newName) }
    return nil
}

/// A name with a quote or backslash, or one that reads as a command separator, can't be written
/// into, or reliably found in, the config's command strings
private func unwritableNameReason(_ name: String) -> String? {
    if commandSeparators.contains(name) { return "'\(name)' separates commands in the config, so it can't be a workspace name." }
    if name.contains(where: { $0 == "'" || $0 == "\"" || $0 == "\\" }) { return "A workspace name in the config can't contain a quote or a backslash." }
    return nil
}

func getTextEditorToOpenConfig() -> URL {
    NSWorkspace.shared.urlForApplication(toOpen: findCustomConfigUrl().urlOrNil ?? defaultConfigUrl)?
        .takeIf { $0.lastPathComponent != "Xcode.app" } // Blacklist Xcode. It is too heavy to open plain text files
        ?? URL(filePath: "/System/Applications/TextEdit.app")
}
