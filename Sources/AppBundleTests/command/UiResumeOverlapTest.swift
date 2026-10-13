@testable import AppBundle
import Common
import XCTest

@MainActor final class UiResumeOverlapTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
        uiResumeFocus.reset()
    }
    override func tearDown() async throws {
        TrayMenuModel.shared.isEnabled = true
        resetFocusCacheForTests()
        uiResumeFocus.reset()
    }
    func testOverlappingToggleResumesRemainEnabled() async throws {
        try await exerciseOverlappingResume(externalEnable: false)
    }
    func testExternalEnableDuringToggleResumeRemainsEnabled() async throws {
        try await exerciseOverlappingResume(externalEnable: true)
    }
    private func exerciseOverlappingResume(externalEnable: Bool) async throws {
        let window = TestWindow.new(id: 211, parent: Workspace.get(byName: "external").rootTilingContainer)
        XCTAssertTrue(window.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        window.nativeFocus()
        appForTests = nil
        let started = AwaitableOneTimeBroadcastLatch()
        let release = AwaitableOneTimeBroadcastLatch()
        var resolutions = 0
        uiResumeFocus.rememberCandidate {
            UiResumeFocusCandidate(resolve: {
                resolutions += 1
                if resolutions == 1 {
                    await started.signalToAll()
                    try await release.await()
                }
                return window
            })
        }
        let first = Task { @MainActor in try await runEnableCommandFromUi(.toggle) }
        defer { first.cancel(); Task { await release.signalToAll() } }
        try await awaitResumeGate(started)
        if externalEnable {
            _ = try await parseCommand("enable on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        } else {
            try await runEnableCommandFromUi(.toggle)
        }
        XCTAssertTrue(TrayMenuModel.shared.isEnabled)
        await release.signalToAll()
        try await first.value
        resetFocusCacheForTests()
        XCTAssertTrue(TrayMenuModel.shared.isEnabled)
        XCTAssertEqual(resolutions, externalEnable ? 1 : 2)
    }
    func testSameAppWindowChangeDuringResolutionDoesNotOverrideNewerWindow() async throws {
        let old = TestWindow.new(id: 221, parent: Workspace.get(byName: "old").rootTilingContainer)
        let selected = TestWindow.new(id: 222, parent: Workspace.get(byName: "selected").rootTilingContainer)
        let newer = TestWindow.new(id: 223, parent: Workspace.get(byName: "newer").rootTilingContainer)
        XCTAssertEqual(selected.app.pid, newer.app.pid)
        XCTAssertTrue(old.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        selected.nativeFocus()
        appForTests = nil
        var resolutions = 0
        var focusChecks = 0
        uiResumeFocus.rememberCandidate {
            UiResumeFocusCandidate(isStillFocused: {
                focusChecks += 1
                return TestApp.shared.focusedWindow?.windowId == selected.windowId
            }, resolve: {
                resolutions += 1
                await Task.yield()
                newer.nativeFocus() // Same app: deliberately no remember()/application generation change.
                return selected
            })
        }
        do {
            try await runEnableCommandFromUi(.on)
            XCTFail("A changed same-app window must abort the older resume")
        } catch UiResumeFocusError.focusKeptChanging {}
        resetFocusCacheForTests()
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        XCTAssertTrue(focus.windowOrNil === old)
        XCTAssertTrue(TestApp.shared.focusedWindow === newer)
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(focusChecks, 1)
        try await runEnableCommandFromUi(.on)
        resetFocusCacheForTests()
        XCTAssertTrue(TrayMenuModel.shared.isEnabled)
        XCTAssertTrue(focus.windowOrNil === newer)
        XCTAssertEqual(resolutions, 1)
    }
}

private enum ResumeGateTimeout: Error { case timedOut }
private func awaitResumeGate(_ gate: AwaitableOneTimeBroadcastLatch) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await gate.await() }
        group.addTask { try await Task.sleep(for: .seconds(2)); throw ResumeGateTimeout.timedOut }
        defer { group.cancelAll() }
        _ = try await group.next()
    }
}
