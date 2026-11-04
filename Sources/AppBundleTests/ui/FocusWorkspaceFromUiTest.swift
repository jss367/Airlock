@testable import AppBundle
import Common
import XCTest

/// The menu bar, Mission Control, and Quick Switcher follow the same rule as the `workspace` command:
/// without window management, showing a hidden workspace would pull every window on the monitor into it.
@MainActor
final class FocusWorkspaceFromUiTest: XCTestCase {
    private var previousMessage: Message?

    override func setUp() async throws {
        setUpWorkspacesForTests()
        previousMessage = MessageModel.shared.message
        MessageModel.shared.message = nil
    }

    override func tearDown() async throws {
        resetFocusCacheForTests()
        resetFocusStealingPreventionForTests()
        MessageModel.shared.message = previousMessage
    }

    func testRefusesHiddenWorkspaceWithoutWindowManagement() {
        config.enableWindowManagement = false
        let shown = focus.workspace

        focusWorkspaceFromUi(Workspace.get(byName: "hidden"))

        assertTrue(focus.workspace === shown)
        assertEquals(Workspace.get(byName: "hidden").isVisible, false)
        assertTrue(MessageModel.shared.message?.body.contains("requires window management") == true)
    }

    func testFocusesShownWorkspaceWithoutWindowManagement() {
        config.enableWindowManagement = false

        focusWorkspaceFromUi(focus.workspace)

        assertNil(MessageModel.shared.message)
    }

    func testFocusesHiddenWorkspaceWithWindowManagement() {
        focusWorkspaceFromUi(Workspace.get(byName: "hidden"))

        assertEquals(focus.workspace.name, "hidden")
        assertNil(MessageModel.shared.message)
    }
    func testWindowSelectionRefusesHiddenWorkspaceWithoutWindowManagement() {
        config.enableWindowManagement = false
        let shown = focus.workspace
        let hidden = Workspace.get(byName: "hidden")
        let window = TestWindow.new(id: 901, parent: hidden.rootTilingContainer)

        focusWindowFromUi(window)

        assertTrue(focus.workspace === shown)
        assertEquals(hidden.isVisible, false)
        assertTrue(MessageModel.shared.message?.body.contains("requires window management") == true)
    }

    func testWindowSelectionFocusesShownWorkspaceWithoutWindowManagement() {
        config.enableWindowManagement = false
        let window = TestWindow.new(id: 902, parent: focus.workspace.rootTilingContainer)
        focusWindowFromUi(window)
        assertTrue(focus.windowOrNil === window)
        assertNil(MessageModel.shared.message)
    }

    func testWindowSelectionFocusesHiddenWorkspaceWithWindowManagement() {
        let window = TestWindow.new(id: 903, parent: Workspace.get(byName: "hidden").rootTilingContainer)
        focusWindowFromUi(window)
        assertTrue(focus.windowOrNil === window)
        assertTrue(focus.workspace.isVisible)
        assertNil(MessageModel.shared.message)
    }

    func testWindowSelectionSessionCannotShowHiddenWorkspaceWithoutWindowManagement() async throws {
        // runLightSession queues a native refresh; cancel it before this synthetic test yields again.
        defer { resetFocusCacheForTests() }
        config.enableWindowManagement = false
        config.focusFlash.enabled = false
        config.quickSwitcher.enabled = false
        let shown = focus.workspace
        let old = TestWindow.new(id: 904, parent: shown.rootTilingContainer)
        assertTrue(old.focusWindow())
        old.nativeFocus()
        let hidden = Workspace.get(byName: "hidden")
        let window = TestWindow.new(id: 905, parent: hidden.rootTilingContainer)
        let token = try XCTUnwrap(RunSessionGuard.isServerEnabled)

        try await runLightSession(.menuBarButton, token) {
            focusWindowFromUi(window)
            assertTrue(focus.windowOrNil === old)
            assertEquals(hidden.isVisible, false)
        }

        assertTrue(focus.workspace === shown)
        assertTrue(focus.windowOrNil === old)
        assertTrue(MessageModel.shared.message?.body.contains("requires window management") == true)
    }
}
