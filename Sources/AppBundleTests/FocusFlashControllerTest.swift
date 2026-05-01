@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class FocusFlashControllerTest: XCTestCase {
    func testParseAARRGGBB_validFullOpacityGreen() {
        let c = parseAARRGGBB("0xff00ff00")
        XCTAssertNotNil(c)
        let srgb = c!.usingColorSpace(NSColorSpace.sRGB)!
        assertEquals(srgb.alphaComponent, 1.0)
        assertEquals(srgb.redComponent, 0.0)
        assertEquals(srgb.greenComponent, 1.0)
        assertEquals(srgb.blueComponent, 0.0)
    }

    func testParseAARRGGBB_validHalfTransparentRed() {
        let c = parseAARRGGBB("0x80ff0000")
        XCTAssertNotNil(c)
        let srgb = c!.usingColorSpace(NSColorSpace.sRGB)!
        XCTAssertEqual(srgb.alphaComponent, 128.0 / 255.0, accuracy: 0.001)
        assertEquals(srgb.redComponent, 1.0)
    }

    func testParseAARRGGBB_rejectsShortString() {
        XCTAssertNil(parseAARRGGBB("0xff00"))
    }

    func testParseAARRGGBB_rejectsNonHex() {
        XCTAssertNil(parseAARRGGBB("0xggggggg0"))
    }

    func testParseAARRGGBB_acceptsCapitalX() {
        XCTAssertNotNil(parseAARRGGBB("0Xff000000"))
    }
}
