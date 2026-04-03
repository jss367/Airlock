@testable import AppBundle
import Common
import XCTest

final class RectTest: XCTestCase {
    func testBasicProperties() {
        let rect = Rect(topLeftX: 10, topLeftY: 20, width: 100, height: 50)
        assertEquals(rect.topLeftX, 10)
        assertEquals(rect.topLeftY, 20)
        assertEquals(rect.width, 100)
        assertEquals(rect.height, 50)
    }

    func testMinMax() {
        let rect = Rect(topLeftX: 10, topLeftY: 20, width: 100, height: 50)
        assertEquals(rect.minX, 10)
        assertEquals(rect.maxX, 110)
        assertEquals(rect.minY, 20)
        assertEquals(rect.maxY, 70)
    }

    func testCenter() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 200, height: 100)
        assertEquals(rect.center, CGPoint(x: 100, y: 50))
    }

    func testCorners() {
        let rect = Rect(topLeftX: 10, topLeftY: 20, width: 100, height: 50)
        assertEquals(rect.topLeftCorner, CGPoint(x: 10, y: 20))
        assertEquals(rect.topRightCorner, CGPoint(x: 110, y: 20))
        assertEquals(rect.bottomRightCorner, CGPoint(x: 110, y: 70))
        assertEquals(rect.bottomLeftCorner, CGPoint(x: 10, y: 70))
    }

    func testSize() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 200)
        assertEquals(rect.size, CGSize(width: 300, height: 200))
    }

    func testContainsPoint() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 100)
        assertTrue(rect.contains(CGPoint(x: 50, y: 50)))
        assertTrue(!rect.contains(CGPoint(x: 150, y: 50)))
        assertTrue(!rect.contains(CGPoint(x: 50, y: 150)))
        assertTrue(!rect.contains(CGPoint(x: -1, y: 50)))
        assertTrue(!rect.contains(CGPoint(x: 50, y: -1)))
    }

    func testContainsEdge() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 100)
        // Edge points: minX/minY are inclusive, maxX/maxY are exclusive
        assertTrue(rect.contains(CGPoint(x: 0, y: 0)))
        assertTrue(!rect.contains(CGPoint(x: 100, y: 100)))
        assertTrue(!rect.contains(CGPoint(x: 100, y: 0)))
        assertTrue(!rect.contains(CGPoint(x: 0, y: 100)))
    }

    func testNegativeWidthHeightClampedToZero() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: -10, height: -20)
        assertEquals(rect.width, 0)
        assertEquals(rect.height, 0)
    }

    func testZeroSizeRect() {
        let rect = Rect(topLeftX: 5, topLeftY: 5, width: 0, height: 0)
        assertEquals(rect.center, CGPoint(x: 5, y: 5))
        assertEquals(rect.size, CGSize(width: 0, height: 0))
        assertTrue(!rect.contains(CGPoint(x: 5, y: 5)))
    }

    func testGetDimension() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 200)
        assertEquals(rect.getDimension(.h), 300)
        assertEquals(rect.getDimension(.v), 200)
    }
}
