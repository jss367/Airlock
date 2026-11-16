import AppKit
import SwiftUI

// MARK: - Layout

/// How large the switcher draws. Chosen in Settings → Appearance
enum AppSwitcherSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
        }
    }

    var scale: CGFloat {
        switch self {
            case .small: 0.8
            case .medium: 1
            case .large: 1.25
        }
    }
}

struct AppSwitcherLayout {
    /// Multiplies icons, thumbnails, and the space around them
    let scale: CGFloat

    init(size: AppSwitcherSize = .medium) {
        self.scale = size.scale
    }

    /// Room around the content for its drop shadow
    static let shadowMargin: CGFloat = 30
    private static let maxTilesWithoutScrolling = 4

    var iconSize: CGFloat { length(80) }
    /// App names get a little more room than the icon above them. They follow the text size,
    /// so a name that fits at one size fits at all of them
    var iconLabelWidth: CGFloat { fontSize(96).rounded() }
    var itemPadding: CGFloat { length(8) }
    var iconSpacing: CGFloat { length(14) }
    var thumbnailSize: CGSize { CGSize(width: length(264), height: length(165)) }
    var tileSpacing: CGFloat { length(14) }
    var rowPadding: CGSize { CGSize(width: length(22), height: length(16)) }
    var cornerRadius: CGFloat { length(16) }
    /// Thumbnails are drawn at most `thumbnailSize` points large, so 2x pixels is all they need
    var thumbnailMaxPixelDimension: CGFloat { 2 * max(thumbnailSize.width, thumbnailSize.height) }
    /// Fits the key hints on two lines when a single window would make the panel narrower
    private var minWidth: CGFloat { (400 * textScale).rounded() }

    /// A length in whole points at this size
    func length(_ points: CGFloat) -> CGFloat {
        (points * scale).rounded()
    }

    /// Text changes half as much as the pictures do, so it stays readable when small and quiet when large
    private var textScale: CGFloat { 1 + (scale - 1) / 2 }

    func fontSize(_ points: CGFloat) -> CGFloat {
        points * textScale
    }

    /// Wide enough for every app icon and for the busiest app's windows, within what the screen allows.
    /// The width stays fixed while the switcher is open so the panel doesn't resize under the user.
    func contentWidth(appCount: Int, maxWindowCount: Int, availableWidth: CGFloat) -> CGFloat {
        let iconsWidth = rowWidth(itemCount: appCount, itemWidth: iconLabelWidth + 2 * itemPadding, spacing: iconSpacing)
        let tilesWidth = rowWidth(
            itemCount: min(maxWindowCount, Self.maxTilesWithoutScrolling),
            itemWidth: thumbnailSize.width + 2 * itemPadding,
            spacing: tileSpacing,
        )
        // The minimum is preferred; the available screen width is a hard limit at every size.
        return min(max(0, availableWidth), max(minWidth, max(iconsWidth, tilesWidth)))
    }

    private func rowWidth(itemCount: Int, itemWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        CGFloat(itemCount) * itemWidth + CGFloat(max(0, itemCount - 1)) * spacing + 2 * rowPadding.width
    }

    /// Break a row of items into as few lines as fit within `maxWidth`, then even the lines out so the
    /// last one isn't left with a single item. An item wider than `maxWidth` gets a line to itself
    static func wrappedLines(itemWidths: [CGFloat], spacing: CGFloat, maxWidth: CGFloat) -> [Range<Int>] {
        let widest = filledLines(itemWidths: itemWidths, spacing: spacing, maxWidth: maxWidth)
        // The narrowest limit that needs no more lines is the width of some run of neighboring items
        var runWidths: [CGFloat] = []
        for start in itemWidths.indices {
            var width: CGFloat = 0
            for end in start ..< itemWidths.count {
                width += itemWidths[end] + (end == start ? 0 : spacing)
                if width < maxWidth { runWidths.append(width) }
            }
        }
        return runWidths.sorted().lazy
            .map { filledLines(itemWidths: itemWidths, spacing: spacing, maxWidth: $0) }
            .first { $0.count == widest.count } ?? widest
    }

    private static func filledLines(itemWidths: [CGFloat], spacing: CGFloat, maxWidth: CGFloat) -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var lineStart = 0
        var lineWidth: CGFloat = 0
        for (index, width) in itemWidths.enumerated() {
            let widthWithItem = index == lineStart ? width : lineWidth + spacing + width
            if index > lineStart && widthWithItem > maxWidth {
                lines.append(lineStart ..< index)
                lineStart = index
                lineWidth = width
            } else {
                lineWidth = widthWithItem
            }
        }
        if lineStart < itemWidths.count { lines.append(lineStart ..< itemWidths.count) }
        return lines
    }
}

