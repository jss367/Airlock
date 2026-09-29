@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class ErrorReportingTest: XCTestCase {
    private var previousMessage: Message?
    private let failure = NSError(domain: "AirlockTests", code: 42, userInfo: [NSLocalizedDescriptionKey: "Permission denied"])

    override func setUp() async throws {
        previousMessage = MessageModel.shared.message
        MessageModel.shared.message = nil
    }

    override func tearDown() async throws {
        MessageModel.shared.message = previousMessage
    }

    func testUserActionFailureIncludesOperationAndUnderlyingError() async throws {
        let succeeded = await withErrorReporting("Starting Airlock", userMessage: "Airlock could not finish starting.") {
            throw failure
        }

        XCTAssertFalse(succeeded)
        let message = try XCTUnwrap(MessageModel.shared.message)
        XCTAssertEqual(message.type, .runtime)
        XCTAssertEqual(message.description, "Airlock could not finish starting.")
        XCTAssertTrue(message.body.contains("Starting Airlock"))
        XCTAssertTrue(message.body.contains("Permission denied"))
        XCTAssertTrue(message.body.contains("AirlockTests, code 42"))
    }

    func testBackgroundFailurePreservesExistingUserMessage() async throws {
        let existing = Message(description: "Config error", body: "Fix the configuration")
        MessageModel.shared.message = existing

        let succeeded = await withErrorReporting("Refreshing windows") { throw failure }

        XCTAssertFalse(succeeded)
        XCTAssertEqual(MessageModel.shared.message, existing)
        let report = try XCTUnwrap(AppErrorReport(failure, operation: "Refreshing windows"))
        XCTAssertEqual(report.operation, "Refreshing windows")
        XCTAssertEqual(report.domain, "AirlockTests")
        XCTAssertEqual(report.code, 42)
        XCTAssertTrue(report.details.contains("Permission denied"))
    }

    func testCancellationProducesNeitherDiagnosticNorUserMessage() async {
        XCTAssertNil(AppErrorReport(CancellationError(), operation: "Refreshing windows"))
        let existing = Message(description: "Config error", body: "Fix the configuration")
        MessageModel.shared.message = existing

        let succeeded = await withErrorReporting("Reloading configuration", userMessage: "Reload failed") {
            throw CancellationError()
        }

        XCTAssertFalse(succeeded)
        XCTAssertEqual(MessageModel.shared.message, existing)
    }

    func testSuccessfulActionRunsOnceAndPreservesExistingMessage() async {
        let existing = Message(description: "Config error", body: "Fix the configuration")
        MessageModel.shared.message = existing
        var calls = 0

        let succeeded = await withErrorReporting("Switching workspace", userMessage: "Switch failed") { calls += 1 }

        XCTAssertTrue(succeeded)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(MessageModel.shared.message, existing)
    }

    func testCancelledTaskStillReportsAnUnrelatedFailure() async {
        // Do not use Task.isCancelled to suppress all errors: a real I/O failure may race cancellation.
        let task = Task { @MainActor in
            await withErrorReporting("Saving configuration", userMessage: "Save failed") { throw self.failure }
        }
        task.cancel()

        let succeeded = await task.value
        XCTAssertFalse(succeeded)
        XCTAssertEqual(MessageModel.shared.message?.description, "Save failed")
    }

    func testFailedRefreshDoesNotPreventTheNextRefresh() async throws {
        let coordinator = FocusEventCoordinator()
        let failed = coordinator.schedule(.startup) {
            await withErrorReporting("Refreshing windows") { throw self.failure }
        }
        try await failed.value
        XCTAssertNil(MessageModel.shared.message)

        var refreshed = false
        let next = coordinator.schedule(.startup) {
            await withErrorReporting("Refreshing windows") { refreshed = true }
        }
        try await next.value
        XCTAssertTrue(refreshed)
    }

    func testSettingsProcessReportsNonzeroExit() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/false")
        XCTAssertThrowsError(try runSettingsProcess(process)) { error in
            XCTAssertEqual((error as NSError).domain, "Airlock.SettingsProcess")
            XCTAssertEqual((error as NSError).code, 1)
        }
    }

    func testSettingsProcessPropagatesLaunchFailureWithoutWaiting() {
        let process = Process()
        process.executableURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        XCTAssertThrowsError(try runSettingsProcess(process))
    }

    func testSettingsProcessAcceptsSuccessfulExit() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/true")
        try runSettingsProcess(process)
    }
}
