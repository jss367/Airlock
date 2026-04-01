import Foundation
import HotKey

struct PhysicalKey: Identifiable, Hashable {
    let id: String // key notation string (e.g. "q", "semicolon", "backtick")
    let displayLabel: String // what to show on the keycap (e.g. "Q", ";", "`")
    let widthMultiplier: CGFloat // 1.0 = standard key width

    init(_ notation: String, _ label: String, width: CGFloat = 1.0) {
        self.id = notation
        self.displayLabel = label
        self.widthMultiplier = width
    }
}

struct KeyboardRow: Identifiable {
    let id: Int
    let keys: [PhysicalKey]
}

enum KeyboardLayout {
    static let qwerty: [KeyboardRow] = [
        // Number row
        KeyboardRow(id: 0, keys: [
            PhysicalKey("backtick", "`"),
            PhysicalKey("1", "1"),
            PhysicalKey("2", "2"),
            PhysicalKey("3", "3"),
            PhysicalKey("4", "4"),
            PhysicalKey("5", "5"),
            PhysicalKey("6", "6"),
            PhysicalKey("7", "7"),
            PhysicalKey("8", "8"),
            PhysicalKey("9", "9"),
            PhysicalKey("0", "0"),
            PhysicalKey("minus", "-"),
            PhysicalKey("equal", "="),
            PhysicalKey("backspace", "\u{232B}", width: 1.5),
        ]),
        // QWERTY row
        KeyboardRow(id: 1, keys: [
            PhysicalKey("tab", "\u{21E5}", width: 1.5),
            PhysicalKey("q", "Q"),
            PhysicalKey("w", "W"),
            PhysicalKey("e", "E"),
            PhysicalKey("r", "R"),
            PhysicalKey("t", "T"),
            PhysicalKey("y", "Y"),
            PhysicalKey("u", "U"),
            PhysicalKey("i", "I"),
            PhysicalKey("o", "O"),
            PhysicalKey("p", "P"),
            PhysicalKey("leftSquareBracket", "["),
            PhysicalKey("rightSquareBracket", "]"),
            PhysicalKey("backslash", "\\"),
        ]),
        // Home row
        KeyboardRow(id: 2, keys: [
            PhysicalKey("_capslock", "\u{21EA}", width: 1.75),
            PhysicalKey("a", "A"),
            PhysicalKey("s", "S"),
            PhysicalKey("d", "D"),
            PhysicalKey("f", "F"),
            PhysicalKey("g", "G"),
            PhysicalKey("h", "H"),
            PhysicalKey("j", "J"),
            PhysicalKey("k", "K"),
            PhysicalKey("l", "L"),
            PhysicalKey("semicolon", ";"),
            PhysicalKey("quote", "'"),
            PhysicalKey("enter", "\u{21A9}", width: 1.75),
        ]),
        // Bottom row
        KeyboardRow(id: 3, keys: [
            PhysicalKey("_lshift", "\u{21E7}", width: 2.25),
            PhysicalKey("z", "Z"),
            PhysicalKey("x", "X"),
            PhysicalKey("c", "C"),
            PhysicalKey("v", "V"),
            PhysicalKey("b", "B"),
            PhysicalKey("n", "N"),
            PhysicalKey("m", "M"),
            PhysicalKey("comma", ","),
            PhysicalKey("period", "."),
            PhysicalKey("slash", "/"),
            PhysicalKey("_rshift", "\u{21E7}", width: 2.25),
        ]),
        // Space row
        KeyboardRow(id: 4, keys: [
            PhysicalKey("_fn", "fn", width: 1.0),
            PhysicalKey("_ctrl", "\u{2303}", width: 1.25),
            PhysicalKey("_option", "\u{2325}", width: 1.25),
            PhysicalKey("_cmd", "\u{2318}", width: 1.25),
            PhysicalKey("space", "Space", width: 5.0),
            PhysicalKey("_rcmd", "\u{2318}", width: 1.25),
            PhysicalKey("_roption", "\u{2325}", width: 1.25),
            PhysicalKey("left", "\u{2190}"),
            PhysicalKey("up", "\u{2191}"),
            PhysicalKey("down", "\u{2193}"),
            PhysicalKey("right", "\u{2192}"),
        ]),
    ]

    /// Keys that are bindable (have entries in keyNotationToKeyCode).
    /// Modifier-only keys (prefixed with _) are excluded.
    static let bindableKeyNotations: Set<String> = {
        Set(qwerty.flatMap(\.keys).map(\.id).filter { !$0.hasPrefix("_") })
    }()
}
