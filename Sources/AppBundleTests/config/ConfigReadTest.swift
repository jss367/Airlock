@testable import AppBundle
import Common
import XCTest

@MainActor
final class ConfigReadTest: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
        setUpWorkspacesForTests()
    }

    func testExplicitMissingPathIsNotReplacedWithDefaults() {
        let url = directory.appending(path: "missing.toml")
        XCTAssertEqual(findCustomConfigUrl(configLocation: url.path).urlOrNil, url)
        assertReadFailure(url)
    }

    func testDirectoryAndInvalidEncodingAreReadFailures() throws {
        assertReadFailure(directory)
        let url = directory.appending(path: "invalid.toml")
        try Data([0xFF, 0xFE, 0xFF]).write(to: url)
        assertReadFailure(url)
    }

    func testFailedReloadPreservesActiveConfiguration() async throws {
        config.accordionPadding = 123
        let previousUrl = configUrl
        let previousMode = activeMode
        var args = ReloadConfigCmdArgs(rawArgs: [])
        args.noGui = true
        var output = ""
        let result = try await reloadConfig(args: args, forceConfigUrl: directory.appending(path: "missing.toml"), stdout: &output)
        XCTAssertFalse(result)
        XCTAssertEqual(config.accordionPadding, 123)
        XCTAssertEqual(configUrl, previousUrl)
        XCTAssertEqual(activeMode, previousMode)
        XCTAssertTrue(output.contains("Failed to read"))
    }

    func testReadableConfigStillParsesAndSyntaxErrorsStillReport() throws {
        let url = directory.appending(path: "config.toml")
        try "accordion-padding = 42".write(to: url, atomically: true, encoding: .utf8)
        let (parsed, actualUrl) = try readConfig(forceConfigUrl: url).get()
        XCTAssertEqual(parsed.accordionPadding, 42)
        XCTAssertEqual(actualUrl, url)
        try "accordion-padding = [".write(to: url, atomically: true, encoding: .utf8)
        guard case .failure(let message) = readConfig(forceConfigUrl: url) else {
            return XCTFail("Expected a syntax error")
        }
        XCTAssertTrue(message.contains("Failed to parse"))
    }

    private func assertReadFailure(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let message) = readConfig(forceConfigUrl: url) else {
            return XCTFail("Unreadable config must not succeed with defaults", file: file, line: line)
        }
        XCTAssertTrue(message.contains("Failed to read"), file: file, line: line)
        XCTAssertTrue(message.contains(url.path), file: file, line: line)
    }
}
