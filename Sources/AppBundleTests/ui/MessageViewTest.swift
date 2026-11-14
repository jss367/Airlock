@testable import AppBundle
import AppKit
import XCTest

final class MessageViewTest: XCTestCase {
    func testEachMessageTypeHasItsOwnIcon() {
        let types: [MessageType] = [.config, .runtime, .notice]
        assertEquals(Set(types.map(\.symbolName)).count, types.count)
        assertEquals(Set(types.map(\.accessibilityLabel)).count, types.count)
        // Only a notice, which reports nothing broken, goes without a warning or error symbol
        assertEquals(MessageType.notice.symbolName, "info.circle.fill")
    }

    func testOnlyConfigMessagesOfferConfigButtons() {
        assertEquals(MessageType.config.showsConfigButtons, true)
        assertEquals(MessageType.runtime.showsConfigButtons, false)
        assertEquals(MessageType.notice.showsConfigButtons, false)
        // Call sites that don't name a type report config errors
        assertEquals(Message(description: "Airlock Config Error", body: "").type, .config)
    }

    @MainActor
    func testReturnClosesAfterSelectingTextAndStopsWhenWindowCloses() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = try XCTUnwrap(window.contentView)
        let monitor = MessageCloseKeyView()
        content.addSubview(monitor)
        let text = NSTextView(frame: content.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.string = "Selectable multiline\nmessage body"
        content.addSubview(text)
        XCTAssertTrue(window.makeFirstResponder(text))
        text.setSelectedRange(NSRange(location: 0, length: 10))
        var closes = 0
        monitor.onClose = { closes += 1 }
        func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], in target: NSWindow? = nil) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: (target ?? window).windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(monitor.handle(try key(36)))
        XCTAssertTrue(monitor.handle(try key(76)))
        XCTAssertEqual(closes, 2)
        XCTAssertFalse(monitor.handle(try key(36, .command)))
        XCTAssertFalse(monitor.handle(try key(8, .command))) // Copy must keep working.
        let otherWindow = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        XCTAssertFalse(monitor.handle(try key(36, in: otherWindow)))
        let returnEvent = try key(36)
        window.close()
        XCTAssertFalse(monitor.handle(returnEvent))
        XCTAssertEqual(closes, 2)
    }
}
