@testable import AppBundle
import Common
import XCTest

@MainActor final class UiResumeSessionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
        uiResumeFocus.reset()
    }
    override func tearDown() async throws {
        TrayMenuModel.shared.isEnabled = true
        resetFocusCacheForTests()
        resetFocusStealingPreventionForTests()
        uiResumeFocus.reset()
    }
    func testResumeMustNotRestoreStaleFocusWhenInitialQueryOutlastsGrace() async throws {
        let old = TestWindow.new(id: 151, parent: Workspace.get(byName: "old").rootTilingContainer)
        let external = TestWindow.new(id: 152, parent: Workspace.get(byName: "external").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        old.nativeFocus()
        _ = updateFocusCache(old)
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        external.nativeFocus()
        var now = ContinuousClock().now
        let clock = FocusStealingPreventionState(now: { now })
        clock.markUserInitiatedFocusChange()
        appForTests = SlowResumeFixtureApp {
            await Task.yield()
            now = now.advanced(by: .seconds(2))
            XCTAssertFalse(clock.isUserInitiatedFocusChange)
            // The expired state has the same decision as an unset deadline, without sleeping.
            resetFocusStealingPreventionForTests()
            return external
        }
        try await runEnableCommandFromUi(.on)
        resetFocusCacheForTests()
        XCTAssertTrue(focus.windowOrNil === external)
        XCTAssertEqual(focus.workspace.name, "external")
    }
    func testSpeculativeRegistrationCallbacksMustNotRunWhenRecoveryExhausts() async throws {
        let old = TestWindow.new(id: 161, parent: Workspace.get(byName: "old").rootTilingContainer)
        let external = TestWindow.new(id: 162, parent: Workspace.get(byName: "external").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        appForTests = nil
        var callbackCalls = 0
        @MainActor func queryCandidate() async throws -> UiResumeFocusCandidate? {
            await Task.yield()
            uiResumeFocus.rememberCandidate(queryCandidate)
            return UiResumeFocusCandidate(resolve: {
                callbackCalls += 1 // Stand-in for committed registration/detection, never a real callback.
                return external
            })
        }
        uiResumeFocus.rememberCandidate(queryCandidate)
        do { try await runEnableCommandFromUi(.on) }
        catch UiResumeFocusError.focusKeptChanging {}
        resetFocusCacheForTests()
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        XCTAssertEqual(callbackCalls, 0)
    }
    func testStableCandidateResolvesOnlyOnceAfterSelection() async throws {
        let old = TestWindow.new(id: 171, parent: Workspace.get(byName: "old").rootTilingContainer)
        let external = TestWindow.new(id: 172, parent: Workspace.get(byName: "external").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        appForTests = nil
        var queries = 0
        var committedRegistrations = 0
        uiResumeFocus.rememberCandidate {
            queries += 1
            return UiResumeFocusCandidate(resolve: {
                XCTAssertEqual(queries, 1)
                committedRegistrations += 1
                return external
            })
        }
        try await runEnableCommandFromUi(.on)
        resetFocusCacheForTests()
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(committedRegistrations, 1)
        XCTAssertTrue(TrayMenuModel.shared.isEnabled)
        XCTAssertTrue(focus.windowOrNil === external)
    }

    func testSelectedWindowClosedDuringCommittedResolutionAbortsWithoutRebinding() async throws {
        let old = TestWindow.new(id: 181, parent: Workspace.get(byName: "old").rootTilingContainer)
        let external = TestWindow.new(id: 182, parent: Workspace.get(byName: "external").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        appForTests = nil
        var committedRegistrations = 0
        uiResumeFocus.rememberCandidate {
            UiResumeFocusCandidate(resolve: {
                committedRegistrations += 1
                external.closeAxWindow()
                return external
            })
        }
        do {
            try await runEnableCommandFromUi(.on)
            XCTFail("A lost selected window must abort before enabling")
        } catch UiResumeFocusError.selectedWindowUnavailable {}
        resetFocusCacheForTests()
        XCTAssertEqual(committedRegistrations, 1)
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        XCTAssertFalse(external.isBound)
        XCTAssertTrue(focus.windowOrNil === old)
    }
}

private final class SlowResumeFixtureApp: AbstractApp {
    let pid: Int32 = 999_151
    let rawAppBundleId: String? = "fixture.slow-app"
    let name: String? = "Fixture"
    let execPath: String? = nil
    let bundlePath: String? = nil
    private let query: @MainActor () async throws -> Window?
    init(_ query: @MainActor @escaping () async throws -> Window?) { self.query = query }
    @MainActor func getFocusedWindow() async throws -> Window? { try await query() }
}
