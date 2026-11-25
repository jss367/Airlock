@testable import AppBundle
import Common
import XCTest

@MainActor
final class OneShotModeTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
        sessionCoordinator.setEnabled(true)
        activeMode = mainModeId
        config.modes = [
            mainModeId: Mode(bindings: [:]),
            "window": Mode(bindings: [:], oneShot: true),
            "resize": Mode(bindings: [:]),
        ]
    }

    override func tearDown() async throws {
        config.modes = [mainModeId: Mode(bindings: [:])]
        sessionCoordinator.setEnabled(true)
        activeMode = mainModeId
        resetFocusCacheForTests()
    }

    func testABindingOfAOneShotModeReturnsToMain() async throws {
        try await activateMode("window")
        try await runHotkeyCommandSession([parseCommand("balance-sizes").cmdOrDie], mode: "window")
        assertEquals(activeMode, mainModeId)
    }

    func testABindingOfAnOrdinaryModeStaysInIt() async throws {
        try await activateMode("resize")
        try await runHotkeyCommandSession([parseCommand("balance-sizes").cmdOrDie], mode: "resize")
        assertEquals(activeMode, "resize")
    }

    func testABindingThatSwitchesModeItselfKeepsItsTarget() async throws {
        try await activateMode("window")
        try await runHotkeyCommandSession([parseCommand("mode resize").cmdOrDie], mode: "window")
        assertEquals(activeMode, "resize")
    }

    func testTheBindingThatEntersAOneShotModeDoesNotLeaveIt() async throws {
        // The key that runs 'mode window' belongs to main, which is where the mode was entered from
        try await runHotkeyCommandSession([parseCommand("mode window").cmdOrDie], mode: mainModeId)
        assertEquals(activeMode, "window")
    }

    func testAFailedCommandStillEndsTheOneShotMode() async throws {
        try await activateMode("window")
        try await runHotkeyCommandSession([parseCommand("mode no-such-mode").cmdOrDie], mode: "window")
        assertEquals(activeMode, mainModeId)
    }

    func testTriggerBindingEndsTheOneShotModeItsBindingBelongsTo() async throws {
        let binding = HotkeyBinding(.option, .x, [parseCommand("balance-sizes").cmdOrDie], descriptionWithKeyNotation: "option-x")
        config.modes["window"]?.bindings = [binding.descriptionWithKeyCode: binding]
        config.modes["resize"]?.bindings = [binding.descriptionWithKeyCode: binding]
        let trigger = parseCommand("trigger-binding option-x --mode window").cmdOrDie

        // Run from a main-mode key while in main: there is no one-shot mode to end
        try await runHotkeyCommandSession([trigger], mode: mainModeId)
        assertEquals(activeMode, mainModeId)

        activeMode = "resize"
        try await runHotkeyCommandSession([trigger])
        assertEquals(activeMode, "resize")

        activeMode = "window"
        try await runHotkeyCommandSession([trigger])
        assertEquals(activeMode, mainModeId)
    }

    func testPauseInsideAOneShotBindingIsNotUndone() async throws {
        defer { resetFocusCacheForTests() }
        activeMode = "window"
        try await runHotkeyCommandSession([parseCommand("enable off").cmdOrDie], mode: "window")
        XCTAssertFalse(sessionCoordinator.isEnabled)
        XCTAssertNil(activeMode)
    }
}