// MARK: - SwiftUI Views

struct AppSwitcherContent: View {
    @ObservedObject var state: AppSwitcherState
    let width: CGFloat
    var layout = AppSwitcherLayout()

    var body: some View {
        VStack(spacing: 0) {
            // Keep every app visible, wrapping into centered rows in keyboard cycling order.
            WrappingRow(spacing: layout.iconSpacing, lineSpacing: layout.iconSpacing) {
                ForEach(Array(state.groups.enumerated()), id: \.element.id) { index, group in
                    AppIconView(
                        group: group,
                        isSelected: index == state.selectedAppIndex,
                        layout: layout,
                    )
                    .background(AppSwitcherIconVisibility(
                        revealSelection: index == state.selectedAppIndex && state.selectionCameFromKeyboard,
                    ))
                    .id(group.id)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active = phase { state.hoverApp(at: index) }
                    }
                    .onTapGesture { switchToApp(at: index) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(group.accessibilityLabel)
                    .accessibilityAddTraits(index == state.selectedAppIndex ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { switchToApp(at: index) }
                }
            }
            .padding(.horizontal, layout.rowPadding.width)
            .padding(.vertical, layout.rowPadding.height)
            .frame(width: width)

            Divider()

            // Windows of the selected app. Always shown, even for a single window,
            // so the panel keeps its height while cycling through apps
            if let group = state.selectedGroup {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: layout.tileSpacing) {
                            ForEach(Array(group.windows.enumerated()), id: \.element.id) { index, window in
                                WindowTile(
                                    window: window,
                                    appIcon: group.icon,
                                    thumbnail: state.thumbnails[window.windowId],
                                    isSelected: index == state.selectedWindowIndex,
                                    layout: layout,
                                )
                                .id(window.id)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    if case .active = phase { state.hoverWindow(at: index) }
                                }
                                .onTapGesture { switchToWindow(at: index) }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(window.title)
                                .accessibilityAddTraits(index == state.selectedWindowIndex ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction { switchToWindow(at: index) }
                            }
                        }
                        .padding(.horizontal, layout.rowPadding.width)
                        .padding(.vertical, layout.rowPadding.height)
                        .frame(minWidth: width)
                    }
                    .onChange(of: state.selectedWindowIndex) {
                        if state.selectionCameFromKeyboard, let window = group.windows[safe: state.selectedWindowIndex] {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(window.id, anchor: .center)
                            }
                        }
                    }
                }
                .id(group.id) // a new app starts scrolled to its first window
            }

            Divider()

            KeyHintFooter(layout: layout)
        }
        .frame(width: width)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous))
        // A hairline edge keeps the panel distinct from a window of the same tone behind it
        .overlay(RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        .padding(AppSwitcherLayout.shadowMargin)
    }

    private func switchToApp(at index: Int) {
        state.selectApp(at: index)
        commitAppSwitcher(.click)
    }

    private func switchToWindow(at index: Int) {
        state.selectWindow(at: index)
        commitAppSwitcher(.click)
    }
}

/// Use the icon's actual laid-out bounds, including its label and padding, in the outer AppKit
/// scroll view. A SwiftUI reader inside the icon row cannot control that enclosing NSScrollView.
private struct AppSwitcherIconVisibility: NSViewRepresentable {
    let revealSelection: Bool

    func makeNSView(context: Context) -> AppSwitcherIconVisibilityView {
        AppSwitcherIconVisibilityView()
    }

    func updateNSView(_ view: AppSwitcherIconVisibilityView, context: Context) {
        view.revealSelection = revealSelection
    }
}

final class AppSwitcherIconVisibilityView: NSView {
    var revealSelection = false {
        didSet {
            guard revealSelection != oldValue else { return }
            needsReveal = revealSelection
            scheduleReveal()
        }
    }

    private var needsReveal = false
    private var revealScheduled = false

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleReveal()
    }

    override func layout() {
        super.layout()
        scheduleReveal()
    }

    // This background only measures visibility; SwiftUI owns hover and click handling.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func scheduleReveal() {
        guard needsReveal, !revealScheduled else { return }
        revealScheduled = true
        // SwiftUI updates selection before placing the row. Wait until the document has its
        // final frame and has been installed in the scroll view, including on reverse opening.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.revealScheduled = false }
            guard self.needsReveal, let scrolling = self.enclosingScrollView else { return }
            scrolling.documentView?.layoutSubtreeIfNeeded()
            guard !self.bounds.isEmpty else { return }
            self.needsReveal = false
            self.scrollToVisible(self.bounds)
        }
    }
}

