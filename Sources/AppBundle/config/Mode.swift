import Common
import HotKey
import TOMLKit

struct Mode: ConvenienceCopyable, Equatable, Sendable {
    var bindings: [String: HotkeyBinding]

    static let zero = Mode(bindings: [:])
}

func parseModes(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace, _ errors: inout [TomlParseError], _ mapping: [String: Key]) -> [String: Mode] {
    guard let rawTable = raw.table else {
        errors += [expectedActualTypeError(expected: .table, actual: raw.type, backtrace)]
        return [:]
    }
    var result: [String: Mode] = [:]
    for (key, value) in rawTable {
        result[key] = parseMode(value, backtrace + .key(key), &errors, mapping)
    }
    return result
}

func parseMode(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace, _ errors: inout [TomlParseError], _ mapping: [String: Key]) -> Mode {
    guard let rawTable: TOMLTable = raw.table else {
        errors += [expectedActualTypeError(expected: .table, actual: raw.type, backtrace)]
        return .zero
    }

    var result: Mode = .zero
    for (key, value) in rawTable {
        let backtrace = backtrace + .key(key)
        switch key {
            case "binding":
                result.bindings = parseBindings(value, backtrace, &errors, mapping)
            default:
                errors += [unknownKeyError(backtrace)]
        }
    }
    return result
}

/// Merge user-defined modes on top of default modes.
/// - User bindings override default bindings for the same key.
/// - Bindings with empty commands ('disabled' sentinel) remove the default binding.
/// - Modes only in defaults are preserved; modes only in user config are added.
func mergeModesWithDefaults(userModes: [String: Mode], defaultModes: [String: Mode]) -> [String: Mode] {
    var result = defaultModes
    for (modeName, userMode) in userModes {
        if let defaultMode = result[modeName] {
            var mergedBindings = defaultMode.bindings
            for (key, binding) in userMode.bindings {
                if binding.commands.isEmpty {
                    // 'disabled' sentinel: remove the default binding
                    mergedBindings.removeValue(forKey: key)
                } else {
                    mergedBindings[key] = binding
                }
            }
            result[modeName] = Mode(bindings: mergedBindings)
        } else {
            result[modeName] = userMode
        }
    }
    return result
}
