@testable import AppBundle
import AppKit

final class TestWindow: Window, CustomStringConvertible {
    var _rect: Rect?

    @MainActor
    private init(_ id: UInt32, _ parent: NonLeafTreeNodeObject, _ adaptiveWeight: CGFloat, _ rect: Rect?) {
        _rect = rect
        super.init(id: id, TestApp.shared, lastFloatingSize: rect.map { CGSize(width: $0.width, height: $0.height) }, parent: parent, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
    }

    @discardableResult
    @MainActor
    static func new(id: UInt32, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat = 1, rect: Rect? = nil) -> TestWindow {
        let wi = TestWindow(id, parent, adaptiveWeight, rect)
        TestApp.shared._windows.append(wi)
        return wi
    }

    nonisolated var description: String { "TestWindow(\(windowId))" }

    @MainActor
    override func nativeFocus() {
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = self
    }

    override func closeAxWindow() {
        unbindFromParent()
    }

    override var title: String {
        get async { // redundant async. todo create bug report to Swift
            description
        }
    }

    @MainActor override func getAxRect() async throws -> Rect? { // todo change to not Optional
        _rect
    }

    override func getAxSize() async throws -> CGSize? {
        _rect.map { CGSize(width: $0.width, height: $0.height) }
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        if let topLeft, let size {
            _rect = Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: size.width, height: size.height)
        } else if let topLeft {
            _rect = Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: _rect?.width ?? 0, height: _rect?.height ?? 0)
        } else if let size {
            _rect = Rect(topLeftX: _rect?.topLeftX ?? 0, topLeftY: _rect?.topLeftY ?? 0, width: size.width, height: size.height)
        }
    }

    override var isHiddenInCorner: Bool { false }
}
