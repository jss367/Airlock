@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class AboutWindowTest: XCTestCase {
    func testContentFitsAndClosingKeepsTheReusableWindow() throws {
        _ = NSApplication.shared
        let controller = AboutWindowController.shared
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible) // No test orders the window onscreen or activates Airlock.
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.width, content.fittingSize.width)
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.height, content.fittingSize.height)
        for _ in 0 ..< 3 {
            controller.close()
            XCTAssertTrue(controller.window === window)
            XCTAssertTrue(controller.window?.contentView === content)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testCmdWClosesAboutWithCapsLockOnOrOff() throws {
        for (flags, characters): (NSEvent.ModifierFlags, String) in [
            (.command, "w"), ([.command, .capsLock], "w"), ([.command, .capsLock], "W"),
        ] {
            let result = try closeShortcut(flags: flags, characters: characters)
            XCTAssertTrue(result.handled)
            XCTAssertEqual(result.closes, 1)
        }
    }

    func testOtherKeysAndMeaningfulExtraModifiersDoNotCloseAbout() throws {
        for flags: NSEvent.ModifierFlags in [
            [], .capsLock, [.command, .shift], [.command, .option], [.command, .control],
            [.command, .capsLock, .shift], [.command, .function],
        ] {
            XCTAssertEqual(try closeShortcut(flags: flags, characters: "w").closes, 0)
        }
        XCTAssertEqual(try closeShortcut(flags: .command, characters: "q").closes, 0)
    }

    private func closeShortcut(flags: NSEvent.ModifierFlags, characters: String) throws -> (handled: Bool, closes: Int) {
        _ = NSApplication.shared
        let window = AboutWindowController.makeWindow()
        defer { window.close() }
        var closes = 0
        let observation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { closes += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 13))
        return (window.performKeyEquivalent(with: event), closes)
    }
}
