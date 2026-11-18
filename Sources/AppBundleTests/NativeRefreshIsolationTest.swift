@testable import AppBundle
import XCTest

@MainActor
final class NativeRefreshIsolationTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        sessionCoordinator.setEnabled(true)
        appForTests = TestApp.shared
        config.focusFlash.enabled = false
        focusEvents.reset()
        resetFocusCacheForTests()
    }

    override func tearDown() async throws {
        focusEvents.reset()
        resetFocusCacheForTests()
        appForTests = nil
    }

    func testMockRefreshNeverDiscoversHostApplications() async throws {
        var discoveries = 0
        let alive = try await MacApp.refreshAllAndGetAliveWindowIds(frontmostAppBundleId: "com.apple.finder") {
            discoveries += 1
            XCTFail("Mock-based tests must not discover real AX applications")
            return []
        }
        XCTAssertEqual(discoveries, 0)
        XCTAssertTrue(alive.isEmpty)
        XCTAssertTrue(MacApp.allAppsMap.isEmpty)
    }

    func testHotkeyFullRefreshPreservesMockWindowsAndFocus() async throws {
        let window = TestWindow.new(id: 987_001, parent: focus.workspace.rootTilingContainer)
        XCTAssertTrue(window.focusWindow())
        window.nativeFocus()

        // Reproduce the background full refresh scheduled by a hotkey/light session,
        // await it explicitly so the test cannot finish while native discovery runs.
        try await runRefreshSessionBlocking(.hotkeyBinding)

        XCTAssertTrue(focus.windowOrNil === window)
        XCTAssertTrue(TestApp.shared.focusedWindow === window)
        XCTAssertTrue(Window.get(byId: window.windowId) === window)
        XCTAssertTrue(MacApp.allAppsMap.isEmpty)
        XCTAssertTrue(MacWindow.allWindows.isEmpty)
    }
}
