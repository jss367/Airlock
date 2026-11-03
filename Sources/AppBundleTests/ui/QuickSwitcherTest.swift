@testable import AppBundle
import Foundation
import XCTest

final class QuickSwitcherTest: XCTestCase {
    @MainActor
    func testRepeatedPanelDismissalDoesNotRestoreStaleFocus() {
        setUpWorkspacesForTests()
        dismissQuickSwitcher(restoreFocus: false)
        dismissMissionControl(restoreFocus: false)
        let old = TestWindow.new(id: 501, parent: Workspace.get(byName: "old").rootTilingContainer)
        let external = TestWindow.new(id: 502, parent: Workspace.get(byName: "external").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        external.nativeFocus()
        // Pause has already closed the panels. An older selection finishing later must be harmless.
        dismissQuickSwitcher()
        dismissMissionControl()
        XCTAssertTrue(TestApp.shared.focusedWindow === external)
    }

    func testWebSearchUrlKeepsQuerySyntaxCharacters() {
        for query in ["c++", "AT&T", "a=b", "50% off", "what is #1?"] {
            let url = webSearchUrl(query: query)
            let q = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .percentEncodedQueryItems?.first { $0.name == "q" }?.value?.removingPercentEncoding
            assertEquals(q, query)
        }
        assertEquals(webSearchUrl(query: "c++")?.absoluteString, "https://google.com/search?q=c%2B%2B")
    }

    @MainActor
    func testPausingReleasesHotkey() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = true
        registerQuickSwitcherHotkey()
        defer {
            sessionCoordinator.setEnabled(true)
            config.quickSwitcher.enabled = false
            registerQuickSwitcherHotkey()
        }
        assertEquals(isQuickSwitcherHotkeyRegistered, true)

        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(isQuickSwitcherHotkeyRegistered, false)

        // Reloading config while paused must not re-register it
        registerQuickSwitcherHotkey()
        assertEquals(isQuickSwitcherHotkeyRegistered, false)

        _ = try await parseCommand("enable on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(isQuickSwitcherHotkeyRegistered, true)
    }

    @MainActor
    func testPanelsDontOpenWhilePaused() async throws {
        setUpWorkspacesForTests()
        defer { sessionCoordinator.setEnabled(true) }
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)

        toggleQuickSwitcher()
        assertEquals(isQuickSwitcherOpen, false)
        toggleMissionControl()
        assertEquals(isMissionControlOpen, false)
    }

    @MainActor
    func testPausingClosesMissionControl() async throws {
        setUpWorkspacesForTests()
        defer {
            sessionCoordinator.setEnabled(true)
            dismissMissionControl(restoreFocus: false)
        }
        toggleMissionControl()
        assertEquals(isMissionControlOpen, true) // Still capturing thumbnails

        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(isMissionControlOpen, false)
    }
}
