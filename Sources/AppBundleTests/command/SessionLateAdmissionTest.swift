@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor final class SessionLateAdmissionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
        uiResumeFocus.reset()
        ModeCallbackFocusFixtureCommand.newer = nil
        ModeCallbackFocusFixtureCommand.noopEnable = false
        ModeCallbackFocusFixtureCommand.activation = false
        ModeCallbackFocusFixtureCommand.calls = 0
    }
    override func tearDown() async throws {
        config.onModeChanged = []
        TrayMenuModel.shared.isEnabled = true
        activeMode = mainModeId
        resetFocusCacheForTests()
        uiResumeFocus.reset()
    }
    func testUnrelatedResumeCancellationStillPropagates() async throws {
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        appForTests = nil
        uiResumeFocus.rememberCandidate { UiResumeFocusCandidate(resolve: { throw CancellationError() }) }
        do {
            try await runEnableCommandFromUi(.on)
            XCTFail("Cancellation without a newer intent must propagate")
        } catch is CancellationError {}
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
    }
    func testPauseDuringFloatingLayoutStopsRemainingHiddenWindowMutations() async throws {
        let visible = Workspace.get(byName: "visible")
        let selected = TestWindow.new(id: 351, parent: visible.rootTilingContainer)
        let floating = FakeLayoutWindow(352, parent: visible)
        let hidden = FakeLayoutWindow(353, parent: Workspace.get(byName: "hidden").rootTilingContainer)
        XCTAssertTrue(selected.focusWindow())
        selected.nativeFocus()
        let check = captureEnabledSessionAdmission()
        var queries = 0
        floating.rectQuery = {
            queries += 1
            await Task.yield()
            try await self.pauseThroughSocket()
            return floating.rect
        }
        do { try await runAppLauncherWindowSession(selected, admissionCheck: check) {} }
        catch is CancellationError {}
        XCTAssertEqual(queries, 1)
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        XCTAssertEqual(hidden.hideWrites, 0)
        XCTAssertFalse(hidden.hidden)
    }
    func testPauseDuringHideMetadataStopsItsFrameWriteWithoutReplayingEarlierHide() async throws {
        let selected = TestWindow.new(id: 354, parent: Workspace.get(byName: "visible").rootTilingContainer)
        let hiddenWorkspace = Workspace.get(byName: "hidden")
        let admitted = FakeLayoutWindow(355, parent: hiddenWorkspace.rootTilingContainer)
        let pending = FakeLayoutWindow(356, parent: hiddenWorkspace.rootTilingContainer)
        XCTAssertTrue(selected.focusWindow())
        selected.nativeFocus()
        let check = captureEnabledSessionAdmission()
        pending.hideQuery = {
            await Task.yield()
            try await self.pauseThroughSocket()
        }
        do { try await runAppLauncherWindowSession(selected, admissionCheck: check) {} }
        catch is CancellationError {}
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        XCTAssertEqual(admitted.hideWrites, 1)
        XCTAssertEqual(pending.hideWrites, 0)
        XCTAssertFalse(admitted.hidden)
        XCTAssertFalse(pending.hidden)
    }
    func testSameAppFocusChangeDuringEnableSizeQueryCannotRestoreSelectedWindow() async throws {
        try await exerciseFocusChangeDuringSize(activation: false)
    }
    func testApplicationActivationDuringEnableSizeQueryInvalidatesSelection() async throws {
        try await exerciseFocusChangeDuringSize(activation: true)
    }
    private func exerciseFocusChangeDuringSize(activation: Bool) async throws {
        let old = TestWindow.new(id: 359, parent: Workspace.get(byName: "old").rootTilingContainer)
        let selected = TestWindow.new(id: 357, parent: Workspace.get(byName: "selected"))
        let newer = TestWindow.new(id: 358, parent: Workspace.get(byName: "newer").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        selected.nativeFocus()
        appForTests = nil
        uiResumeFocus.rememberCandidate {
            UiResumeFocusCandidate(isStillFocused: { TestApp.shared.focusedWindow === selected }, resolve: { selected })
        }
        selected.sizeQueryForTests = {
            await Task.yield()
            newer.nativeFocus()
            if activation { uiResumeFocus.remember { newer } }
            return nil
        }
        do {
            try await runEnableCommandFromUi(.on)
            XCTFail("Changed focus during pre-enable metadata must abort")
        } catch UiResumeFocusError.focusKeptChanging {}
        XCTAssertTrue(TestApp.shared.focusedWindow === newer)
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        XCTAssertNil(activeMode)
        selected.sizeQueryForTests = nil
        try await runEnableCommandFromUi(.on)
        XCTAssertTrue(TrayMenuModel.shared.isEnabled)
        XCTAssertEqual(activeMode, mainModeId)
        XCTAssertTrue(TestApp.shared.focusedWindow === newer)
    }
    func testNestedNoopEnableInModeCallbackDoesNotCancelUiResume() async throws {
        let old = TestWindow.new(id: 369, parent: Workspace.get(byName: "old").rootTilingContainer)
        let selected = TestWindow.new(id: 370, parent: Workspace.get(byName: "selected").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        selected.nativeFocus()
        appForTests = nil
        uiResumeFocus.rememberCandidate {
            UiResumeFocusCandidate(isStillFocused: { TestApp.shared.focusedWindow === selected }, resolve: { selected })
        }
        ModeCallbackFocusFixtureCommand.noopEnable = true
        defer { ModeCallbackFocusFixtureCommand.noopEnable = false }
        config.onModeChanged = [ModeCallbackFocusFixtureCommand()]
        try await runEnableCommandFromUi(.on)
        XCTAssertTrue(TrayMenuModel.shared.isEnabled)
        XCTAssertEqual(activeMode, mainModeId)
        XCTAssertTrue(focus.windowOrNil === selected)
        XCTAssertTrue(selected.nodeWorkspace?.isVisible == true)
        XCTAssertTrue(TestApp.shared.focusedWindow === selected)
    }
    func testSameAppFocusChangeDuringAdmittedModeCallbackCannotRestoreSelectedWindow() async throws {
        try await exerciseModeCallbackFocus(activation: false)
    }
    func testActivationDuringAdmittedModeCallbackInvalidatesSelection() async throws {
        try await exerciseModeCallbackFocus(activation: true)
    }
    private func exerciseModeCallbackFocus(activation: Bool) async throws {
        let old = TestWindow.new(id: 361, parent: Workspace.get(byName: "old").rootTilingContainer)
        let selected = TestWindow.new(id: 362, parent: Workspace.get(byName: "selected").rootTilingContainer)
        let newer = TestWindow.new(id: 363, parent: Workspace.get(byName: "newer").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        selected.nativeFocus()
        appForTests = nil
        uiResumeFocus.rememberCandidate {
            UiResumeFocusCandidate(isStillFocused: { TestApp.shared.focusedWindow === selected }, resolve: { selected })
        }
        ModeCallbackFocusFixtureCommand.newer = newer
        ModeCallbackFocusFixtureCommand.activation = activation
        ModeCallbackFocusFixtureCommand.calls = 0
        config.onModeChanged = [ModeCallbackFocusFixtureCommand()]
        do {
            try await runEnableCommandFromUi(.on)
            XCTFail("A changed selection must stop the old session postlude")
        } catch UiResumeFocusError.focusKeptChanging {}
        XCTAssertEqual(ModeCallbackFocusFixtureCommand.calls, 1)
        XCTAssertTrue(TestApp.shared.focusedWindow === newer)
        // Enable/mode and the callback were admitted while valid. Preserve their effects.
        XCTAssertTrue(TrayMenuModel.shared.isEnabled)
        XCTAssertEqual(activeMode, mainModeId)
        config.onModeChanged = []
        ModeCallbackFocusFixtureCommand.newer = nil
    }
    func testSameAppFocusChangeDuringResumeLayoutStopsRemainingHidesAndNativeRestoration() async throws {
        let old = TestWindow.new(id: 364, parent: Workspace.get(byName: "old").rootTilingContainer)
        let selectedWorkspace = Workspace.get(byName: "selected")
        let selected = TestWindow.new(id: 365, parent: selectedWorkspace.rootTilingContainer)
        let floating = FakeLayoutWindow(366, parent: selectedWorkspace)
        let newer = TestWindow.new(id: 367, parent: Workspace.get(byName: "newer").rootTilingContainer)
        let hidden = FakeLayoutWindow(368, parent: Workspace.get(byName: "hidden").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        selected.nativeFocus()
        appForTests = nil
        uiResumeFocus.rememberCandidate {
            UiResumeFocusCandidate(isStillFocused: { TestApp.shared.focusedWindow === selected }, resolve: { selected })
        }
        floating.rectQuery = { await Task.yield(); newer.nativeFocus(); return floating.rect }
        do { try await runEnableCommandFromUi(.on); XCTFail("Layout must stop on changed focus") }
        catch UiResumeFocusError.focusKeptChanging {}
        XCTAssertEqual(hidden.hideWrites, 0)
        XCTAssertTrue(TestApp.shared.focusedWindow === newer)
        XCTAssertTrue(TrayMenuModel.shared.isEnabled)
        XCTAssertEqual(activeMode, mainModeId)
    }
    private func pauseThroughSocket() async throws {
        let request = ClientRequest(args: ["enable", "off"], stdin: "", windowId: nil, workspace: nil)
        _ = try await runSocketCommandSession(parseCommand("enable off").cmdOrDie, request: request, token: .forceRun)
    }
}

/// Entirely synthetic AX/layout backend; no MacWindow, app activation, frames or real window calls.
private final class FakeLayoutWindow: Window {
    var rect = Rect(topLeftX: 100, topLeftY: 100, width: 200, height: 200)
    var rectQuery: (@MainActor () async throws -> Rect?)?
    var hideQuery: (@MainActor () async throws -> Void)?
    var hidden = false
    var hideWrites = 0
    @MainActor init(_ id: UInt32, parent: NonLeafTreeNodeObject) {
        super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        TestApp.shared._windows.append(self)
    }
    override func getAxSize() async throws -> CGSize? { rect.size }
    override var title: String { get async { "Fixture" } }
    override var isHiddenInCorner: Bool { hidden }
    @MainActor override func nativeFocus() { appForTests = TestApp.shared; TestApp.shared.focusedWindow = self }
    @MainActor override func closeAxWindow() { unbindFromParent() }
    @MainActor override func getAxRect() async throws -> Rect? {
        if let query = rectQuery { rectQuery = nil; return try await query() }
        return rect
    }
    override func setAxFrame(_ point: CGPoint?, _ size: CGSize?) {}
    @MainActor override func hideInCorner(_ corner: OptimalHideCorner, admissionCheck: @MainActor () async throws -> Void = {}) async throws {
        if let query = hideQuery { hideQuery = nil; try await query() }
        try await admissionCheck()
        hideWrites += 1
        hidden = true
    }
    @MainActor override func unhideFromCorner(restoreTilingPosition: Bool = false) { hidden = false }
}

/// Fake configured callback: changes only the test app's in-memory focus, never AX/UI.
private struct ModeCallbackFocusFixtureCommand: Command {
    let args = EnableCmdArgs(rawArgs: [], targetState: .on)
    let shouldResetClosedWindowsCache = false
    @MainActor static var newer: Window?
    @MainActor static var activation = false
    @MainActor static var calls = 0
    @MainActor static var noopEnable = false
    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        await Task.yield()
        Self.calls += 1
        if Self.noopEnable { _ = try await parseCommand("enable on").cmdOrDie.run(env, .emptyStdin) }
        Self.newer?.nativeFocus()
        if Self.activation { uiResumeFocus.remember { Self.newer } }
        return true
    }
}
