@testable import AppBundle
import Common
import XCTest

// Deterministic callbacks stand in for AX/activation; no OS actions.
@MainActor final class UiResumeFocusGenerationTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
    }
    func testFinalNativeQueryReturningOlderWindowAfterNewActivation() async throws {
        let state = UiResumeFocusState()
        let remembered = TestWindow.new(id: 111, parent: Workspace.get(byName: "remembered").rootTilingContainer)
        let olderNative = TestWindow.new(id: 112, parent: Workspace.get(byName: "older-native").rootTilingContainer)
        let newer = TestWindow.new(id: 113, parent: Workspace.get(byName: "newer").rootTilingContainer)
        state.remember { remembered }
        var queries = 0
        let result = try await state.windowToResume(nativeFocus: {
            queries += 1
            if queries != 2 { return nil }
            await Task.yield()
            state.remember { newer } // A newer external app activated during this older AX request.
            return olderNative
        })
        XCTAssertTrue(result === newer)
    }
    func testInitialNativeQueryReturningOlderWindowAfterNewActivation() async throws {
        let state = UiResumeFocusState()
        let olderNative = TestWindow.new(id: 121, parent: Workspace.get(byName: "older-native").rootTilingContainer)
        let newer = TestWindow.new(id: 122, parent: Workspace.get(byName: "newer").rootTilingContainer)
        state.remember { olderNative }
        var queries = 0
        let result = try await state.windowToResume(nativeFocus: {
            queries += 1
            if queries != 1 { return nil }
            await Task.yield()
            state.remember { newer }
            return olderNative
        })
        XCTAssertTrue(result === newer)
    }
    func testRepeatedGenerationChangesStopAfterBoundedRetries() async throws {
        let state = UiResumeFocusState()
        let stale = TestWindow.new(id: 131, parent: Workspace.get(byName: "stale").rootTilingContainer)
        state.remember { stale }
        var queries = 0
        do {
            _ = try await state.windowToResume(nativeFocus: {
                queries += 1
                await Task.yield()
                state.remember { stale }
                return stale
            })
            XCTFail("Continuous focus changes must abort the resume")
        } catch UiResumeFocusError.focusKeptChanging {}
        XCTAssertEqual(queries, 3)
    }
}
