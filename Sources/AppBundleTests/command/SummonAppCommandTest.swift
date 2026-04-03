@testable import AppBundle
import Common
import XCTest

@MainActor
final class SummonAppCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseMissingAppName() {
        assertEquals(
            parseCommand("summon-app").errorOrNil,
            "ERROR: Argument '<app-name>' is mandatory",
        )
    }

    func testParseWithAppName() {
        var expected = SummonAppCmdArgs(rawArgs: [])
        expected.appName = .initialized("Spotify")
        testParseCommandSucc("summon-app Spotify", expected)
    }

    func testParseWithQuotedAppName() {
        var expected = SummonAppCmdArgs(rawArgs: [])
        expected.appName = .initialized("Spotify")
        testParseCommandSucc("summon-app \"Spotify\"", expected)
    }

    func testParseWithNewWindowFlag() {
        var expected = SummonAppCmdArgs(rawArgs: [])
        expected.appName = .initialized("Terminal")
        expected.newWindow = true
        testParseCommandSucc("summon-app --new-window Terminal", expected)
    }

    func testParseNewWindowDefaultFalse() {
        var expected = SummonAppCmdArgs(rawArgs: [])
        expected.appName = .initialized("Safari")
        expected.newWindow = false
        testParseCommandSucc("summon-app Safari", expected)
    }

    func testParseCommandReturnsSummonAppCommand() {
        let parsed = parseCommand("summon-app Finder")
        switch parsed {
        case .cmd(let command):
            XCTAssertTrue(command is SummonAppCommand)
        case .help:
            XCTFail("Expected command, got help")
        case .failure(let msg):
            XCTFail("Expected command, got failure: \(msg)")
        }
    }
}
