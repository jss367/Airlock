import Foundation

nonisolated(unsafe) public var isCli = true
var isServer: Bool { !isCli }

nonisolated(unsafe) public var terminationHandler: TerminationHandler = EmptyTerminationHandler()

struct EmptyTerminationHandler: TerminationHandler {
    func beforeTermination() {}
    func beforeTerminationBlocking(deadline: DispatchTime) -> Bool { true }
}

@MainActor
public protocol TerminationHandler: Sendable {
    func beforeTermination() async throws
    /// Synchronous variant of `beforeTermination` for `die` on the main thread, where async main-actor work can't
    /// run. Must return by `deadline`. Returns whether it finished all of its work.
    func beforeTerminationBlocking(deadline: DispatchTime) -> Bool
}
