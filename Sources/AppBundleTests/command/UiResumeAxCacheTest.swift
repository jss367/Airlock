@testable import AppBundle
import Common
import XCTest

@MainActor final class UiResumeAxCacheTest: XCTestCase {
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
    func testFirstPausedWindowHasMetadataBeforeModelRegistrationAndTitleRule() async throws {
        let old = TestWindow.new(id: 191, parent: Workspace.get(byName: "old").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        appForTests = nil
        let id: UInt32 = 192
        let axCache = FakeResumeAxCache()
        let workspace = Workspace.get(byName: "external")
        var titleRules = 0
        var registeredRect: Rect?
        var registeredType: String?
        uiResumeFocus.rememberCandidate {
            UiResumeFocusCandidate(resolveValidated: { validate in
                try await registerFocusedWindowWithAxCache(
                    expectedWindowId: id,
                    registerAxWindow: {
                        axCache.windows[id] = .init(rect: Rect(topLeftX: 100, topLeftY: 120, width: 500, height: 300), title: "Work", type: "standard")
                        return id
                    },
                    beforeModelRegistration: validate,
                    registerModelWindow: { registeredId in
                        let data = axCache.windows[registeredId]
                        registeredRect = data?.rect
                        registeredType = data?.type
                        if data?.title == "Work" { titleRules += 1 }
                        return TestWindow.new(id: registeredId, parent: workspace.rootTilingContainer, rect: data?.rect)
                    },
                )
            })
        }
        try await runEnableCommandFromUi(.on)
        resetFocusCacheForTests()
        XCTAssertNotNil(registeredRect)
        XCTAssertEqual(registeredType, "standard")
        XCTAssertEqual(titleRules, 1)
        XCTAssertEqual(focus.windowOrNil?.windowId, id)
    }
    func testMismatchedSnapshotDoesNotRunModelRegistration() async throws {
        var modelRegistrations = 0
        let result = try await registerFocusedWindowWithAxCache(
            expectedWindowId: 193,
            registerAxWindow: { 194 },
            registerModelWindow: { _ in modelRegistrations += 1; return nil },
        )
        XCTAssertNil(result)
        XCTAssertEqual(modelRegistrations, 0)
    }

    func testFailedAxCacheRegistrationDoesNotRunModelRegistration() async throws {
        var modelRegistrations = 0
        let result = try await registerFocusedWindowWithAxCache(
            expectedWindowId: 195,
            registerAxWindow: { nil },
            registerModelWindow: { _ in modelRegistrations += 1; return nil },
        )
        XCTAssertNil(result)
        XCTAssertEqual(modelRegistrations, 0)
    }

    func testNewActivationDuringAxCacheRegistrationSkipsModelCallbacks() async throws {
        let old = TestWindow.new(id: 196, parent: Workspace.get(byName: "old").rootTilingContainer)
        let newer = TestWindow.new(id: 197, parent: Workspace.get(byName: "newer").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        appForTests = nil
        var modelCallbacks = 0
        uiResumeFocus.rememberCandidate {
            UiResumeFocusCandidate(resolveValidated: { validate in
                try await registerFocusedWindowWithAxCache(
                    expectedWindowId: 198,
                    registerAxWindow: {
                        await Task.yield()
                        newer.nativeFocus()
                        uiResumeFocus.remember { newer }
                        return 198
                    },
                    beforeModelRegistration: validate,
                    registerModelWindow: { _ in modelCallbacks += 1; return nil },
                )
            })
        }
        do {
            try await runEnableCommandFromUi(.on)
            XCTFail("Changed generation must abort before model callbacks")
        } catch UiResumeFocusError.focusKeptChanging {}
        XCTAssertEqual(modelCallbacks, 0)
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        XCTAssertTrue(focus.windowOrNil === old)
        XCTAssertTrue(TestApp.shared.focusedWindow === newer)
    }
}

@MainActor private final class FakeResumeAxCache {
    struct Entry { let rect: Rect; let title: String; let type: String }
    var windows: [UInt32: Entry] = [:]
}
