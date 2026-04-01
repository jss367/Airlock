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

    return .otherCommand(description: execArgs.bashScript)
}

private let openAppRegex = try! NSRegularExpression(
    pattern: #"^open\s+-a\s+"([^"]+)"|^open\s+-a\s+(\S+)"#,
    options: []
)

private func extractAppName(from script: String) -> String? {
    let range = NSRange(script.startIndex..., in: script)
    guard let match = openAppRegex.firstMatch(in: script, range: range) else { return nil }

    // Group 1: quoted name, Group 2: unquoted name
    for groupIdx in 1...2 {
        let groupRange = match.range(at: groupIdx)
        if groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: script) {
            return String(script[swiftRange])
        }
    }
    return nil
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
