@testable import AppBundle
import AppKit
import Common
import SwiftUI
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

    func testColumnsFillTopToBottom() {
        assertEquals(modeHintsColumns(rows(0), rowsPerColumn: 8).map(\.count), [])
        assertEquals(modeHintsColumns(rows(5), rowsPerColumn: 8).map(\.count), [5])
        assertEquals(modeHintsColumns(rows(9), rowsPerColumn: 8).map(\.count), [8, 1])
        assertEquals(modeHintsColumns(rows(33), rowsPerColumn: 9).map(\.count), [9, 9, 9, 6])
        assertEquals(modeHintsColumns(rows(33), rowsPerColumn: 9).flatMap(\.self).map(\.action), (0 ..< 33).map(String.init))
    }

    func testColumnHeightOptionsGoFromFourColumnsToOne() {
        assertEquals(modeHintsRowsPerColumnOptions(rowCount: 0), [8])
        assertEquals(modeHintsRowsPerColumnOptions(rowCount: 8), [8])
        assertEquals(modeHintsRowsPerColumnOptions(rowCount: 9), [8, 9])
        assertEquals(modeHintsRowsPerColumnOptions(rowCount: 32), [8, 11, 16, 32])
        assertEquals(modeHintsRowsPerColumnOptions(rowCount: 33), [9, 11, 17, 33])
    }

    func testLayoutTakesTheWidestThatFitsAndShrinksOnlyWhenNothingDoes() {
        // 100pt per column, 10pt per row
        func measure(_ count: Int) -> (Int) -> CGSize {
            { rowsPerColumn in CGSize(width: Double(modeHintsColumns(self.rows(count), rowsPerColumn: rowsPerColumn).count) * 100, height: Double(min(count, rowsPerColumn)) * 10) }
        }
        func layout(_ count: Int, _ width: Double, _ height: Double) -> ModeHintsLayout {
            modeHintsLayout(rowCount: count, available: CGSize(width: width, height: height), measure: measure(count))
        }

        assertEquals(layout(32, 1000, 1000), ModeHintsLayout(rowsPerColumn: 8, scale: 1))
        // Four columns are too wide for the screen, three fit
        assertEquals(layout(32, 350, 1000), ModeHintsLayout(rowsPerColumn: 11, scale: 1))
        assertEquals(layout(32, 150, 1000), ModeHintsLayout(rowsPerColumn: 32, scale: 1))
        // Nothing fits. Two columns of 16 need the least shrinking: to 100/160 of their height.
        // Three columns would shrink to 150/300 of their width, one column to 100/320 of its height
        assertEquals(layout(32, 150, 100), ModeHintsLayout(rowsPerColumn: 16, scale: 0.625))
        assertEquals(layout(3, 50, 1000), ModeHintsLayout(rowsPerColumn: 8, scale: 0.5))
        assertEquals(modeHintsLayout(rowCount: 3, available: CGSize(width: 50, height: 50)) { _ in .zero }, ModeHintsLayout(rowsPerColumn: 3, scale: 1))
    }

    func testAModeWithManyLongBindingsStillFitsALaptopScreen() {
        let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init) + ["1", "2", "3", "4", "5", "6"]
        let toml = letters.map { "ctrl-option-shift-\($0) = 'exec-and-forget open -a \"An Application With A Long Name \($0)\"'" }.joined(separator: "\n")
        let hints = modeHints(mode: "apps", bindings: parseBindings(toml), oneShot: false)!
        assertEquals(hints.rows.count, 32)
        let available = CGSize(width: 1280, height: 720)
        var sizes: [Int: CGSize] = [:]

        let layout = modeHintsLayout(rowCount: hints.rows.count, available: available) { rowsPerColumn in
            let size = NSHostingView(rootView: ModeHintsView(hints: hints, rowsPerColumn: rowsPerColumn)).fittingSize
            sizes[rowsPerColumn] = size
            return size
        }

        // Four columns of these rows are wider than the screen, which is what clipped the outer ones
        assertTrue(sizes[8]!.width > available.width)
        let size = sizes[layout.rowsPerColumn]!
        assertTrue(size.width * layout.scale <= available.width + 0.5)
        assertTrue(size.height * layout.scale <= available.height + 0.5)
        assertTrue(layout.scale > 0.5)
    }

    private func rows(_ count: Int) -> [Shortcut] { (0 ..< count).map { Shortcut(tokens: [], action: "\($0)", searchText: "") } }

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
