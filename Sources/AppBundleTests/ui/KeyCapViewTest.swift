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
        assertEquals(keyCapAccessibilityLabel(key: PhysicalKey("_capslock", "\u{21EA}"), bindingInfo: .unbound), "Caps Lock key")
    }

    func testEveryModifierHasASpokenName() {
        let names = ["_capslock": "Caps Lock", "_lshift": "left Shift", "_rshift": "right Shift", "_fn": "Function", "_ctrl": "Control", "_option": "left Option", "_roption": "right Option", "_cmd": "left Command", "_rcmd": "right Command"]
        let modifiers = KeyboardLayout.qwerty.flatMap(\.keys).filter { $0.id.hasPrefix("_") }
        for key in modifiers {
            assertNotNil(names[key.id])
            assertEquals(keyCapAccessibilityLabel(key: key, bindingInfo: .unbound), "\(names[key.id]!) key")
        }
    }
}
