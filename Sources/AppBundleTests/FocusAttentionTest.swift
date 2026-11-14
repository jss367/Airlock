@testable import AppBundle
import Common
import XCTest

/// A blocked focus change is deferred, not dropped. Each test starts with window 1 focused on
/// workspace "focused", window 2 on the same workspace, windows 3 and 4 on workspace "other", and
/// window 5 on workspace "third".
@MainActor
final class FocusAttentionTest: XCTestCase {
    private var current: Window!
    private var sameWorkspace: Window!
    private var other: Window!
    private var otherSibling: Window!
    private var third: Window!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        let focused = Workspace.get(byName: "focused").rootTilingContainer
        current = TestWindow.new(id: 1, parent: focused)
        sameWorkspace = TestWindow.new(id: 2, parent: focused)
        other = TestWindow.new(id: 3, parent: Workspace.get(byName: "other").rootTilingContainer)
        otherSibling = TestWindow.new(id: 4, parent: Workspace.get(byName: "other").rootTilingContainer)
        third = TestWindow.new(id: 5, parent: Workspace.get(byName: "third").rootTilingContainer)
        check(current.focusWindow())
        _ = updateFocusCache(current)
    }

    private var pendingWindowIds: [UInt32] { focusAttention.pending.map(\.windowId) }

    private func userFocuses(_ window: Window) {
        markUserInitiatedFocusChange()
        assertTrue(updateFocusCache(window))
    }

    func testBlockedWindowIsRecordedWithItsWorkspace() {
        assertEquals(updateFocusCache(other), false)
        assertEquals(focusAttention.pending.map(\.workspaceName), ["other"])
        assertEquals(pendingWindowIds, [3])
    }

    func testAllowedChangeRecordsNothing() {
        assertTrue(updateFocusCache(sameWorkspace))
        assertEquals(pendingWindowIds, [])
    }

    func testMostRecentRequestComesFirst() {
        assertEquals(updateFocusCache(other), false)
        assertEquals(updateFocusCache(third), false)
        assertEquals(pendingWindowIds, [5, 3])
        // Asking again moves a window back to the front instead of listing it twice
        assertEquals(updateFocusCache(other), false)
        assertEquals(pendingWindowIds, [3, 5])
    }

    func testFocusingTheWindowClearsItsRequest() {
        assertEquals(updateFocusCache(other), false)
        userFocuses(other)
        assertEquals(pendingWindowIds, [])
    }

    /// Going to the workspace answers every request on it, whichever window the user picks there.
    func testFocusingTheWorkspaceClearsItsRequests() {
        assertEquals(updateFocusCache(other), false)
        assertEquals(updateFocusCache(otherSibling), false)
        assertEquals(updateFocusCache(third), false)
        check(Workspace.get(byName: "other").focusWorkspace())
        assertEquals(pendingWindowIds, [5])
    }

    func testFocusChangeOnAnotherWorkspaceKeepsTheRequest() {
        assertEquals(updateFocusCache(other), false)
        userFocuses(sameWorkspace)
        assertEquals(pendingWindowIds, [3])
    }

    func testVisitingWorkspaceAndLeavingBeforeReadingClearsItsRequests() {
        assertEquals(updateFocusCache(other), false)
        // A command sequence can visit and leave before the tray reads attention state.
        check(other.focusWindow())
        check(current.focusWindow())
        assertEquals(pendingWindowIds, [])
    }

    func testAlwaysModeFocusChangeCannotBeUndoneByReturningBeforeReading() {
        config.preventFocusStealing = .always
        assertEquals(updateFocusCache(sameWorkspace), false)
        check(sameWorkspace.focusWindow())
        check(current.focusWindow())
        assertEquals(pendingWindowIds, [])
    }

    func testInterruptedSessionDoesNotRetainAnAnsweredRequest() async throws {
        assertEquals(updateFocusCache(other), false)
        do {
            try await runLightSession(.menuBarButton, .enabled, syncFocusBeforeBody: false) {
                check(self.other.focusWindow())
                throw CancellationError()
            }
            XCTFail("The interrupted session must throw")
        } catch is CancellationError {}
        check(current.focusWindow())
        assertEquals(pendingWindowIds, [])
    }

    func testClosingTheWindowClearsItsRequest() {
        assertEquals(updateFocusCache(other), false)
        other.closeAxWindow()
        assertEquals(pendingWindowIds, [])
    }

    func testMovingTheWindowClearsItsRequest() {
        assertEquals(updateFocusCache(other), false)
        other.bind(to: Workspace.get(byName: "third").rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        assertEquals(pendingWindowIds, [])
    }

    func testRenamingPendingWorkspacePreservesOrderMarkerAndFocusCommand() async throws {
        assertEquals(updateFocusCache(other), false)
        assertEquals(updateFocusCache(third), false)
        let before = focusAttention.pending
        // Exercise the real in-memory rename while keeping the user's config untouched.
        let renamed = try await Workspace.rename(other.nodeWorkspace!, to: "renamed", updateConfig: { _, _ in true })
        assertTrue(renamed)
        assertEquals(pendingWindowIds, [5, 3])
        assertEquals(focusAttention.pending.map(\.order), before.map(\.order))
        assertEquals(focusAttention.pending.last?.workspaceName, "renamed")
        updateTrayText()
        assertEquals(TrayMenuModel.shared.workspaces.first { $0.name == "renamed" }?.wantsAttention, true)
        for expected in [third!, other!] {
            let result = try await parseCommand("focus-attention").cmdOrDie.run(.defaultEnv, .emptyStdin)
            assertEquals(result.exitCode, 0)
            assertTrue(focus.windowOrNil === expected)
        }
        assertEquals(focus.workspace.name, "renamed")
        assertEquals(pendingWindowIds, [])
    }

    func testRenamingFocusedWorkspaceDoesNotAnswerAlwaysModeRequest() async throws {
        config.preventFocusStealing = .always
        assertEquals(updateFocusCache(sameWorkspace), false)
        let renamed = try await Workspace.rename(current.nodeWorkspace!, to: "renamed-focused", updateConfig: { _, _ in true })
        assertTrue(renamed)
        assertEquals(pendingWindowIds, [2])
        assertEquals(focusAttention.pending.first?.workspaceName, "renamed-focused")
        userFocuses(sameWorkspace)
        assertEquals(pendingWindowIds, [])
    }

    func testFailedRenameKeepsTheOriginalRequest() async throws {
        assertEquals(updateFocusCache(other), false)
        let renamed = try await Workspace.rename(other.nodeWorkspace!, to: "renamed", updateConfig: { _, _ in false })
        assertEquals(renamed, false)
        assertEquals(pendingWindowIds, [3])
        assertEquals(focusAttention.pending.first?.workspaceName, "other")
    }

    func testPauseClearsRequests() {
        assertEquals(updateFocusCache(other), false)
        defer { sessionCoordinator.setEnabled(true) }
        sessionCoordinator.setEnabled(false)
        // Nothing reads the requests while paused, so they must be gone by the time Airlock resumes
        sessionCoordinator.setEnabled(true)
        assertEquals(pendingWindowIds, [])
    }

    func testTurningTheProtectionOffClearsRequests() {
        assertEquals(updateFocusCache(other), false)
        config.preventFocusStealing = .off
        assertEquals(pendingWindowIds, [])
    }

    /// `always` blocks windows of the focused workspace too. The user is already there, so the
    /// request stays until focus moves on that workspace.
    func testAlwaysModeRequestOnTheFocusedWorkspace() {
        config.preventFocusStealing = .always
        assertEquals(updateFocusCache(sameWorkspace), false)
        assertEquals(pendingWindowIds, [2])
        userFocuses(sameWorkspace)
        assertEquals(pendingWindowIds, [])
    }

    func testAlwaysModeRequestEndsWhenTheUserPicksAnotherWindowThere() {
        config.preventFocusStealing = .always
        let another = TestWindow.new(id: 6, parent: Workspace.get(byName: "focused").rootTilingContainer)
        assertEquals(updateFocusCache(sameWorkspace), false)
        userFocuses(another)
        assertEquals(pendingWindowIds, [])
    }

    /// Leaving the workspace turns it into an ordinary request, which coming back answers.
    func testAlwaysModeRequestSurvivesLeavingAndEndsOnReturn() {
        config.preventFocusStealing = .always
        assertEquals(updateFocusCache(sameWorkspace), false)
        check(Workspace.get(byName: "third").focusWorkspace())
        assertEquals(pendingWindowIds, [2])
        check(Workspace.get(byName: "focused").focusWorkspace())
        assertEquals(pendingWindowIds, [])
    }

    // MARK: - Menu bar

    func testHiddenWorkspaceThatWantsAttentionIsShownInTheTrayText() {
        assertEquals(updateFocusCache(other), false)
        updateTrayText()
        assertEquals(TrayMenuModel.shared.trayText, "focused  \(attentionMarker)other")
        let model = TrayMenuModel.shared.workspaces.first { $0.name == "other" }
        assertEquals(model?.wantsAttention, true)
        // The menu draws name + suffix, so the suffix has to say it
        assertEquals(model?.suffix, " - dev.airlock.test-app \(attentionMarker) dev.airlock.test-app wants focus")
        assertEquals(TrayMenuModel.shared.workspaces.filter(\.wantsAttention).map(\.name), ["other"])
        assertEquals(TrayMenuModel.shared.trayItems.map(\.wantsAttention), [false])
    }

    func testVisibleWorkspaceThatWantsAttentionIsMarkedInPlace() {
        config.preventFocusStealing = .always
        assertEquals(updateFocusCache(sameWorkspace), false)
        updateTrayText()
        assertEquals(TrayMenuModel.shared.trayText, "\(attentionMarker)focused")
        assertEquals(TrayMenuModel.shared.trayItems.map(\.wantsAttention), [true])
    }

    func testTrayTextIsUnmarkedOnceTheUserGoesThere() {
        assertEquals(updateFocusCache(other), false)
        check(Workspace.get(byName: "other").focusWorkspace())
        updateTrayText()
        assertEquals(TrayMenuModel.shared.trayText, "other")
        assertEquals(TrayMenuModel.shared.workspaces.filter(\.wantsAttention).map(\.name), [])
    }
}
