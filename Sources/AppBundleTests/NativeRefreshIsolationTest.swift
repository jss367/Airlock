@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class NativeRefreshIsolationTest: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared // A full refresh also updates the secure-input panel.
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

    func testFullRefreshUsesMockAppHiddenState() async throws {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 987_002, parent: workspace.rootTilingContainer)
        config.automaticallyUnhideMacosHiddenApps = false
        window.isMacosAppHiddenForTests = true

        try await runRefreshSessionBlocking(.hotkeyBinding)
        XCTAssertTrue(window.parent === workspace.macOsNativeHiddenAppsWindowsContainer)

        window.isMacosAppHiddenForTests = false
        try await runRefreshSessionBlocking(.hotkeyBinding)
        XCTAssertTrue(window.nodeWorkspace === workspace)
        XCTAssertFalse(window.parent === workspace.macOsNativeHiddenAppsWindowsContainer)
        XCTAssertTrue(MacApp.allAppsMap.isEmpty)
    }
}
