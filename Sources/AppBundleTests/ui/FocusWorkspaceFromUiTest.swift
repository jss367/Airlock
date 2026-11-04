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
}
