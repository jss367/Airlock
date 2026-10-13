@testable import AppBundle
import Common
import XCTest

@MainActor
final class ModeCommandTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        activeMode = mainModeId
    }
    override func tearDown() async throws { activeMode = mainModeId }

    func testUnknownModePreservesPausedMode() async throws {
        activeMode = nil
        let result = try await parseCommand("mode resiz").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 1)
        assertEquals(activeMode, nil)
    }

    func testUnknownModeIsRejected() async throws {
        let result = try await parseCommand("mode resiz").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 1)
        assertEquals(result.stderr, ["Mode 'resiz' doesn't exist. Available modes: main"])
        assertEquals(activeMode, mainModeId)
    }
}
