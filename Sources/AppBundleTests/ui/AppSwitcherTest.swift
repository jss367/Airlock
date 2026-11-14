@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class AppSwitcherTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testWindowsByFocusRecencyIsGlobalAcrossContainers() {
        let workspace = Workspace.get(byName: name)
        var x1: Window!
        var x2: Window!
        var other: Window!
        workspace.rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                x1 = TestWindow.new(id: 1, parent: $0)
                other = TestWindow.new(id: 3, parent: $0)
            }
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                x2 = TestWindow.new(id: 2, parent: $0)
            }
            TestWindow.new(id: 4, parent: $0) // never focused
        }

        assertTrue(x1.focusWindow())
        assertTrue(x2.focusWindow())
        assertTrue(other.focusWindow())

        // other's container is now the most recent root child, but x2 was focused after x1
        assertEquals(windowsByFocusRecency(workspace).map(\.windowId), [3, 2, 1, 4])
    }

    func testGroupedPreservingOrderKeepsFirstAppearanceOrder() {
        // (pid, windowId), most recently focused window first
        let windows = [(2, 20), (1, 10), (2, 21), (3, 30), (1, 11)]
        let groups = groupedPreservingOrder(windows, by: { $0.0 })

        // The app of the most recent window leads, so Cmd+Tab's second entry is the previous app
        assertEquals(groups.map(\.key), [2, 1, 3])
        assertEquals(groups.map { $0.items.map(\.1) }, [[20, 21], [10, 11], [30]])
    }

    func testThumbnailsLoadFromTheSelectedAppOnward() {
        let state = AppSwitcherState(groups: [group(pid: 1, windows: [10, 11]), group(pid: 2, windows: [20]), group(pid: 3, windows: [30, 31])], selectedAppIndex: 1)
        assertEquals(state.windowIdsFromSelectedApp, [20, 30, 31, 10, 11])

        state.cycleApp(offset: -1)
        assertEquals(state.windowIdsFromSelectedApp, [10, 11, 20, 30, 31])
    }

    func testContentWidthFitsIconsAndTilesWithinTheScreen() {
        // One app with one window: the single thumbnail tile sets the width
        assertEquals(AppSwitcherLayout.contentWidth(appCount: 1, maxWindowCount: 1, availableWidth: 2000), 320)
        // Three windows are wider than three icons
        assertEquals(AppSwitcherLayout.contentWidth(appCount: 3, maxWindowCount: 3, availableWidth: 2000), 688)
        // Beyond four windows the strip scrolls instead of growing
        assertEquals(
            AppSwitcherLayout.contentWidth(appCount: 3, maxWindowCount: 9, availableWidth: 2000),
            AppSwitcherLayout.contentWidth(appCount: 3, maxWindowCount: 4, availableWidth: 2000),
        )
        // Many apps widen the panel, but never past the screen
        assertEquals(AppSwitcherLayout.contentWidth(appCount: 12, maxWindowCount: 1, availableWidth: 2000), 1172)
        assertEquals(AppSwitcherLayout.contentWidth(appCount: 12, maxWindowCount: 1, availableWidth: 900), 900)
    }

    func testHoverWaitsForThePointerToMove() {
        var pointer = CGPoint(x: 100, y: 100)
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 1, pointerLocation: { pointer })

        // The panel opened under a resting pointer: the keyboard's selection stands
        state.hoverApp(at: 2)
        assertEquals(state.selectedAppIndex, 1)

        pointer.x += 10
        state.hoverApp(at: 2)
        assertEquals(state.selectedAppIndex, 2)
        assertEquals(state.selectedWindowIndex, 0)
        assertEquals(state.selectionCameFromKeyboard, false)

        state.hoverWindow(at: 1)
        assertEquals(state.selectedWindowIndex, 1)
    }

    func testKeyboardSelectionHoldsUntilThePointerMovesAgain() {
        var pointer = CGPoint(x: 100, y: 100)
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0, pointerLocation: { pointer })
        pointer.x += 10
        state.hoverApp(at: 2)
        assertEquals(state.selectedAppIndex, 2)

        // The row scrolls under the pointer after a key press, which reports a hover without any movement
        state.cycleApp(offset: 1)
        assertEquals(state.selectedAppIndex, 0)
        assertEquals(state.selectionCameFromKeyboard, true)
        state.hoverApp(at: 2)
        assertEquals(state.selectedAppIndex, 0)

        pointer.y += 10
        state.hoverApp(at: 2)
        assertEquals(state.selectedAppIndex, 2)
    }

    func testClickSelectsWithoutPointerMovement() {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0, pointerLocation: { .zero })
        state.selectApp(at: 2)
        assertEquals(state.selectedAppIndex, 2)
        state.selectWindow(at: 1)
        assertEquals(state.selectedWindowIndex, 1)

        // Out-of-range items are ignored
        state.selectApp(at: 7)
        state.selectWindow(at: 7)
        assertEquals(state.selectedAppIndex, 2)
        assertEquals(state.selectedWindowIndex, 1)
    }

    func testClosingTheSelectedWindowKeepsASelection() async throws {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 2, pointerLocation: { .zero })
        state.cycleWindow(offset: 1)

        // The last window of an app: selection falls back to the window before it
        try await confirmClose(31, in: state)
        assertEquals(state.selectedGroup?.windows.map(\.windowId), [30])
        assertEquals(state.selectedWindowIndex, 0)

        // An app's only window: the app goes too, and selection moves to the last app left
        try await confirmClose(30, in: state)
        assertEquals(state.groups.map(\.pid), [1, 2])
        assertEquals(state.selectedAppIndex, 1)
    }

    func testQuittingEveryAppEmptiesTheList() {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0, pointerLocation: { .zero })
        assertEquals(state.quitApp(pid: 1, requestQuit: { true }), true)
        assertEquals(state.selectedGroup?.pid, 2)
        assertEquals(state.quitApp(pid: 2, requestQuit: { true }), true)
        assertEquals(state.quitApp(pid: 3, requestQuit: { true }), true)
        assertTrue(state.groups.isEmpty)
        assertNil(state.selectedGroup)
        assertNil(state.reserveAppForQuit())
        assertNil(state.reserveWindowForClose())
    }

    func testFailedQuitKeepsTheLastAppAndSelection() {
        let state = AppSwitcherState(groups: [group(pid: 1, windows: [10, 11])], selectedAppIndex: 0)
        state.cycleWindow(offset: 1)
        assertEquals(state.quitApp(pid: 1, requestQuit: { false }), false)
        assertEquals(state.groups.map(\.pid), [1])
        assertEquals(state.selectedWindowIndex, 1)
        assertEquals(state.quitApp(pid: 1, requestQuit: { true }), true)
        assertTrue(state.groups.isEmpty)
    }

    func testQuitRemovesTheRequestedAppAfterSelectionChanges() {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0)
        let target = state.selectedGroup!.pid
        state.cycleApp(offset: 2)
        state.cycleWindow(offset: 1)
        assertEquals(state.quitApp(pid: target, requestQuit: { true }), true)
        assertEquals(state.groups.map(\.pid), [2, 3])
        assertEquals(state.selectedGroup?.pid, 3)
        assertEquals(state.selectedWindowIndex, 1)
        var requestedMissingApp = false
        assertEquals(state.quitApp(pid: target, requestQuit: { requestedMissingApp = true; return true }), false)
        assertEquals(requestedMissingApp, false)
    }

    func testQuittingALaterAppPreservesTheSelectedWindow() {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0)
        state.cycleWindow(offset: 1)
        assertEquals(state.quitApp(pid: 3, requestQuit: { true }), true)
        assertEquals(state.selectedGroup?.pid, 1)
        assertEquals(state.selectedWindowIndex, 1)

        // Removing the selected app still selects the next app's first window.
        assertEquals(state.quitApp(pid: 1, requestQuit: { true }), true)
        assertEquals(state.selectedGroup?.pid, 2)
        assertEquals(state.selectedWindowIndex, 0)
    }

    func testFailedCloseKeepsTheLastWindow() async throws {
        let state = AppSwitcherState(groups: [group(pid: 1, windows: [10])], selectedAppIndex: 0)
        do {
            _ = try await state.closeWindowAfterConfirmation(windowId: 10) { throw NSError(domain: "test", code: 1) }
            XCTFail("A failed close must rethrow")
        } catch {}
        assertEquals(state.selectedGroup?.windows.map(\.windowId), [10])
        try await confirmClose(10, in: state)
        assertTrue(state.groups.isEmpty)
    }

    func testClosingCapturedWindowPreservesNewSelection() async throws {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0)
        state.cycleWindow(offset: 1)
        try await confirmClose(10, in: state)
        assertEquals(state.selectedGroup?.windows[safe: state.selectedWindowIndex]?.windowId, 11)

        state.cycleApp(offset: 2)
        state.cycleWindow(offset: 1)
        try await confirmClose(11, in: state)
        assertEquals(state.selectedGroup?.pid, 3)
        assertEquals(state.selectedGroup?.windows[safe: state.selectedWindowIndex]?.windowId, 31)
    }

    func testRapidCloseReservationsAdvanceWithoutHidingWindows() async throws {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0)
        assertEquals(state.reserveWindowForClose(), 10)
        assertEquals(state.reserveWindowForClose(), 11)
        assertEquals(state.reserveWindowForClose(), 20)
        assertEquals(state.groups.flatMap { $0.windows.map(\.windowId) }, [10, 11, 20, 30, 31])
        assertEquals(state.reserveWindowForClose(), 30)
        assertEquals(state.reserveWindowForClose(), 31)
        assertNil(state.reserveWindowForClose())

        // A failed admission releases its target without removing it or another reservation.
        state.finishClosingWindow(10)
        assertEquals(state.reserveWindowForClose(), 10)
        try await confirmClose(11, in: state)
        state.finishClosingWindow(11)
        assertNil(state.reserveWindowForClose())
    }

    func testCloseReservationsRespectNewSelectionsAndLastWindowFallback() {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 2)
        state.cycleWindow(offset: 1)
        assertEquals(state.reserveWindowForClose(), 31)
        assertEquals(state.reserveWindowForClose(), 30)
        assertEquals(state.reserveWindowForClose(), 20)
        state.selectApp(at: 0)
        state.selectWindow(at: 1)
        assertEquals(state.reserveWindowForClose(), 11)
        assertEquals(state.reserveWindowForClose(), 10)
        assertNil(state.reserveWindowForClose())
    }

    func testCloseWaitsForConfirmationAndRetainsRejectedTarget() async throws {
        let state = AppSwitcherState(groups: [group(pid: 1, windows: [10])], selectedAppIndex: 0)
        let rejected = try await state.closeWindowAfterConfirmation(windowId: 10) {
            await Task.yield()
            assertEquals(state.selectedGroup?.windows.map(\.windowId), [10])
            return false
        }
        assertEquals(rejected, false)
        assertEquals(state.selectedGroup?.windows.map(\.windowId), [10])
        let accepted = try await state.closeWindowAfterConfirmation(windowId: 10) {
            await Task.yield()
            assertEquals(state.selectedGroup?.windows.map(\.windowId), [10])
            return true
        }
        assertEquals(accepted, true)
        assertTrue(state.groups.isEmpty)
    }

    func testRapidQuitReservationsAdvanceAndReleaseOnFailure() {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0)
        assertEquals(state.reserveAppForQuit(), 1)
        assertEquals(state.reserveAppForQuit(), 2)
        assertEquals(state.reserveAppForQuit(), 3)
        assertNil(state.reserveAppForQuit())
        assertEquals(state.groups.map(\.pid), [1, 2, 3])
        assertEquals(state.quitApp(pid: 1, requestQuit: { false }), false)
        state.finishQuittingApp(1)
        assertEquals(state.reserveAppForQuit(), 1)
        assertEquals(state.quitApp(pid: 2, requestQuit: { true }), true)
        state.finishQuittingApp(2)
        assertNil(state.reserveAppForQuit())
    }

    func testQuitReservationsRespectNewSelectionAndCloseSkipsQuittingApps() {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 2)
        assertEquals(state.reserveAppForQuit(), 3)
        assertEquals(state.reserveWindowForClose(), 20)
        state.selectApp(at: 0)
        assertEquals(state.reserveAppForQuit(), 1)
        assertNil(state.reserveAppForQuit()) // App 2's only window is already reserved for close.
        assertNil(state.reserveWindowForClose())
        state.finishQuittingApp(1)
        assertEquals(state.reserveWindowForClose(), 10)
    }

    func testQuitSkipsFullyCloseReservedAppsAndRecoversAfterFailure() async throws {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0)
        assertEquals(state.reserveWindowForClose(), 10)
        assertEquals(state.reserveWindowForClose(), 11)
        assertEquals(state.reserveAppForQuit(), 2)
        assertEquals(state.reserveAppForQuit(), 3)
        assertNil(state.reserveAppForQuit())

        // A failed close restores eligibility without disturbing other pending quits.
        state.finishClosingWindow(10)
        assertEquals(state.reserveAppForQuit(), 1)
        state.finishQuittingApp(1)
        try await confirmClose(11, in: state)
        state.finishClosingWindow(11)
        assertEquals(state.reserveAppForQuit(), 1)
        assertEquals(state.selectedGroup?.windows.map(\.windowId), [10])
    }

    func testQuitFallsBackPastASelectedAppWithItsLastWindowReserved() {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 2)
        assertEquals(state.reserveWindowForClose(), 30)
        assertEquals(state.reserveWindowForClose(), 31)
        assertEquals(state.reserveAppForQuit(), 2)
        assertEquals(state.reserveAppForQuit(), 1)
        assertNil(state.reserveAppForQuit())
    }

    func testQueuedQuitWaitsForPartialCloseSuccessOrFailure() async {
        for closeSucceeds in [true, false] {
            let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0)
            let queue = AppSwitcherActionQueue()
            let windowId = state.reserveWindowForClose()!
            let pid = state.reserveAppForQuit()!
            assertEquals(windowId, 10)
            assertEquals(pid, 1)
            var resumeClose: CheckedContinuation<Void, Never>?
            var order: [String] = []
            queue.enqueue {
                defer { state.finishClosingWindow(windowId) }
                order.append("close started")
                _ = try? await state.closeWindowAfterConfirmation(windowId: windowId) {
                    await withCheckedContinuation { resumeClose = $0 }
                    if !closeSucceeds { throw NSError(domain: "test", code: 1) }
                    return true
                }
                order.append("close finished")
            }
            while resumeClose == nil { await Task.yield() }
            let finished = queue.enqueue {
                defer { state.finishQuittingApp(pid) }
                order.append("quit")
                assertEquals(state.groups.first?.windows.count, closeSucceeds ? 1 : 2)
                assertEquals(state.quitApp(pid: pid, requestQuit: { true }), true)
            }
            state.selectApp(at: 2)
            state.selectWindow(at: 1)
            await Task.yield()
            assertEquals(order, ["close started"])
            resumeClose?.resume()
            await finished.value
            assertEquals(order, ["close started", "close finished", "quit"])
            assertEquals(state.selectedGroup?.pid, 3)
            assertEquals(state.selectedGroup?.windows[safe: state.selectedWindowIndex]?.windowId, 31)
        }
    }

    func testReopenedPanelSharesPendingTargetsAndOrdering() async {
        for closeSucceeds in [true, false] {
            let queue = AppSwitcherActionQueue()
            let oldState = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0, actionQueue: queue)
            let first = oldState.reserveWindowForClose()!
            var resumeClose: CheckedContinuation<Void, Never>?
            var order: [UInt32] = []
            queue.enqueue {
                defer { oldState.finishClosingWindow(first) }
                _ = try? await oldState.closeWindowAfterConfirmation(windowId: first) {
                    await withCheckedContinuation { resumeClose = $0 }
                    order.append(first)
                    return closeSucceeds
                }
            }
            while resumeClose == nil { await Task.yield() }
            // The panel is replaced while its previously accepted action is suspended.
            let reopened = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0, actionQueue: queue)
            let second = reopened.reserveWindowForClose()!
            assertEquals(second, 11)
            let finished = queue.enqueue {
                defer { reopened.finishClosingWindow(second) }
                order.append(second)
                _ = try? await reopened.closeWindowAfterConfirmation(windowId: second) { true }
            }
            await Task.yield()
            assertTrue(order.isEmpty)
            resumeClose?.resume()
            await finished.value
            assertEquals(order, [10, 11])
            assertEquals(reopened.groups.first?.windows.map(\.windowId), closeSucceeds ? [20] : [10])
            assertEquals(oldState.groups.map(\.pid), reopened.groups.map(\.pid))
            assertEquals(reopened.reserveWindowForClose(), closeSucceeds ? 20 : 10)
        }
    }

    func testRefreshedTitlesApplyToTheCurrentList() async {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let state = AppSwitcherState(
            groups: [group(pid: 1, windows: [1]), group(pid: 2, windows: [2])],
            selectedAppIndex: 0,
            pointerLocation: { .zero },
        )

        var reported: [UInt32: String] = [:]
        await state.refreshWindowTitles { windowId, title in
            reported[windowId] = title
            // Window 2's app is quit from the switcher while titles are still loading
            if windowId == 1 { assertEquals(state.quitApp(pid: 2, requestQuit: { true }), true) }
        }

        assertEquals(reported, [1: "TestWindow(1)", 2: "TestWindow(2)"])
        assertEquals(state.groups.map { $0.windows.map(\.title) }, [["TestWindow(1)"]])
    }

    func testKeyActions() {
        func action(_ keyCode: UInt16, shift: Bool = false, isRepeat: Bool = false) -> AppSwitcherKeyAction? {
            appSwitcherKeyAction(keyCode: keyCode, hasShift: shift, isRepeat: isRepeat)
        }
        assertEquals(action(48), .cycleApp(offset: 1)) // Tab
        assertEquals(action(48, shift: true), .cycleApp(offset: -1))
        assertEquals(action(124), .cycleApp(offset: 1)) // Right
        assertEquals(action(123), .cycleApp(offset: -1)) // Left
        assertEquals(action(125), .cycleWindow(offset: 1)) // Down
        assertEquals(action(126), .cycleWindow(offset: -1)) // Up
        assertEquals(action(38), .cycleWindow(offset: 1)) // j
        assertEquals(action(40), .cycleWindow(offset: -1)) // k
        assertEquals(action(13), .closeWindow) // w
        assertEquals(action(12), .quitApp) // q
        assertEquals(action(53), .cancel) // Escape
        assertNil(action(0)) // a

        // A held key repeats arrows but never closes or quits again
        assertEquals(action(124, isRepeat: true), .cycleApp(offset: 1))
        assertEquals(action(13, isRepeat: true), .ignore)
        assertEquals(action(12, isRepeat: true), .ignore)
    }

    /// Close a window the way the panel does once the close is confirmed
    private func confirmClose(_ windowId: UInt32, in state: AppSwitcherState) async throws {
        let closed = try await state.closeWindowAfterConfirmation(windowId: windowId) { true }
        assertTrue(closed)
    }

    private func threeApps() -> [AppGroup] {
        [group(pid: 1, windows: [10, 11]), group(pid: 2, windows: [20]), group(pid: 3, windows: [30, 31])]
    }

    private func group(pid: Int32, windows: [UInt32]) -> AppGroup {
        AppGroup(
            id: pid,
            pid: pid,
            name: "App \(pid)",
            icon: NSImage(),
            windows: windows.map { AppGroupWindow(id: $0, windowId: $0, title: "Window \($0)") },
        )
    }
}
