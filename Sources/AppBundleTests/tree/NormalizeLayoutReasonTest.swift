@testable import AppBundle
import Common
import XCTest

/// `tile-new-windows` must not change the layout of windows that already exist
@MainActor
final class NormalizeLayoutReasonTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.tileNewWindows = false
    }

    func testTiledWindowStaysTiledAfterNativeFullscreenCommand() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        try await toggleNativeFullscreen(window)
        assertEquals(window.parent?.kind, .tilingContainer)
        assertEquals(window.layoutReason, .standard)
    }

    func testFloatingWindowStaysFloatingAfterNativeFullscreenCommand() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace)
        try await toggleNativeFullscreen(window)
        assertEquals(window.parent?.kind, .workspace)
        assertEquals(window.layoutReason, .standard)
    }

    func testTiledWindowStaysTiledAfterNativeMinimizeCommand() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        window.bindByMacosNativeCommand(to: macosMinimizedWindowsContainer)
        window.isMacosMinimizedForTests = true
        try await normalizeLayoutReason()
        assertEquals(window.layoutReason, .macos(prevParentKind: .tilingContainer))

        window.isMacosMinimizedForTests = false
        try await normalizeLayoutReason()
        assertEquals(window.parent?.kind, .tilingContainer)
        assertEquals(window.layoutReason, .standard)
    }

    func testParentKindIsRememberedWhenCommandRunsAgainBeforeNormalization() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        window.bindByMacosNativeCommand(to: focus.workspace.macOsNativeFullscreenWindowsContainer)
        window.bindByMacosNativeCommand(to: focus.workspace.macOsNativeFullscreenWindowsContainer)
        assertEquals(window.parentKindOutsideMacosState, .tilingContainer)
    }

    private func toggleNativeFullscreen(_ window: TestWindow) async throws {
        let prevParentKind = window.parent?.kind
        window.bindByMacosNativeCommand(to: focus.workspace.macOsNativeFullscreenWindowsContainer)
        try await normalizeLayoutReason() // macOS doesn't report fullscreen yet
        assertEquals(window.parent?.kind, .macosFullscreenWindowsContainer)
        assertEquals(window.parentKindOutsideMacosState, prevParentKind)

        window.isMacosFullscreenForTests = true
        try await normalizeLayoutReason()
        assertEquals(window.parent?.kind, .macosFullscreenWindowsContainer)

        window.isMacosFullscreenForTests = false
        try await normalizeLayoutReason()
    }
}
