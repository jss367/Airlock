@testable import AppBundle
import Common
import SwiftUI
import XCTest

@MainActor
final class MenuBarTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    // MARK: - Workspaces

    func testMenuListsWorkspacesInUseAndTucksAwayTheRest() {
        config.persistentWorkspaces = ["1", "2", "3"]
        TestWindow.new(id: 1, parent: Workspace.get(byName: "2").rootTilingContainer)
        _ = Workspace.get(byName: "1")
        _ = Workspace.get(byName: "3")
        let focused = focus.workspace.name
        updateTrayText()

        let menu = menuWorkspaces(TrayMenuModel.shared.workspaces)

        // "2" has a window. The focused workspace is empty but shown on the monitor
        assertEquals(menu.shown.map(\.name), ["2", focused])
        assertEquals(menu.empty.map(\.name), ["1", "3"])
    }

    func testMenuHasNoEmptyWorkspacesWithoutWindowManagement() {
        config.enableWindowManagement = false
        config.persistentWorkspaces = ["1", "2"]
        _ = Workspace.get(byName: "1")
        _ = Workspace.get(byName: "2")
        updateTrayText()

        let menu = menuWorkspaces(TrayMenuModel.shared.workspaces)

        assertEquals(menu.shown.map(\.name), [focus.workspace.name])
        assertEquals(menu.empty.map(\.name), [])
    }

    // MARK: - Shortcut hints

    func testMenuKeyboardShortcutFromNotation() {
        assertEquals(menuKeyboardShortcut("option-space"), KeyboardShortcut(.space, modifiers: .option))
        assertEquals(menuKeyboardShortcut("option-shift-1"), KeyboardShortcut("1", modifiers: [.option, .shift]))
        assertEquals(menuKeyboardShortcut("cmd-ctrl-semicolon"), KeyboardShortcut(";", modifiers: [.command, .control]))
        assertEquals(menuKeyboardShortcut("option-A"), KeyboardShortcut("a", modifiers: .option))
        assertEquals(menuKeyboardShortcut("f13"), nil)
        assertEquals(menuKeyboardShortcut("option-keypad1"), nil)
    }

    func testMenuKeyboardShortcutLeavesTheMenusOwnKeysAlone() {
        assertEquals(menuKeyboardShortcut("cmd-comma"), nil)
        assertEquals(menuKeyboardShortcut("cmd-q"), nil)
        assertEquals(menuKeyboardShortcut("cmd-shift-comma"), KeyboardShortcut(",", modifiers: [.command, .shift]))
    }

    func testHintsComeFromBindingsThatRunExactlyTheMenuAction() {
        let bindings = parseBindings("""
            option-1 = 'workspace 1'
            option-2 = ['workspace 2', 'layout tiles']
            option-3 = 'workspace --auto-back-and-forth 3'
            option-shift-1 = 'move-node-to-workspace 1'
            option-n = 'workspace next'
            option-m = 'mission-control'
            option-r = 'reload-config'
            option-e = 'enable toggle'
            """)

        let hints = menuShortcutHints(bindings: bindings, quickSwitcherBinding: "option-space", isEnabled: true)

        assertEquals(hints.workspaces, ["1": KeyboardShortcut("1", modifiers: .option)])
        assertEquals(hints.quickSwitcher, KeyboardShortcut(.space, modifiers: .option))
        assertEquals(hints.workspaceOverview, KeyboardShortcut("m", modifiers: .option))
        assertEquals(hints.reloadConfig, KeyboardShortcut("r", modifiers: .option))
        assertEquals(hints.pauseOrResume, KeyboardShortcut("e", modifiers: .option))
    }

    func testDefaultConfigHintsWorkspaceKeys() {
        let hints = menuShortcutHints(bindings: Array(defaultConfig.modes[mainModeId]!.bindings.values), quickSwitcherBinding: nil, isEnabled: true)

        assertEquals(hints.workspaces["1"], KeyboardShortcut("1", modifiers: .option))
        assertEquals(hints.workspaces["A"], KeyboardShortcut("a", modifiers: .option))
        assertEquals(hints.quickSwitcher, nil)
    }

    func testNoHintsWithoutBindings() {
        assertEquals(menuShortcutHints(bindings: [], quickSwitcherBinding: nil, isEnabled: true), MenuShortcutHints())
    }

    func testPauseHintFollowsRunningState() {
        let bindings = parseBindings("""
            option-p = 'enable off'
            option-o = 'enable on'
            """)

        assertEquals(
            menuShortcutHints(bindings: bindings, quickSwitcherBinding: nil, isEnabled: true).pauseOrResume,
            KeyboardShortcut("p", modifiers: .option),
        )
        assertEquals(
            menuShortcutHints(bindings: bindings, quickSwitcherBinding: nil, isEnabled: false).pauseOrResume,
            KeyboardShortcut("o", modifiers: .option),
        )
    }

    // MARK: - Rename

    func testRenameProblems() {
        _ = Workspace.get(byName: "taken")
        TestWindow.new(id: 1, parent: Workspace.get(byName: "taken").rootTilingContainer)

        assertEquals(workspaceRenameProblem(currentName: "old", newName: ""), .empty)
        assertEquals(workspaceRenameProblem(currentName: "old", newName: "old"), .unchanged)
        assertEquals(workspaceRenameProblem(currentName: "old", newName: "taken"), .taken("taken"))
        assertEquals(workspaceRenameProblem(currentName: "old", newName: "new"), nil)
    }

    func testRenameRejectsNamesTheConfigCantHold() {
        for name in ["it's", "a\"b", "a\\b", "&&", ";", "next", "a,b"] {
            guard case .invalid(let reason) = workspaceRenameProblem(currentName: "old", newName: name) else {
                XCTFail("Expected '\(name)' to be invalid")
                continue
            }
            assertTrue(!reason.isEmpty)
        }
        guard case .invalid = workspaceRenameProblem(currentName: "it's", newName: "new") else {
            return XCTFail("A workspace whose name has a quote can't be renamed")
        }
    }

    func testRenameDialogValidatesWhileTyping() {
        _ = Workspace.get(byName: "taken")
        TestWindow.new(id: 1, parent: Workspace.get(byName: "taken").rootTilingContainer)
        let dialog = RenameDialog(currentName: "old")

        // Opens on the current name: nothing to rename to yet, and nothing to complain about
        assertEquals(dialog.renameButton.isEnabled, false)
        assertEquals(dialog.problemLabel.stringValue, "")
        assertNil(dialog.acceptedName)

        type("taken", into: dialog)
        assertEquals(dialog.renameButton.isEnabled, false)
        assertEquals(dialog.problemLabel.stringValue, "A workspace named 'taken' already exists.")

        type("it's", into: dialog)
        assertEquals(dialog.renameButton.isEnabled, false)
        assertEquals(dialog.problemLabel.stringValue, "A workspace name in the config can't contain a quote or a backslash.")

        type("", into: dialog)
        assertEquals(dialog.renameButton.isEnabled, false)
        assertEquals(dialog.problemLabel.stringValue, "")

        type(" new ", into: dialog)
        assertEquals(dialog.renameButton.isEnabled, true)
        assertEquals(dialog.problemLabel.stringValue, "")
        assertEquals(dialog.acceptedName, "new")
    }

    private func type(_ text: String, into dialog: RenameDialog) {
        dialog.textField.stringValue = text
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: dialog.textField))
    }

    func testOnlyNamedProblemsCarryAMessage() {
        assertNil(WorkspaceRenameProblem.empty.message)
        assertNil(WorkspaceRenameProblem.unchanged.message)
        assertEquals(WorkspaceRenameProblem.taken("web").message, "A workspace named 'web' already exists.")
        assertEquals(WorkspaceRenameProblem.invalid("why").message, "why")
    }
}

/// The bindings of a `[mode.main.binding]` table with the given entries, without the default ones
@MainActor
func parseBindings(_ entries: String, file: StaticString = #filePath, line: UInt = #line) -> [HotkeyBinding] {
    let (parsed, errors) = parseConfig("[mode.main.binding]\n" + entries, mergeWithDefaults: false)
    XCTAssertEqual(errors.descriptions, [], file: file, line: line)
    return Array(parsed.modes[mainModeId]?.bindings.values ?? [:].values)
}
