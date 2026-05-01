import Common
import TOMLKit

struct FocusFlashSettings: ConvenienceCopyable, Equatable, Sendable {
    var enabled: Bool = true
    var mode: FocusFlashMode = .crossWorkspace
    var idleThresholdSeconds: Int = 10
    var color: String = "0xff00ff00"
    var width: Double = 6.0
    var popDistance: Double = 10.0
    var durationMs: Int = 400

    static let `default` = FocusFlashSettings()
}

private let focusFlashParser: [String: any ParserProtocol<FocusFlashSettings>] = [
    "enabled": Parser(\.enabled, parseBool),
    "mode": Parser(\.mode, parseFocusFlashMode),
    "idle-threshold-seconds": Parser(\.idleThresholdSeconds, parseInt),
    "color": Parser(\.color, parseFocusFlashColor),
    "width": Parser(\.width, parseFocusFlashDouble),
    "pop-distance": Parser(\.popDistance, parseFocusFlashDouble),
    "duration-ms": Parser(\.durationMs, parseInt),
]

func parseFocusFlash(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace, _ errors: inout [TomlParseError]) -> FocusFlashSettings {
    parseTable(raw, .default, focusFlashParser, backtrace, &errors)
}

private func parseFocusFlashMode(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace) -> ParsedToml<FocusFlashMode> {
    parseString(raw, backtrace).flatMap { str in
        if let mode = FocusFlashMode(rawValue: str) {
            return .success(mode)
        }
        let valid = FocusFlashMode.allCases.map(\.rawValue).joined(separator: ", ")
        return .failure(.semantic(backtrace, "mode: '\(str)' is not a valid mode. Valid: \(valid)"))
    }
}

private func parseFocusFlashColor(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace) -> ParsedToml<String> {
    parseString(raw, backtrace).flatMap { str in
        // Accept "0x" + 8 hex chars (AARRGGBB).
        let pattern = #"^0[xX][0-9a-fA-F]{8}$"#
        if str.range(of: pattern, options: .regularExpression) != nil {
            return .success(str)
        }
        return .failure(.semantic(backtrace, "color: '\(str)' must be of form 0xAARRGGBB"))
    }
}

private func parseFocusFlashDouble(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace) -> ParsedToml<Double> {
    if let d = raw.double {
        return .success(d)
    }
    if let i = raw.int {
        return .success(Double(i))
    }
    return .failure(expectedActualTypeError(expected: .double, actual: raw.type, backtrace))
}
