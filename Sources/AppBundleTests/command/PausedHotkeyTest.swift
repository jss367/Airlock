@testable import AppBundle
import Common
import XCTest

@MainActor final class PausedHotkeyTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
        uiResumeFocus.reset()
    }
    override func tearDown() async throws {
        resetFocusCacheForTests()
        resetFocusStealingPreventionForTests()
        uiResumeFocus.reset()
        sessionCoordinator.setEnabled(true)
        activeMode = mainModeId
    }

    func testPausedKeepsOnlyEnableOnlyMainBindings() {
        let toggle = HotkeyBinding(.option, .e, [parseCommand("enable toggle").cmdOrDie])
        let mixed = HotkeyBinding(.option, .m, [parseCommand("enable on").cmdOrDie, parseCommand("workspace 1").cmdOrDie])
        let other = HotkeyBinding(.option, .w, [parseCommand("mission-control").cmdOrDie])
        config.modes = [mainModeId: Mode(bindings: Dictionary(uniqueKeysWithValues: [toggle, mixed, other].map { ($0.descriptionWithKeyCode, $0) }))]
        XCTAssertEqual(pausedBindings(), [:])
        sessionCoordinator.setEnabled(false)
        XCTAssertEqual(pausedBindings(), [toggle.descriptionWithKeyCode: toggle])
    }

    func testEnableToggleHotkeyResumesWhilePaused() async throws {
        defer { resetFocusCacheForTests() }
        try await runHotkeyCommandSession([parseCommand("enable toggle").cmdOrDie])
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        XCTAssertNil(activeMode)
        try await runHotkeyCommandSession([parseCommand("enable toggle").cmdOrDie])
        XCTAssertTrue(TrayMenuModel.shared.isEnabled)
        XCTAssertEqual(activeMode, mainModeId)
    }

    func testOtherHotkeysStayInertWhilePaused() async throws {
        defer { resetFocusCacheForTests() }
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await runHotkeyCommandSession([parseCommand("workspace 2").cmdOrDie])
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        XCTAssertNotEqual(focus.workspace.name, "2")
    }
}
