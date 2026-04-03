@testable import AppBundle
import Common
import XCTest

final class ArrayExTest: XCTestCase {
    func testSingleOrNil_noMatch() {
        let result = [1, 2, 3].singleOrNil(where: { $0 == 5 })
        assertNil(result)
    }

    func testSingleOrNil_oneMatch() {
        let result = [1, 2, 3].singleOrNil(where: { $0 == 2 })
        assertEquals(result, 2)
    }

    func testSingleOrNil_multipleMatches() {
        let result = [1, 2, 2, 3].singleOrNil(where: { $0 == 2 })
        assertNil(result)
    }

    func testSingleOrNil_emptyArray() {
        let result = [Int]().singleOrNil(where: { $0 == 1 })
        assertNil(result)
    }

    func testRemoveElement_existing() {
        var arr = [1, 2, 3]
        let index = arr.remove(element: 2)
        assertEquals(index, 1)
        assertEquals(arr, [1, 3])
    }

    func testRemoveElement_missing() {
        var arr = [1, 2, 3]
        let index = arr.remove(element: 5)
        assertNil(index)
        assertEquals(arr, [1, 2, 3])
    }

    func testRemoveElement_firstOccurrence() {
        var arr = [1, 2, 2, 3]
        let index = arr.remove(element: 2)
        assertEquals(index, 1)
        assertEquals(arr, [1, 2, 3])
    }

    func testSubtraction() {
        let result = [1, 2, 3, 4, 5] - [2, 4]
        assertEquals(result, [1, 3, 5])
    }

    func testSubtraction_noOverlap() {
        let result = [1, 2, 3] - [4, 5]
        assertEquals(result, [1, 2, 3])
    }

    func testSubtraction_emptyRhs() {
        let result = [1, 2, 3] - [Int]()
        assertEquals(result, [1, 2, 3])
    }

    func testSubtraction_emptyLhs() {
        let result = [Int]() - [1, 2]
        assertEquals(result, [])
    }
}
