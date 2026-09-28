import Foundation

/// Rewrites the config text so references to workspace `old` name `new` instead. Covers:
/// - entries of `persistent-workspaces` and the `workspace` matcher of `[[on-window-detected]]`
/// - keys of `[workspaces.names]` and `[workspace-to-monitor-force-assignment]` (their values are
///   keys and monitor patterns, so they stay as they are)
/// - the workspace argument of `workspace`, `move-node-to-workspace` and `summon-workspace`, and the
///   value of `--workspace`, in fields that hold commands (bindings, callbacks, `run`)
///
/// Other strings are left alone, even when they look like commands. So are multi-line strings,
/// strings with escapes, and inline or dotted forms of the tables above. `configStillReferences`
/// catches a reference this missed
func renameWorkspaceInConfig(_ text: String, from old: String, to new: String) -> String {
    var table = ""
    var key = ""
    var arrayDepth = 0
    var openMultiLineString: String? = nil
    let lines = text.components(separatedBy: "\n").map { line -> String in
        if let delimiter = openMultiLineString {
            // The rest of a line that closes a multi-line string is left alone too
            if line.contains(delimiter) { openMultiLineString = nil }
            return line
        }
        if arrayDepth <= 0, let header = tomlTableHeader(line) {
            table = header
            return line
        }
        var tokens = tomlLineTokens(line)[...]
        var replacements: [(Range<String.Index>, String)] = []
        // A line inside an open array continues the previous line's value
        if arrayDepth <= 0, let first = tokens.first, tokens.dropFirst().first?.kind == .equals {
            key = String(line[first.content])
            arrayDepth = 0
            if (first.kind == .bare || first.kind == .string) && key == old && workspaceNameKeyTables.contains(table) {
                replacements.append((first.whole, first.kind == .bare ? tomlKey(new) : "\"\(new)\""))
            }
            tokens = tokens.dropFirst(2)
        }
        let field = tomlField(table: table, key: key)
        for token in tokens {
            switch token.kind {
                case .openMultiLine(let delimiter):
                    openMultiLineString = delimiter
                case .bracket(let delta):
                    arrayDepth += delta
                case .string where !token.hasEscapes:
                    let content = String(line[token.content])
                    switch field {
                        case .workspaceName:
                            if content == old { replacements.append((token.content, new)) }
                        case .commands:
                            let renamed = renameWorkspaceInCommand(content, from: old, to: new)
                            if renamed != content { replacements.append((token.content, renamed)) }
                        case .other:
                            break
                    }
                case .string, .bare, .equals:
                    break
            }
        }
        var result = line
        // Apply replacements from the end so earlier ranges stay valid
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
    return lines.joined(separator: "\n")
}

/// Whether the parsed config still names workspace `name` somewhere a rename must reach. Parse
/// without defaults: the default bindings aren't in the file, so no rename could change them
func configStillReferences(_ config: Config, workspace name: String) -> Bool {
    let commands = config.modes.values.flatMap { $0.bindings.values.flatMap(\.commands) } +
        config.afterStartupCommand + config.onFocusChanged + config.onFocusedMonitorChanged + config.onModeChanged +
        config.onWindowDetected.flatMap { $0.rawRun ?? [] }
    return config.persistentWorkspaces.contains(name) ||
        config.workspaceToMonitorForceAssignment[name] != nil ||
        config.onWindowDetected.contains { $0.matcher.workspace == name } ||
        commands.contains { command in
            let description = command.args.description
            return renameWorkspaceInCommand(description, from: name, to: "_") != description
        }
}

private let workspaceNameKeyTables: Set<String> = ["workspaces.names", "workspace-to-monitor-force-assignment"]
private let rootCommandKeys: Set<String> = ["after-startup-command", "on-focus-changed", "on-mode-changed", "on-focused-monitor-changed"]

private enum TomlField { case workspaceName, commands, other }

private func tomlField(table: String, key: String) -> TomlField {
    switch true {
        case table.isEmpty && key == "persistent-workspaces": .workspaceName
        case table == "on-window-detected" && key == "if.workspace": .workspaceName
        case table == "on-window-detected.if" && key == "workspace": .workspaceName
        case table.isEmpty && rootCommandKeys.contains(key): .commands
        case table == "on-window-detected" && key == "run": .commands
        case table.hasPrefix("mode.") && table.hasSuffix(".binding"): .commands
        default: .other
    }
}

private let workspaceArgCommands: Set<String> = ["workspace", "move-node-to-workspace", "summon-workspace"]
private let flagsWithValue: Set<String> = ["--window-id", "--workspace"]
let commandSeparators: Set<String> = ["&&", "||", ";"]

/// Renames the workspace in one command string, which can hold a whole sequence (`a && b; c`)
func renameWorkspaceInCommand(_ command: String, from old: String, to new: String) -> String {
    var words: [Range<String.Index>] = []
    var index = command.startIndex
    while index < command.endIndex {
        if command[index].isWhitespace {
            index = command.index(after: index)
            continue
        }
        let start = index
        while index < command.endIndex && !command[index].isWhitespace {
            index = command.index(after: index)
        }
        words.append(start ..< index)
    }

    var replacements: [Range<String.Index>] = []
    var isWorkspaceCommand = false
    var isAtCommandStart = true
    var i = 0
    while i < words.count {
        let word = String(command[words[i]])
        if commandSeparators.contains(word) {
            isAtCommandStart = true
            isWorkspaceCommand = false
        } else if isAtCommandStart {
            isAtCommandStart = false
            isWorkspaceCommand = workspaceArgCommands.contains(word)
        } else if word == "--workspace" {
            // `list-windows --workspace` takes every word up to the next flag, each a comma separated list
            while i + 1 < words.count, !command[words[i + 1]].hasPrefix("-"), !commandSeparators.contains(String(command[words[i + 1]])) {
                replacements += commaSeparatedMatches(command, words[i + 1], old)
                i += 1
            }
        } else if flagsWithValue.contains(word) {
            i += 1
        } else if word.hasPrefix("-") {
            // A flag without a value
        } else if isWorkspaceCommand {
            if word == old { replacements.append(words[i]) }
            isWorkspaceCommand = false
        }
        i += 1
    }

    var result = command
    for range in replacements.reversed() {
        result.replaceSubrange(range, with: new)
    }
    return result
}

private func commaSeparatedMatches(_ text: String, _ range: Range<String.Index>, _ name: String) -> [Range<String.Index>] {
    var matches: [Range<String.Index>] = []
    var start = range.lowerBound
    for index in text[range].indices + [range.upperBound] where index == range.upperBound || text[index] == "," {
        if text[start ..< index] == name { matches.append(start ..< index) }
        if index < range.upperBound { start = text.index(after: index) }
    }
    return matches
}

/// `name` as a TOML key, quoted unless it's a valid bare key
private func tomlKey(_ name: String) -> String {
    let bare = name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    return bare ? name : "\"\(name)\""
}

private struct TomlToken {
    enum Kind: Equatable {
        case bare, string, equals, bracket(Int), openMultiLine(String)
    }
    let kind: Kind
    /// The whole token, quotes included
    let whole: Range<String.Index>
    /// The token without its quotes
    let content: Range<String.Index>
    var hasEscapes = false
}

/// Splits one line into bare words, single-line strings, `=`, and brackets, up to a comment.
/// A multi-line string that opens here is reported as `openMultiLine` when it doesn't close on the same line
private func tomlLineTokens(_ line: String) -> [TomlToken] {
    var tokens: [TomlToken] = []
    var index = line.startIndex
    func isBareChar(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "-" || char == "_" || char == "."
    }
    while index < line.endIndex {
        let char = line[index]
        if char == "#" { break }
        if char == "\"" || char == "'" {
            let triple = String(repeating: char, count: 3)
            if line[index...].hasPrefix(triple) {
                let afterOpen = line.index(index, offsetBy: 3)
                guard let close = line[afterOpen...].range(of: triple) else {
                    tokens.append(TomlToken(kind: .openMultiLine(triple), whole: index ..< line.endIndex, content: afterOpen ..< line.endIndex))
                    break
                }
                index = close.upperBound // A multi-line string on one line is never rewritten
                continue
            }
            let contentStart = line.index(after: index)
            var end = contentStart
            var hasEscapes = false
            while end < line.endIndex && line[end] != char {
                if char == "\"" && line[end] == "\\" {
                    hasEscapes = true
                    end = line.index(after: end)
                    if end == line.endIndex { break }
                }
                end = line.index(after: end)
            }
            let whole = index ..< (end < line.endIndex ? line.index(after: end) : end)
            tokens.append(TomlToken(kind: .string, whole: whole, content: contentStart ..< end, hasEscapes: hasEscapes))
            index = whole.upperBound
        } else if char == "=" {
            tokens.append(TomlToken(kind: .equals, whole: index ..< line.index(after: index), content: index ..< line.index(after: index)))
            index = line.index(after: index)
        } else if char == "[" || char == "]" {
            tokens.append(TomlToken(kind: .bracket(char == "[" ? 1 : -1), whole: index ..< line.index(after: index), content: index ..< line.index(after: index)))
            index = line.index(after: index)
        } else if isBareChar(char) {
            let start = index
            while index < line.endIndex && isBareChar(line[index]) {
                index = line.index(after: index)
            }
            tokens.append(TomlToken(kind: .bare, whole: start ..< index, content: start ..< index))
        } else {
            index = line.index(after: index)
        }
    }
    return tokens
}
