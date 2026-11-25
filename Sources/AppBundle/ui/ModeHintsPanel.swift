import AppKit
import Common
import SwiftUI

// MARK: - Model

/// What the mode hints panel shows: the keys of the active binding mode and what each one does.
struct ModeHints: Equatable {
    let mode: String
    let oneShot: Bool
    let rows: [Shortcut]
}

let modeHintsLeaveAction = "back to main"

/// The hints for `mode`, or nil when it has no bindings to show. `bindings` are the registered ones.
/// - A trailing `mode main` is dropped from a row: every such key leaves the mode, and the row is
///   for what the key does first. In a one-shot mode it would be redundant on every row.
/// - Keys that only leave the mode come last.
/// - A key bound to `[]` has no row: it is there to do nothing.
func modeHints(mode: String, bindings: [HotkeyBinding], oneShot: Bool) -> ModeHints? {
    var actions: [HotkeyBinding] = []
    var leaving: [HotkeyBinding] = []
    for binding in bindings where !binding.commands.isEmpty {
        var commands = binding.commands
        while let last = commands.last as? ModeCommand, last.args.targetMode.val == mainModeId { commands.removeLast() }
        if commands.isEmpty {
            leaving.append(binding)
        } else {
            actions.append(HotkeyBinding(binding.modifiers, binding.keyCode, commands, descriptionWithKeyNotation: binding.descriptionWithKeyNotation))
        }
    }
    let rows = keybindingShortcuts(actions).map { Shortcut(tokens: $0.tokens, action: modeHintsActionText($0.action), searchText: "") }
    return rows.isEmpty && leaving.isEmpty ? nil : ModeHints(mode: mode, oneShot: oneShot, rows: rows + modeHintsLeaveRows(leaving))
}

/// Keys without modifiers share one row ("↩ ⎋ back to main"): they are alternatives, and a row each
/// would spend the panel on the least interesting keys. A chord keeps its own row, since its key caps
/// side by side with another key's would read as one longer chord.
private func modeHintsLeaveRows(_ leaving: [HotkeyBinding]) -> [Shortcut] {
    let sorted = leaving.sorted { $0.descriptionWithKeyNotation < $1.descriptionWithKeyNotation }
    let plain = sorted.filter(\.modifiers.isEmpty).flatMap { keyTokens(fromNotation: $0.descriptionWithKeyNotation) }
    let tokenRows = (plain.isEmpty ? [] : [plain]) + sorted.filter { !$0.modifiers.isEmpty }.map { keyTokens(fromNotation: $0.descriptionWithKeyNotation) }
    return tokenRows.map { tokens in
        Shortcut(tokens: tokens.enumerated().map { KeyToken(id: $0.offset, label: $0.element.label, isModifier: $0.element.isModifier) }, action: modeHintsLeaveAction, searchText: "")
    }
}

/// One line, short enough for a column. A shell script bound with `exec-and-forget` can run to many lines
func modeHintsActionText(_ action: String, maxLength: Int = 44) -> String {
    let oneLine = action.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return oneLine.count > maxLength ? oneLine.prefix(maxLength - 1).trimmingCharacters(in: .whitespaces) + "…" : oneLine
}

/// Nil in the main mode, while Airlock is paused, and with `[mode-hints] enabled = false`.
/// The main mode holds every global shortcut, far too many for a panel that is always on screen.
@MainActor
func currentModeHints() -> ModeHints? {
    guard config.modeHints.enabled, sessionCoordinator.isEnabled, let mode = activeMode, mode != mainModeId else { return nil }
    return modeHints(mode: mode, bindings: Array(hotkeyBindings(for: mode).values), oneShot: config.modes[mode]?.oneShot == true)
}

/// Rows are laid out top to bottom, then in the next column.
func modeHintsColumns(_ rows: [Shortcut], rowsPerColumn: Int) -> [[Shortcut]] {
    let perColumn = max(1, rowsPerColumn)
    return stride(from: 0, to: rows.count, by: perColumn).map { Array(rows[$0 ..< min($0 + perColumn, rows.count)]) }
}

/// The column heights to try for `rowCount` rows, widest layout first: four columns, then three,
/// two, and one. A column holds at least eight rows, so a short list stays in one column.
func modeHintsRowsPerColumnOptions(rowCount: Int, minRows: Int = 8, maxColumns: Int = 4) -> [Int] {
    var result: [Int] = []
    for columns in (1 ... maxColumns).reversed() {
        let rows = max(minRows, Int((Double(rowCount) / Double(columns)).rounded(.up)))
        if !result.contains(rows) { result.append(rows) }
    }
    return result
}

/// How the panel is laid out on a screen: the height of its columns, and how much it is shrunk
struct ModeHintsLayout: Equatable {
    let rowsPerColumn: Int
    /// 1 when the panel fits as it is
    let scale: CGFloat
}

