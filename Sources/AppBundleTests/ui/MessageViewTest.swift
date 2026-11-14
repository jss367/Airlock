@testable import AppBundle
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
}
