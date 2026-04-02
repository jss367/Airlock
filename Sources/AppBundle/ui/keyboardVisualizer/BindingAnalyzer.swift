import AppKit
import Common
import HotKey

enum KeyBindingInfo {
    case appLauncher(appName: String, appPath: String)
    case otherCommand(description: String)
    case unbound
}

@MainActor
func analyzeBindings(modifierPrefix: NSEvent.ModifierFlags) -> [String: KeyBindingInfo] {
    var result: [String: KeyBindingInfo] = [:]

    guard let mainMode = config.modes[mainModeId] else { return result }

    for (_, binding) in mainMode.bindings {
        guard binding.modifiers == modifierPrefix else { continue }

        let keyNotation = binding.keyCode.toString()
        let info = classifyBinding(binding)
        result[keyNotation] = info
    }

    return result
}

private func classifyBinding(_ binding: HotkeyBinding) -> KeyBindingInfo {
    guard binding.commands.count == 1,
          let cmd = binding.commands.first,
          let execArgs = cmd.args as? ExecAndForgetCmdArgs else {
        let desc = binding.commands.map { $0.args.description }.joined(separator: ", ")
        return .otherCommand(description: desc)
    }

    let script = execArgs.bashScript.trimmingCharacters(in: .whitespacesAndNewlines)
    if let appName = extractAppName(from: script) {
        let appPath = findAppPath(named: appName) ?? ""
        return .appLauncher(appName: appName, appPath: appPath)
    }

    if let osascriptResult = extractOsascriptDescription(from: script) {
        switch osascriptResult {
        case .launcher(let appName):
            let appPath = findAppPath(named: appName) ?? ""
            return .appLauncher(appName: appName, appPath: appPath)
        case .keystroke(let description):
            return .otherCommand(description: description)
        }
    }

    return .otherCommand(description: execArgs.bashScript)
}

private let openAppRegex = try! NSRegularExpression(
    pattern: #"^open\s+-a\s+"([^"]+)"|^open\s+-a\s+'([^']+)'|^open\s+-a\s+(\S+)"#,
    options: []
)

private func extractAppName(from script: String) -> String? {
    let range = NSRange(script.startIndex..., in: script)
    guard let match = openAppRegex.firstMatch(in: script, range: range) else { return nil }

    // Group 1: double-quoted name, Group 2: single-quoted name, Group 3: unquoted name
    for groupIdx in 1...3 {
        let groupRange = match.range(at: groupIdx)
        if groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: script) {
            var name = String(script[swiftRange])
            // Strip .app suffix if present so findAppPath doesn't produce ".app.app"
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            return name
        }
    }
    return nil
}

private enum OsascriptResult {
    case launcher(appName: String)
    case keystroke(description: String)
}

private let osascriptAppRegex = try! NSRegularExpression(
    pattern: #"tell application "([^"]+)" to activate"#,
    options: []
)

private let osascriptKeystrokeRegex = try! NSRegularExpression(
    pattern: #"keystroke "([^"]+)"(?:\s+using\s+\{([^}]+)\})?"#,
    options: []
)

private func extractOsascriptDescription(from script: String) -> OsascriptResult? {
    // Only handle osascript commands (support both bare and absolute-path invocations)
    let isOsascript = script.hasPrefix("osascript ") || script.range(of: #"^/.*/osascript\s"#, options: .regularExpression) != nil
    guard isOsascript else { return nil }

    let range = NSRange(script.startIndex..., in: script)

    // Extract the target app name
    guard let appMatch = osascriptAppRegex.firstMatch(in: script, range: range),
          let appRange = Range(appMatch.range(at: 1), in: script) else {
        return nil
    }
    let appName = String(script[appRange])

    // Check for keystroke
    guard let keystrokeMatch = osascriptKeystrokeRegex.firstMatch(in: script, range: range),
          let keyRange = Range(keystrokeMatch.range(at: 1), in: script) else {
        // No keystroke — just an app activation
        return .launcher(appName: appName)
    }

    let key = String(script[keyRange]).uppercased()

    // Parse modifiers if present
    var modifierSymbols = ""
    let modifiersGroupRange = keystrokeMatch.range(at: 2)
    if modifiersGroupRange.location != NSNotFound, let modRange = Range(modifiersGroupRange, in: script) {
        let modifierMap: [(String, String)] = [
            ("control down", "⌃"),
            ("option down", "⌥"),
            ("shift down", "⇧"),
            ("command down", "⌘"),
        ]
        let modString = String(script[modRange])
        // Build in standard macOS order: ⌃⌥⇧⌘
        for (name, symbol) in modifierMap {
            if modString.contains(name) {
                modifierSymbols += symbol
            }
        }
    }

    return .keystroke(description: "\(appName): \(modifierSymbols)\(key)")
}

private func findAppPath(named appName: String) -> String? {
    let searchDirs = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        NSHomeDirectory() + "/Applications",
    ]
    for dir in searchDirs {
        let path = "\(dir)/\(appName).app"
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }
    // Also try case-insensitive matching
    for dir in searchDirs {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
        for item in contents where item.hasSuffix(".app") {
            let name = String(item.dropLast(4))
            if name.lowercased() == appName.lowercased() {
                return "\(dir)/\(item)"
            }
        }
    }
    return nil
}

func resolveAppIcon(appPath: String) -> NSImage? {
    guard !appPath.isEmpty else { return nil }
    return NSWorkspace.shared.icon(forFile: appPath)
}

/// The hyper key modifier combination (option+ctrl+cmd+shift)
let hyperModifiers: NSEvent.ModifierFlags = [.option, .control, .command, .shift]
