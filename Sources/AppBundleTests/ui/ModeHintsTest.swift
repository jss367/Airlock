@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class ModeHintsTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        sessionCoordinator.setEnabled(true)
        activeMode = mainModeId
    }

    override func tearDown() async throws {
        sessionCoordinator.setEnabled(true)
        activeMode = mainModeId
    }

    func testRowsDropTheTrailingReturnToMainAndListLeavingKeysLast() {
        let hints = modeHints(mode: "window", bindings: parseBindings("""
            esc = 'mode main'
            c = ['close', 'mode main']
            b = 'balance-sizes'
            enter = ['mode main']
            shift-q = 'mode main'
            r = ['mode resize']
            """), oneShot: false)

        assertEquals(hints?.rows.map(row), [
            "B → balance-sizes",
            "C → close",
            "R → mode resize",
            "↩ ⎋ → back to main",
            "⇧ Q → back to main",
        ])
        // Distinct ids: the view lists a row's tokens by id
        assertEquals(hints?.rows.map { Set($0.tokens.map(\.id)).count }, [1, 1, 1, 2, 2])
        assertEquals(hints?.mode, "window")
        assertEquals(hints?.oneShot, false)
    }

    func testAKeyBoundToNothingHasNoRow() {
        let hints = modeHints(mode: "window", bindings: parseBindings("""
            a = []
            c = 'close'
            """), oneShot: true)

        assertEquals(hints?.rows.map(row), ["C → close"])
        assertEquals(hints?.oneShot, true)
        assertNil(modeHints(mode: "window", bindings: parseBindings("a = []"), oneShot: true))
    }

    func testALongOrMultiLineActionBecomesOneShortLine() {
        assertEquals(modeHintsActionText("close"), "close")
        assertEquals(modeHintsActionText("exec-and-forget osascript -e '\n    tell application \"Finder\" to activate'", maxLength: 30), "exec-and-forget osascript -e…")
        let hints = modeHints(mode: "apps", bindings: parseBindings("""
            f = '''exec-and-forget osascript -e '
                tell application "Finder" to activate'
            '''
            """), oneShot: false)
        assertEquals(hints?.rows.map(row), ["F → exec-and-forget osascript -e ' tell applica…"])
    }

    func testAModeWithOnlyLeavingKeysStillHasHints() {
        assertEquals(modeHints(mode: "empty", bindings: parseBindings("esc = 'mode main'"), oneShot: false)?.rows.map(row), ["⎋ → back to main"])
    }

    func testAModeWithoutBindingsHasNoHints() {
        assertNil(modeHints(mode: "window", bindings: [], oneShot: false))
    }

    func testNoHintsInTheMainModeWhilePausedOrSwitchedOff() {
        config.modes["window"] = Mode(bindings: Dictionary(uniqueKeysWithValues: parseBindings("c = 'close'").map { ($0.descriptionWithKeyCode, $0) }), oneShot: true)
        config.modeHints.enabled = true
        assertNil(currentModeHints())

        activeMode = "window"
        assertEquals(currentModeHints()?.rows.map(row), ["C → close"])
        assertEquals(currentModeHints()?.oneShot, true)

        config.modeHints.enabled = false
        assertNil(currentModeHints())
        config.modeHints.enabled = true

        // The mode's keys aren't registered while these are off, so there is nothing to hint at
        config.enableKeyboardShortcuts = false
        assertNil(currentModeHints())
        config.enableKeyboardShortcuts = true

        sessionCoordinator.setEnabled(false)
        assertNil(currentModeHints())
    }

    func testColumnsHoldEightRowsUntilThereAreTooManyColumns() {
        func rows(_ count: Int) -> [Shortcut] { (0 ..< count).map { Shortcut(tokens: [], action: "\($0)", searchText: "") } }

        assertEquals(modeHintsColumns(rows(0)).map(\.count), [])
        assertEquals(modeHintsColumns(rows(5)).map(\.count), [5])
        assertEquals(modeHintsColumns(rows(8)).map(\.count), [8])
        assertEquals(modeHintsColumns(rows(9)).map(\.count), [8, 1])
        assertEquals(modeHintsColumns(rows(32)).map(\.count), [8, 8, 8, 8])
        assertEquals(modeHintsColumns(rows(33)).map(\.count), [9, 9, 9, 6])
        assertEquals(modeHintsColumns(rows(33)).flatMap(\.self).map(\.action), (0 ..< 33).map(String.init))
    }

    func testPanelSitsAtTheBottomCenterAndStaysOnScreen() {
        let visible = NSRect(x: 100, y: 50, width: 1000, height: 600)

        assertEquals(modeHintsPanelFrame(contentSize: CGSize(width: 400, height: 200), visibleFrame: visible), NSRect(x: 400, y: 98, width: 400, height: 200))
        // Too tall for the margin: the top edge stays on screen
        assertEquals(modeHintsPanelFrame(contentSize: CGSize(width: 400, height: 580), visibleFrame: visible), NSRect(x: 400, y: 70, width: 400, height: 580))
        assertEquals(modeHintsPanelFrame(contentSize: CGSize(width: 2000, height: 900), visibleFrame: visible), visible)
    }

    private func row(_ shortcut: Shortcut) -> String {
        shortcut.tokens.map(\.label).joined(separator: " ") + " → " + shortcut.action
    }
}
