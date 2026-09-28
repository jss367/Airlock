import Common
import XCTest

final class LateinitTest: XCTestCase {
    func testEquality() {
        XCTAssertEqual(Lateinit.initialized(1), Lateinit.initialized(1))
        XCTAssertNotEqual(Lateinit.initialized(1), Lateinit.initialized(2))
        XCTAssertNotEqual(Lateinit.initialized(1), Lateinit.uninitialized)
        XCTAssertEqual(Lateinit<Int>.uninitialized, Lateinit<Int>.uninitialized)
    }
}
