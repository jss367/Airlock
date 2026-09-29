import Common

@MainActor
final class FocusEventCoordinator {
    var lastKnownNativeFocusedWindowId: UInt32?
    private var pendingEvidence = false
    private var activeRefreshTask: Task<Void, any Error>?

    func note(_ event: RefreshSessionEvent) {
        if event.mayHaveChangedFocus { pendingEvidence = true }
    }

    func consumeEvidence() -> Bool {
        defer { pendingEvidence = false }
        return pendingEvidence
    }

    @discardableResult
    func schedule(_ event: RefreshSessionEvent, operation: @escaping @MainActor () async throws -> Void) -> Task<Void, any Error> {
        // Evidence survives coalescing, including replacement by a move/resize with none of its own.
        note(event)
        cancelRefresh()
        let task = Task { @MainActor in
            try checkCancellation()
            try await operation()
        }
        activeRefreshTask = task
        return task
    }

    func cancelRefresh() {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
    }

    func syncFocus<T>(
        consumingEvidence: Bool,
        query: @MainActor () async throws -> T,
        apply: (T) -> Bool,
    ) async throws -> Bool {
        let nativeFocus = try await query()
        if consumingEvidence {
            // AX queries can return a value after cancellation. Never spend evidence on that stale
            // answer. Consumption and application must stay together, without a suspension point.
            try checkCancellation()
            guard consumeEvidence() else { return false }
        }
        // Light sessions cannot be cancelled by a newer refresh, so they must leave its evidence
        // intact even when their own query returns an older snapshot.
        return apply(nativeFocus)
    }

    func reset() {
        cancelRefresh()
        pendingEvidence = false
        lastKnownNativeFocusedWindowId = nil
    }
}
