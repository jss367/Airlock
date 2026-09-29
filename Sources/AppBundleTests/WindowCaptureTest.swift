@testable import AppBundle
import AppKit
import XCTest

final class WindowCaptureTest: XCTestCase {
    func testRetinaFullscreenCaptureIsBounded() {
        let size = windowThumbnailCaptureSize(
            contentSize: CGSize(width: 2560, height: 1440),
            pointPixelScale: 2,
        )
        XCTAssertEqual(size, CGSize(width: 700, height: 393))
    }

    func testPortraitCaptureIsAlsoBounded() {
        let size = windowThumbnailCaptureSize(
            contentSize: CGSize(width: 1440, height: 2560),
            pointPixelScale: 2,
        )
        XCTAssertEqual(size, CGSize(width: 393, height: 700))
    }

    func testSmallWindowsKeepNativeResolution() {
        let size = windowThumbnailCaptureSize(
            contentSize: CGSize(width: 200, height: 100),
            pointPixelScale: 2,
        )
        XCTAssertEqual(size, CGSize(width: 400, height: 200))
    }

    func testEmptyDimensionsStillProduceValidCaptureSize() {
        let size = windowThumbnailCaptureSize(contentSize: .zero, pointPixelScale: 2)
        XCTAssertEqual(size, CGSize(width: 1, height: 1))
    }
}