/// Solid accent behind white text, like the Quick Switcher's rows. A translucent accent over the
/// panel's material washes out in light mode
private struct SelectionBackground: View {
    let isSelected: Bool
    let layout: AppSwitcherLayout

    var body: some View {
        RoundedRectangle(cornerRadius: layout.length(10), style: .continuous)
            .fill(isSelected ? Color.accentColor : Color.clear)
    }
}

private struct AppIconView: View {
    let group: AppGroup
    let isSelected: Bool
    let layout: AppSwitcherLayout

    var body: some View {
        VStack(spacing: layout.length(6)) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: group.icon)
                    .resizable()
                    .frame(width: layout.iconSize, height: layout.iconSize)

                if group.windows.count > 1 {
                    // Gray would fade into the accent behind a selected app, so its badge inverts
                    Text("\(group.windows.count)")
                        .font(.system(size: layout.fontSize(11), weight: .bold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)))
                        .offset(x: 4, y: -4)
                }
            }

            Text(group.name)
                .font(.system(size: layout.fontSize(12)))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .frame(width: layout.iconLabelWidth)
        }
        .padding(layout.itemPadding)
        .background(SelectionBackground(isSelected: isSelected, layout: layout))
    }
}

private struct WindowTile: View {
    let window: AppGroupWindow
    let appIcon: NSImage
    let thumbnail: CGImage?
    let isSelected: Bool
    let layout: AppSwitcherLayout

    var body: some View {
        VStack(spacing: layout.length(8)) {
            ZStack {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                } else {
                    // Not captured yet, or screen recording isn't allowed
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary)
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: layout.length(64), height: layout.length(64))
                }
            }
            .frame(width: layout.thumbnailSize.width, height: layout.thumbnailSize.height)

            Text(window.title)
                .font(.system(size: layout.fontSize(13)))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .frame(maxWidth: layout.thumbnailSize.width)
        }
        .padding(layout.itemPadding)
        .background(SelectionBackground(isSelected: isSelected, layout: layout))
    }
}

// MARK: - Key Hints

/// The keys the switcher answers to, as a quiet footer. Its content never changes, so the panel
/// keeps the size it measured when it opened
private struct KeyHintFooter: View {
    let layout: AppSwitcherLayout

    var body: some View {
        WrappingRow(spacing: 16, lineSpacing: 6) {
            ForEach(appSwitcherKeyHints, id: \.title) { hint in
                HStack(spacing: 5) {
                    HStack(spacing: 3) {
                        ForEach(hint.symbols, id: \.self) { symbol in
                            Text(symbol)
                                .font(.system(size: layout.fontSize(11), weight: .medium))
                                .padding(.horizontal, 5)
                                .frame(minWidth: layout.fontSize(18), minHeight: layout.fontSize(18))
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary))
                        }
                    }
                    Text(hint.title)
                        .font(.system(size: layout.fontSize(12)))
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(hint.accessibilityLabel)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, layout.rowPadding.width)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }
}

/// A centered row that wraps onto more lines when the panel is too narrow for it
// SwiftUI.Layout because Airlock has a Layout of its own
private struct WrappingRow: SwiftUI.Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    private struct Line {
        let items: Range<Int>
        let size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(itemSizes(subviews), maxWidth: proposal.width ?? .infinity)
        let width: CGFloat = lines.map(\.size.width).max() ?? 0
        let height: CGFloat = lines.map(\.size.height).reduce(0, +)
        return CGSize(width: width, height: height + CGFloat(max(0, lines.count - 1)) * lineSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = itemSizes(subviews)
        var y = bounds.minY
        for line in lines(sizes, maxWidth: bounds.width) {
            var x = bounds.midX - line.size.width / 2
            for index in line.items {
                let origin = CGPoint(x: x, y: y + (line.size.height - sizes[index].height) / 2)
                subviews[index].place(at: origin, proposal: ProposedViewSize.unspecified)
                x += sizes[index].width + spacing
            }
            y += line.size.height + lineSpacing
        }
    }

    private func itemSizes(_ subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(ProposedViewSize.unspecified) }
    }

    private func lines(_ sizes: [CGSize], maxWidth: CGFloat) -> [Line] {
        AppSwitcherLayout.wrappedLines(itemWidths: sizes.map(\.width), spacing: spacing, maxWidth: maxWidth).map { items in
            let width: CGFloat = sizes[items].map(\.width).reduce(0, +) + CGFloat(items.count - 1) * spacing
            let height: CGFloat = sizes[items].map(\.height).max() ?? 0
            return Line(items: items, size: CGSize(width: width, height: height))
        }
    }
}
