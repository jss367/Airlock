@testable import Common
import Foundation
import XCTest

final class TerminationHandlerTest: XCTestCase {
    // Regression: die on the main thread used to start a Task needing the main actor and then block the main thread
    // waiting for it, which hung forever instead of crashing
    @MainActor
    func testMainThreadRunsBlockingVariantWithoutDeadlock() {
        let handler = FakeTerminationHandler(blockingResult: true)
        XCTAssertTrue(runTerminationHandlerBeforeDying(handler, timeout: .seconds(5)))
        XCTAssertEqual(handler.calls.value, ["blocking"])
    }

    @MainActor
    func testMainThreadReportsBlockingVariantTimeout() {
        let handler = FakeTerminationHandler(blockingResult: false)
        XCTAssertFalse(runTerminationHandlerBeforeDying(handler, timeout: .seconds(5)))
    }

    func testBackgroundThreadRunsAsyncVariantOnMainActor() async {
        let handler = FakeTerminationHandler(blockingResult: true)
        let finished = await runOnBackgroundThread { runTerminationHandlerBeforeDying(handler, timeout: .seconds(5)) }
        XCTAssertTrue(finished)
        XCTAssertEqual(handler.calls.value, ["async"])
    }

    func testBackgroundThreadGivesUpOnHangingHandler() async {
        let handler = FakeTerminationHandler(blockingResult: true, asyncHangs: true)
        let start = Date.now
        let finished = await runOnBackgroundThread { runTerminationHandlerBeforeDying(handler, timeout: .milliseconds(200)) }
        XCTAssertFalse(finished)
        XCTAssertLessThan(Date.now.timeIntervalSince(start), 5)
    }
}

private func runOnBackgroundThread(_ body: @Sendable @escaping () -> Bool) async -> Bool {
    await withCheckedContinuation { cont in
        Thread.detachNewThread { cont.resume(returning: body()) }
    }
}

private final class LockedCalls: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var _value: [String] = []
    var value: [String] { lock.withLock { _value } }
    func append(_ call: String) { lock.withLock { _value.append(call) } }
}

private struct FakeTerminationHandler: TerminationHandler {
    let blockingResult: Bool
    var asyncHangs = false
    let calls = LockedCalls()

    func beforeTermination() async throws {
        calls.append("async")
        if asyncHangs {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    func beforeTerminationBlocking(deadline: DispatchTime) -> Bool {
        calls.append("blocking")
        return blockingResult
    }
}
