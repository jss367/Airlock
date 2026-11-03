import Common
import Foundation
import Synchronization

extension Thread {
    @discardableResult
    func runInLoopAsync(
        job: RunLoopJob = RunLoopJob(),
        autoCheckCancelled: Bool = true,
        _ body: @Sendable @escaping (RunLoopJob) -> (),
    ) -> RunLoopJob {
        let action = RunLoopAction(job: job, autoCheckCancelled: autoCheckCancelled, body)
        // Alternative: CFRunLoopPerformBlock + CFRunLoopWakeUp
        action.perform(#selector(action.action), on: self, with: nil, waitUntilDone: false)
        return job
    }

    func runInLoop<T>(_ body: @Sendable @escaping (RunLoopJob) throws -> T) async throws -> T {
        try checkCancellation()
        let job = RunLoopJob()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // It's unsafe to implicitly cancel because cont.resume should be invoked exactly once
                self.runInLoopAsync(job: job, autoCheckCancelled: false) { job in
                    do {
                        try job.checkCancellation()
                        cont.resume(returning: try body(job))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            job.cancel()
        }
    }

    /// Blocks the calling thread until `body` has run in this thread's loop, or until `deadline`. Returns nil on
    /// timeout or if `body` threw. Only for termination on the main thread, where `runInLoop` can't be awaited.
    func runInLoopBlocking<T>(deadline: DispatchTime, _ body: @Sendable @escaping (RunLoopJob) throws -> T?) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: T? = nil
        let job = runInLoopAsync { job in
            result = try? body(job)
            semaphore.signal()
        }
        if semaphore.wait(timeout: deadline) == .timedOut {
            job.cancel()
            return nil
        }
        return result
    }
}

private final class RunLoopAction: NSObject, Sendable {
    private let _action: @Sendable (RunLoopJob) -> ()
    let job: RunLoopJob
    private let autoCheckCancelled: Bool
    private let _refreshSessionEvent: RefreshSessionEvent?
    init(job: RunLoopJob, autoCheckCancelled: Bool, _ action: @escaping @Sendable (RunLoopJob) -> ()) {
        self.job = job
        self.autoCheckCancelled = autoCheckCancelled
        _action = action
        _refreshSessionEvent = refreshSessionEvent
    }
    @objc func action() {
        if autoCheckCancelled && job.isCancelled { return }
        $refreshSessionEvent.withValue(_refreshSessionEvent) {
            _action(job)
        }
    }
}

final class RunLoopJob: Sendable, AeroAny {
    // Cancellation is a standalone flag; it does not publish any other shared state.
    private let _isCancelled = Atomic<Bool>(false)
    var isCancelled: Bool { _isCancelled.load(ordering: .relaxed) }
    func cancel() {
        _isCancelled.store(true, ordering: .relaxed)
    }

    static let cancelled: RunLoopJob = RunLoopJob().also { $0.cancel() }

    func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
}
