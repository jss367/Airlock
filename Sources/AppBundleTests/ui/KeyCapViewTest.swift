@testable import AppBundle
import XCTest

final class KeyCapViewTest: XCTestCase {
    func testAccessibilityLabelNamesTheKeyAndItsBinding() {
        let semicolon = PhysicalKey("semicolon", ";")
        assertEquals(
            keyCapAccessibilityLabel(key: semicolon, bindingInfo: .appLauncher(appName: "Safari", appPath: "/Applications/Safari.app")),
            "semicolon, opens Safari",
        )
        assertEquals(
            keyCapAccessibilityLabel(key: semicolon, bindingInfo: .otherCommand(description: "focus left")),
            "semicolon, runs focus left",
        )
        assertEquals(keyCapAccessibilityLabel(key: semicolon, bindingInfo: .unbound), "semicolon, unbound")
        // Modifier keys can't be bound
        assertEquals(keyCapAccessibilityLabel(key: PhysicalKey("_capslock", "\u{21EA}"), bindingInfo: .unbound), "capslock key")
    }
}
