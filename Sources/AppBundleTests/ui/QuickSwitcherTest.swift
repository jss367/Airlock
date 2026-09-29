@testable import AppBundle
import Foundation
import XCTest

final class QuickSwitcherTest: XCTestCase {
    func testWebSearchUrlKeepsQuerySyntaxCharacters() {
        for query in ["c++", "AT&T", "a=b", "50% off", "what is #1?"] {
            let url = webSearchUrl(query: query)
            let q = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .percentEncodedQueryItems?.first { $0.name == "q" }?.value?.removingPercentEncoding
            assertEquals(q, query)
        }
        assertEquals(webSearchUrl(query: "c++")?.absoluteString, "https://google.com/search?q=c%2B%2B")
    }

    @MainActor
    func testPausingReleasesHotkey() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = true
        registerQuickSwitcherHotkey()
        defer {
            TrayMenuModel.shared.isEnabled = true
            config.quickSwitcher.enabled = false
            registerQuickSwitcherHotkey()
        }
        assertEquals(isQuickSwitcherHotkeyRegistered, true)

        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(isQuickSwitcherHotkeyRegistered, false)

        // Reloading config while paused must not re-register it
        registerQuickSwitcherHotkey()
        assertEquals(isQuickSwitcherHotkeyRegistered, false)

        _ = try await parseCommand("enable on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(isQuickSwitcherHotkeyRegistered, true)
    }
}
