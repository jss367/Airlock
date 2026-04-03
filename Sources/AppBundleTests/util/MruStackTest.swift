@testable import AppBundle
import Common
import XCTest

final class MruStackTest: XCTestCase {
    // MARK: - Initialization

    func testEmptyStack() {
        let stack = MruStack<Int>()
        assertNil(stack.mostRecent)
        assertEquals(stack.snapshot(), [])
    }

    // MARK: - pushOrRaise

    func testPushOrRaiseSingleElement() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        assertEquals(stack.mostRecent, 1)
        assertEquals(stack.snapshot(), [1])
    }

    func testPushOrRaiseMultipleElements() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        stack.pushOrRaise(2)
        stack.pushOrRaise(3)
        assertEquals(stack.mostRecent, 3)
        assertEquals(stack.snapshot(), [3, 2, 1])
    }

    func testPushOrRaiseDuplicateMovesToTop() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        stack.pushOrRaise(2)
        stack.pushOrRaise(3)
        stack.pushOrRaise(1) // raise existing element
        assertEquals(stack.mostRecent, 1)
        assertEquals(stack.snapshot(), [1, 3, 2])
    }

    func testPushOrRaiseDuplicateOnTopIsNoop() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        stack.pushOrRaise(2)
        stack.pushOrRaise(2) // already on top
        assertEquals(stack.snapshot(), [2, 1])
    }

    // MARK: - pushIfAbsent

    func testPushIfAbsentAddsToBottom() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        stack.pushOrRaise(2)
        stack.pushIfAbsent(3)
        assertEquals(stack.snapshot(), [2, 1, 3])
    }

    func testPushIfAbsentOnEmptyStack() {
        let stack = MruStack<Int>()
        stack.pushIfAbsent(1)
        assertEquals(stack.mostRecent, 1)
        assertEquals(stack.snapshot(), [1])
    }

    func testPushIfAbsentDoesNotMoveExisting() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        stack.pushOrRaise(2)
        stack.pushOrRaise(3)
        stack.pushIfAbsent(1) // already present, should not change order
        assertEquals(stack.snapshot(), [3, 2, 1])
    }

    func testPushIfAbsentDoesNotDuplicate() {
        let stack = MruStack<Int>()
        stack.pushIfAbsent(1)
        stack.pushIfAbsent(1)
        assertEquals(stack.snapshot(), [1])
    }

    // MARK: - remove

    func testRemoveExistingElement() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        stack.pushOrRaise(2)
        stack.pushOrRaise(3)
        let removed = stack.remove(2)
        assertTrue(removed)
        assertEquals(stack.snapshot(), [3, 1])
    }

    func testRemoveHead() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        stack.pushOrRaise(2)
        let removed = stack.remove(2)
        assertTrue(removed)
        assertEquals(stack.mostRecent, 1)
        assertEquals(stack.snapshot(), [1])
    }

    func testRemoveTail() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        stack.pushOrRaise(2)
        let removed = stack.remove(1)
        assertTrue(removed)
        assertEquals(stack.snapshot(), [2])
    }

    func testRemoveNonexistentReturnsFalse() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        let removed = stack.remove(99)
        assertEquals(removed, false)
        assertEquals(stack.snapshot(), [1])
    }

    func testRemoveFromEmptyStack() {
        let stack = MruStack<Int>()
        let removed = stack.remove(1)
        assertEquals(removed, false)
    }

    func testRemoveOnlyElement() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        let removed = stack.remove(1)
        assertTrue(removed)
        assertNil(stack.mostRecent)
        assertEquals(stack.snapshot(), [])
    }

    // MARK: - Iteration

    func testIterationOrder() {
        let stack = MruStack<String>()
        stack.pushOrRaise("a")
        stack.pushOrRaise("b")
        stack.pushOrRaise("c")
        var collected: [String] = []
        for item in stack {
            collected.append(item)
        }
        assertEquals(collected, ["c", "b", "a"])
    }

    func testIterationEmptyStack() {
        let stack = MruStack<Int>()
        var count = 0
        for _ in stack {
            count += 1
        }
        assertEquals(count, 0)
    }

    // MARK: - Sequence conformance

    func testContains() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        stack.pushOrRaise(2)
        assertTrue(stack.contains(1))
        assertTrue(stack.contains(2))
        assertEquals(stack.contains(3), false)
    }

    func testMap() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        stack.pushOrRaise(2)
        stack.pushOrRaise(3)
        let doubled = stack.map { $0 * 2 }
        assertEquals(doubled, [6, 4, 2])
    }

    // MARK: - restoreOrder

    func testRestoreOrderReordersElements() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        stack.pushOrRaise(2)
        stack.pushOrRaise(3)
        // Current order: [3, 2, 1]
        stack.restoreOrder(from: [1, 2, 3])
        assertEquals(stack.snapshot(), [1, 2, 3])
    }

    func testRestoreOrderSkipsMissingElements() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        stack.pushOrRaise(2)
        // Current order: [2, 1]
        stack.restoreOrder(from: [99, 1, 2]) // 99 not in stack, should be skipped
        assertEquals(stack.snapshot(), [1, 2])
    }

    func testRestoreOrderRetainsUnmentionedElements() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        stack.pushOrRaise(2)
        stack.pushOrRaise(3)
        // Current order: [3, 2, 1]
        // Only mention 1 in snapshot; 3 and 2 should stay in relative order below
        stack.restoreOrder(from: [1])
        assertEquals(stack.snapshot(), [1, 3, 2])
    }

    func testRestoreOrderEmptySnapshot() {
        let stack = MruStack<Int>()
        stack.pushOrRaise(1)
        stack.pushOrRaise(2)
        stack.restoreOrder(from: [])
        assertEquals(stack.snapshot(), [2, 1]) // unchanged
    }

    // MARK: - String type

    func testStringElements() {
        let stack = MruStack<String>()
        stack.pushOrRaise("hello")
        stack.pushOrRaise("world")
        assertEquals(stack.mostRecent, "world")
        stack.pushOrRaise("hello")
        assertEquals(stack.snapshot(), ["hello", "world"])
    }
}
