import Combine

@MainActor let sessionCoordinator = SessionCoordinator()

/// Owns running state and invocation ordering. UI models observe this state; they do not own it.
@MainActor
final class SessionCoordinator: ObservableObject {
    @Published private(set) var isEnabled = true
    private var invocationSequence = 0
    private(set) var latestEnableIntent = 0

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
    }

    func reserveInvocationOrder() -> Int {
        invocationSequence += 1
        return invocationSequence
    }

    func beginEnableIntent() -> Int {
        let intent = reserveInvocationOrder()
        latestEnableIntent = intent
        return intent
    }

    func acceptEnableIntent(_ intent: Int) -> Bool {
        guard intent >= latestEnableIntent else { return false }
        latestEnableIntent = intent
        return true
    }

    func isCurrent(_ intent: Int) -> Bool { intent == latestEnableIntent }

    func validateInvocation(_ intent: Int) throws {
        guard intent >= latestEnableIntent else { throw CancellationError() }
    }

    func validateEnabledSession(_ intent: Int) throws {
        guard isEnabled, isCurrent(intent) else { throw CancellationError() }
    }
}

/// Captured before queuing work and checked by the session before and after suspending.
/// Ordinary UI actions require the same enabled generation. Command invocations may intentionally
/// pause/resume, but must still yield to a newer explicit invocation.
struct RunSessionGuard: Sendable {
    private let check: @MainActor @Sendable () throws -> Void
    let invocationOrder: Int?

    private init(invocationOrder: Int? = nil, check: @MainActor @Sendable @escaping () throws -> Void) {
        self.invocationOrder = invocationOrder
        self.check = check
    }

    @MainActor
    static var enabled: RunSessionGuard {
        let intent = sessionCoordinator.latestEnableIntent
        return RunSessionGuard { try sessionCoordinator.validateEnabledSession(intent) }
    }

    @MainActor
    static var isServerEnabled: RunSessionGuard? { sessionCoordinator.isEnabled ? enabled : nil }

    /// A configured callback belongs to its invoking command, including intentional enable changes.
    @MainActor
    static var forCallback: RunSessionGuard? {
        guard sessionCoordinator.isEnabled else { return nil }
        return command(intent: CommandInvocationIntent.order ?? sessionCoordinator.reserveInvocationOrder())
    }

    static func command(intent: Int, check: @MainActor @Sendable @escaping () throws -> Void = {}) -> RunSessionGuard {
        RunSessionGuard(invocationOrder: intent, check: check)
    }

    // Startup callbacks may pause intentionally, but must yield to a later user invocation.
    @MainActor
    static var startup: RunSessionGuard { command(intent: sessionCoordinator.reserveInvocationOrder()) }

    @MainActor func validateAdmission() throws {
        if let invocationOrder { try sessionCoordinator.validateInvocation(invocationOrder) }
        try check()
    }
}
