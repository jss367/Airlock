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

/// The modes of a config that sets `inherit-default-bindings = false`: only what the config lists.
/// - 'disabled' has no default to remove, so it is dropped like in a mode the defaults don't have.
/// - 'main' always exists, since it is the mode Airlock starts in. Without bindings it is empty.
func modesWithoutDefaults(userModes: [String: Mode]) -> [String: Mode] {
    var result = userModes.mapValues { $0.copy(\.bindings, $0.bindings.filter { !$0.value.isDisabled }) }
    if result[mainModeId] == nil { result[mainModeId] = .zero }
    return result
}

/// Merge user-defined modes on top of default modes.
/// - User bindings override default bindings for the same key.
/// - The 'disabled' sentinel removes the default binding. `[]` keeps the key bound to nothing.
/// - Modes only in defaults are preserved; modes only in user config are added.
func mergeModesWithDefaults(userModes: [String: Mode], defaultModes: [String: Mode]) -> [String: Mode] {
    var result = defaultModes
    for (modeName, userMode) in userModes {
        if let defaultMode = result[modeName] {
            var mergedBindings = defaultMode.bindings
            for (key, binding) in userMode.bindings {
                if binding.isDisabled {
                    // 'disabled' sentinel: remove the default binding
                    mergedBindings.removeValue(forKey: key)
                } else {
                    mergedBindings[key] = binding
                }
            }
            result[modeName] = Mode(bindings: mergedBindings)
        } else {
            // 'disabled' has nothing to remove here, and keeping it would register a hotkey that
            // swallows the keystroke and runs nothing. `[]` bindings stay: swallowing is their job
            result[modeName] = Mode(bindings: userMode.bindings.filter { !$0.value.isDisabled })
        }
    }
    return result
}