/// The panel can't scroll: it ignores the mouse, and its keys belong to the mode. So every row has
/// to fit on screen. The first of `modeHintsRowsPerColumnOptions` that fits `available` wins, which is
/// the one with the most columns. When a mode has too many long rows for any of them, the layout
/// that needs the least shrinking is scaled down to fit. `measure` gives the panel's size for a column height.
func modeHintsLayout(rowCount: Int, available: CGSize, measure: (Int) -> CGSize) -> ModeHintsLayout {
    var best: ModeHintsLayout?
    for rowsPerColumn in modeHintsRowsPerColumnOptions(rowCount: rowCount) {
        let size = measure(rowsPerColumn)
        guard size.width > 0, size.height > 0 else { continue }
        let scale = min(1, available.width / size.width, available.height / size.height)
        if scale >= 1 { return ModeHintsLayout(rowsPerColumn: rowsPerColumn, scale: 1) }
        if scale > best?.scale ?? 0 { best = ModeHintsLayout(rowsPerColumn: rowsPerColumn, scale: scale) }
    }
    return best ?? ModeHintsLayout(rowsPerColumn: max(1, rowCount), scale: 1)
}

// MARK: - Panel

@MainActor private var modeHintsPanel: ModeHintsPanel?

/// Shows, updates, or closes the panel to match the active mode. Call after every change to the
/// active mode or to the config. `activateMode` does both: a config reload ends with it.
@MainActor
func syncModeHintsPanel() {
    if isUnitTest { return }
    guard let hints = currentModeHints() else {
        modeHintsPanel?.close()
        return
    }
    let panel = modeHintsPanel ?? ModeHintsPanel()
    modeHintsPanel = panel
    panel.show(hints)
}

/// Bottom center of the visible frame, clear of the Dock. `modeHintsLayout` keeps the content within
/// the frame. The clamp here is for the rounding of a scaled size.
func modeHintsPanelFrame(contentSize: CGSize, visibleFrame: NSRect, margin: CGFloat = 48) -> NSRect {
    let size = CGSize(width: min(contentSize.width, visibleFrame.width), height: min(contentSize.height, visibleFrame.height))
    let y = min(visibleFrame.minY + margin, visibleFrame.maxY - size.height)
    return NSRect(x: visibleFrame.midX - size.width / 2, y: y, width: size.width, height: size.height)
}

private final class ModeHintsPanel: NSPanelHud {
    private var shown: ModeHints?

    override init() {
        super.init()
        // The keys go to the mode's hotkeys. The panel only informs, so clicks pass through it
        ignoresMouseEvents = true
        collectionBehavior.insert(.ignoresCycle)
        isOpaque = false
        // The view draws its own shadow around its rounded shape
        hasShadow = false
    }

    func show(_ hints: ModeHints) {
        // A config reload re-activates the current mode. Rebuilding the same panel would flicker
        if isVisible, shown == hints { return }
        shown = hints
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var sizes: [Int: CGSize] = [:]
        let layout = modeHintsLayout(rowCount: hints.rows.count, available: visibleFrame.size) { rowsPerColumn in
            let size = NSHostingView(rootView: ModeHintsView(hints: hints, rowsPerColumn: rowsPerColumn)).fittingSize
            sizes[rowsPerColumn] = size
            return size
        }
        let natural = sizes[layout.rowsPerColumn] ?? .zero
        let scaled = CGSize(width: natural.width * layout.scale, height: natural.height * layout.scale)
        let hosting = NSHostingView(rootView: ModeHintsView(hints: hints, rowsPerColumn: layout.rowsPerColumn)
            .scaleEffect(layout.scale, anchor: .topLeading)
            .frame(width: scaled.width, height: scaled.height, alignment: .topLeading))
        let frame = modeHintsPanelFrame(contentSize: scaled, visibleFrame: visibleFrame)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        contentView = hosting
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    override func close() {
        shown = nil
        super.close()
    }
}

// MARK: - View

struct ModeHintsView: View {
    let hints: ModeHints
    let rowsPerColumn: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 9, height: 9)
                Text("\(hints.mode) mode")
                    .font(.system(.headline, design: .rounded))
                if hints.oneShot {
                    Text("one key, then back to main")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 28) {
                ForEach(Array(modeHintsColumns(hints.rows, rowsPerColumn: rowsPerColumn).enumerated()), id: \.offset) { _, column in
                    // A grid, so the actions of a column line up whatever the width of their keys
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                        ForEach(Array(column.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                keys(row)
                                action(row)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1),
        )
        .shadow(color: .black.opacity(0.3), radius: 14, y: 4)
        // Room for the shadow inside the panel, which clips at its frame
        .padding(24)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func keys(_ row: Shortcut) -> some View {
        HStack(spacing: 5) {
            ForEach(row.tokens) { token in
                Text(token.label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(token.isModifier ? Color.secondary : Color.accentColor)
                    .frame(minWidth: 16)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        token.isModifier ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous),
                    )
            }
        }
    }

    private func action(_ row: Shortcut) -> some View {
        Text(row.action)
            .font(.system(.callout, design: .rounded))
            .foregroundStyle(row.action == modeHintsLeaveAction ? .secondary : .primary)
            .lineLimit(1)
            .fixedSize()
    }
}
