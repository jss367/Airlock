@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class WorkspacePreviewTest: XCTestCase {
    func testHiddenWorkspaceWindowsUseUnhiddenRects() throws {
        // Both windows are parked at the same corner point, as they are while their workspace is hidden
        let parked = ["X": CGFloat(3000), "Y": CGFloat(2000), "Width": CGFloat(800), "Height": CGFloat(600)]
        let windowInfoList: [[CFString: Any]] = [
            [kCGWindowNumber: NSNumber(value: 1), kCGWindowBounds: parked],
            [kCGWindowNumber: NSNumber(value: 2), kCGWindowBounds: parked],
            [kCGWindowNumber: NSNumber(value: 3), kCGWindowBounds: parked], // Not in this workspace
        ]
        let unhidden: [CGWindowID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 800, height: 600),
            2: CGRect(x: 800, y: 0, width: 800, height: 600),
        ]
        let layout = try XCTUnwrap(WorkspacePreviewView.previewLayout(
            windowInfoList: windowInfoList,
            windowIds: [1, 2],
            unhiddenRect: { wid, _ in unhidden[wid] },
        ))
        XCTAssertEqual(layout.captureRect, CGRect(x: 0, y: 0, width: 1600, height: 600))
        XCTAssertEqual(layout.windows.map(\.wid), [1, 2])
        XCTAssertEqual(layout.windows.map(\.rect), [unhidden[1]!, unhidden[2]!])
    }

    func testVisibleWorkspaceWindowsKeepReportedBounds() throws {
        let windowInfoList: [[CFString: Any]] = [
            [kCGWindowNumber: NSNumber(value: 1), kCGWindowBounds: ["X": CGFloat(10), "Y": CGFloat(20), "Width": CGFloat(100), "Height": CGFloat(50)]],
        ]
        let layout = try XCTUnwrap(WorkspacePreviewView.previewLayout(
            windowInfoList: windowInfoList,
            windowIds: [1],
            unhiddenRect: { _, _ in nil },
        ))
        XCTAssertEqual(layout.captureRect, CGRect(x: 10, y: 20, width: 100, height: 50))
    }

    func testNoMatchingWindowsGivesNoLayout() {
        XCTAssertNil(WorkspacePreviewView.previewLayout(windowInfoList: [], windowIds: [1], unhiddenRect: { _, _ in nil }))
    }
}
