@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class FocusEventCoordinatorTest: XCTestCase {
    func testCancelledQueryCannotConsumeEvidenceNeededByReplacement() async throws {
        let coordinator = FocusEventCoordinator()
        let staleQuery = SuspendedFocusQuery()
        let freshQuery = SuspendedFocusQuery()
        var applied: [Int] = []
        let first = coordinator.schedule(.ax(kAXFocusedWindowChangedNotification as String)) {
            _ = try await coordinator.syncFocus(consumingEvidence: true, query: staleQuery.read) {
                applied.append($0)
                return true
            }
        }
        await staleQuery.waitUntilRequested()
        let replacement = coordinator.schedule(.ax(kAXMovedNotification as String)) {
            _ = try await coordinator.syncFocus(consumingEvidence: true, query: freshQuery.read) {
                applied.append($0)
                return true
            }
        }
        await freshQuery.waitUntilRequested()
        staleQuery.resume(1)
        do {
            try await first.value
            XCTFail("Cancelled query should throw")
        } catch is CancellationError {
            // The underlying AX query completed despite task cancellation.
        }
        XCTAssertEqual(applied, [])
        freshQuery.resume(2)
        try await replacement.value
        XCTAssertEqual(applied, [2])
        XCTAssertFalse(coordinator.consumeEvidence())
    }

    func testLightSessionLeavesNewerEvidenceForRefresh() async throws {
        let coordinator = FocusEventCoordinator()
        let lightQuery = SuspendedFocusQuery()
        let refreshQuery = SuspendedFocusQuery()
        var applied: [Int] = []
        let light = Task { @MainActor in
            try await coordinator.syncFocus(consumingEvidence: false, query: lightQuery.read) {
                applied.append($0)
                return true
            }
        }
        await lightQuery.waitUntilRequested()
        let refresh = coordinator.schedule(.ax(kAXFocusedWindowChangedNotification as String)) {
            _ = try await coordinator.syncFocus(consumingEvidence: true, query: refreshQuery.read) {
                applied.append($0)
                return true
            }
        }
        await refreshQuery.waitUntilRequested()
        lightQuery.resume(1)
        _ = try await light.value
        refreshQuery.resume(2)
        try await refresh.value
        XCTAssertEqual(applied, [1, 2])
        XCTAssertFalse(coordinator.consumeEvidence())
    }

    func testGeometryOnlyRefreshDoesNotApplyFocus() async throws {
        let coordinator = FocusEventCoordinator()
        var applied = false
        let task = coordinator.schedule(.ax(kAXResizedNotification as String)) {
            _ = try await coordinator.syncFocus(consumingEvidence: true, query: { 1 }) { _ in
                applied = true
                return true
            }
        }
        try await task.value
        XCTAssertFalse(applied)
    }
}

/// Models an AX query that can finish after its requesting task was cancelled.
@MainActor
private final class SuspendedFocusQuery {
    private var result: CheckedContinuation<Int, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    func read() async -> Int {
        await withCheckedContinuation { continuation in
            result = continuation
            requested?.resume()
            requested = nil
        }
    }

    func waitUntilRequested() async {
        if result != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func resume(_ value: Int) {
        result?.resume(returning: value)
        result = nil
    }
}
