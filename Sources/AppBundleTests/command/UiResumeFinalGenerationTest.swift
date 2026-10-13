@testable import AppBundle
import Common
import XCTest

@MainActor final class UiResumeFinalGenerationTest: XCTestCase {
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
    func testNewActivationDuringCommittedResolutionDoesNotFocusOrEnableOlderWindow() async throws {
        let old = TestWindow.new(id: 201, parent: Workspace.get(byName: "old").rootTilingContainer)
        let selected = TestWindow.new(id: 202, parent: Workspace.get(byName: "selected").rootTilingContainer)
        let newer = TestWindow.new(id: 203, parent: Workspace.get(byName: "newer").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        appForTests = nil
        var resolutions = 0
        uiResumeFocus.rememberCandidate {
            UiResumeFocusCandidate(resolve: {
                resolutions += 1
                await Task.yield()
                newer.nativeFocus()
                uiResumeFocus.remember { newer }
                return selected
            })
        }
        do {
            try await runEnableCommandFromUi(.on)
            XCTFail("Changed generation must abort without applying the selected window")
        } catch UiResumeFocusError.focusKeptChanging {}
        resetFocusCacheForTests()
        XCTAssertEqual(resolutions, 1)
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        XCTAssertTrue(focus.windowOrNil === old)
        XCTAssertTrue(TestApp.shared.focusedWindow === newer)
        // No registration retry: a later user action can adopt the newer stable target.
        try await runEnableCommandFromUi(.on)
        resetFocusCacheForTests()
        XCTAssertTrue(TrayMenuModel.shared.isEnabled)
        XCTAssertTrue(focus.windowOrNil === newer)
        XCTAssertEqual(resolutions, 1)
    }
}
