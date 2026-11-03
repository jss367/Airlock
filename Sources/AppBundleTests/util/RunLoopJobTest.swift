@testable import AppBundle
import Foundation
import XCTest

final class RunLoopJobTest: XCTestCase {
    func testCancellationIsPermanentAndIdempotent() throws {
        let job = RunLoopJob()
        XCTAssertFalse(job.isCancelled)
        XCTAssertNoThrow(try job.checkCancellation())
        job.cancel()
        job.cancel()
        XCTAssertTrue(job.isCancelled)
        XCTAssertThrowsError(try job.checkCancellation()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testConcurrentCancellationAndReads() {
        let job = RunLoopJob()
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            if index.isMultiple(of: 2) {
                job.cancel()
            } else {
                _ = job.isCancelled
                _ = try? job.checkCancellation()
            }
        }
        XCTAssertTrue(job.isCancelled)
        XCTAssertThrowsError(try job.checkCancellation()) { XCTAssertTrue($0 is CancellationError) }
    }
}
