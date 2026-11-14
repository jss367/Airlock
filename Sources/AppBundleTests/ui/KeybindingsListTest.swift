@testable import AppBundle
import Common
import XCTest

@MainActor
final class KeybindingsListTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testWorkspaceBindingsCollapseIntoOneRowPerPattern() {
        let shortcuts = keybindingShortcuts(parseBindings("""
            option-1 = 'workspace 1'
            option-2 = 'workspace 2'
            option-3 = 'workspace 3'
            option-shift-1 = 'move-node-to-workspace 1'
            option-shift-2 = 'move-node-to-workspace 2'
            option-shift-3 = 'move-node-to-workspace 3'
            option-h = 'focus left'
            """))

        assertEquals(shortcuts.map(describe), [
            "⌥ 1–3 → workspace <n>",
            "⌥ H → focus left",
            "⌥ ⇧ 1–3 → move-node-to-workspace <n>",
        ])
    }

    func testSearchStillFindsCollapsedBindings() {
        let shortcuts = keybindingShortcuts(parseBindings("""
            option-1 = 'workspace 1'
            option-2 = 'workspace 2'
            option-3 = 'workspace 3'
            option-h = 'focus left'
            """))

        assertEquals(shortcuts.filter { $0.matches("workspace 2") }.map(describe), ["⌥ 1–3 → workspace <n>"])
        assertEquals(shortcuts.filter { $0.matches("option-3") }.map(describe), ["⌥ 1–3 → workspace <n>"])
        assertEquals(shortcuts.filter { $0.matches("workspace <n>") }.map(describe), ["⌥ 1–3 → workspace <n>"])
        assertEquals(shortcuts.filter { $0.matches("left") }.map(describe), ["⌥ H → focus left"])
        assertEquals(shortcuts.filter { $0.matches("workspace 4") }.map(describe), [])
    }

    func testOnlyBindingsOnTheKeyNamedLikeTheWorkspaceCollapse() {
        let shortcuts = keybindingShortcuts(parseBindings("""
            option-1 = 'workspace 1'
            option-2 = 'workspace 2'
            option-w = 'workspace web'
            option-m = 'workspace mail'
            option-n = 'workspace next'
            """))

        assertEquals(shortcuts.map(describe), [
            "⌥ 1 2 → workspace <n>",
            "⌥ M → workspace mail",
            "⌥ N → workspace next",
            "⌥ W → workspace web",
        ])
    }

    func testBindingsThatDifferByMoreThanTheWorkspaceStayApart() {
        let shortcuts = keybindingShortcuts(parseBindings("""
            option-1 = 'workspace 1'
            option-2 = 'workspace --auto-back-and-forth 2'
            option-shift-1 = ['move-node-to-workspace 1', 'workspace 1']
            option-shift-2 = ['move-node-to-workspace 2', 'workspace 2']
            option-shift-3 = ['move-node-to-workspace 3', 'workspace 4']
            """))

        assertEquals(shortcuts.map(describe), [
            "⌥ 1 → workspace 1",
            "⌥ 2 → workspace --auto-back-and-forth 2",
            "⌥ ⇧ 1 2 → move-node-to-workspace <n>, workspace <n>",
            "⌥ ⇧ 3 → move-node-to-workspace 3, workspace 4",
        ])
    }

    func testASingleWorkspaceBindingIsNotAPattern() {
        let shortcuts = keybindingShortcuts(parseBindings("option-1 = 'workspace 1'"))

        assertEquals(shortcuts.map(describe), ["⌥ 1 → workspace 1"])
    }

    func testKeyRangeLabels() {
        assertEquals(keyRangeLabels(["3", "1", "2", "9", "8", "7", "5"]), ["1–3", "5", "7–9"])
        assertEquals(keyRangeLabels(["a", "b", "c", "d", "i", "m", "n"]), ["A–D", "I", "M", "N"])
        assertEquals(keyRangeLabels(["1", "2", "3", "a", "b", "c"]), ["1–3", "A–C"])
        assertEquals(keyRangeLabels(["9", "a"]), ["9", "A"])
        assertEquals(keyRangeLabels(["f1", "1"]), ["1", "F1"])
    }

    func testDefaultConfigWorkspaceRows() {
        let shortcuts = keybindingShortcuts(Array(defaultConfig.modes[mainModeId]!.bindings.values))
        let rows = shortcuts.map(describe)

        assertEquals(rows.filter { $0.contains("workspace <n>") }, [
            "⌥ 1–9 A–G I M–Z → workspace <n>",
            "⌥ ⇧ 1–9 A–G I M–Z → move-node-to-workspace <n>",
        ])
    }

    private func describe(_ shortcut: Shortcut) -> String {
        shortcut.tokens.map(\.label).joined(separator: " ") + " → " + shortcut.action
    }
}
