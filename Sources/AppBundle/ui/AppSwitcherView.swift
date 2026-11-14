import AppKit
import SwiftUI

// MARK: - Layout

enum AppSwitcherLayout {
    static let iconSize: CGFloat = 64
    /// App names get a little more room than the icon above them
    static let iconLabelWidth: CGFloat = 72
    static let itemPadding: CGFloat = 6
    static let iconSpacing: CGFloat = 12
    static let thumbnailSize = CGSize(width: 200, height: 125)
    static let tileSpacing: CGFloat = 10
    static let rowPadding = CGSize(width: 16, height: 12)
    /// Room around the content for its drop shadow
    static let shadowMargin: CGFloat = 30
    /// Thumbnails are drawn at most `thumbnailSize` points large, so 2x pixels is all they need
    static let thumbnailMaxPixelDimension: CGFloat = 2 * max(thumbnailSize.width, thumbnailSize.height)
    private static let minWidth: CGFloat = 320
    private static let maxTilesWithoutScrolling = 4

    /// Wide enough for every app icon and for the busiest app's windows, within what the screen allows.
    /// The width stays fixed while the switcher is open so the panel doesn't resize under the user.
    static func contentWidth(appCount: Int, maxWindowCount: Int, availableWidth: CGFloat) -> CGFloat {
        let iconsWidth = rowWidth(itemCount: appCount, itemWidth: iconLabelWidth + 2 * itemPadding, spacing: iconSpacing)
        let tilesWidth = rowWidth(
            itemCount: min(maxWindowCount, maxTilesWithoutScrolling),
            itemWidth: thumbnailSize.width + 2 * itemPadding,
            spacing: tileSpacing,
        )
        return max(minWidth, min(max(iconsWidth, tilesWidth), availableWidth))
    }

    private static func rowWidth(itemCount: Int, itemWidth: CGFloat, spacing: CGFloat) -> CGFloat {
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

    var body: some View {
        VStack(spacing: 0) {
            // App icons row
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSwitcherLayout.iconSpacing) {
                        ForEach(Array(state.groups.enumerated()), id: \.element.id) { index, group in
                            AppIconView(
                                group: group,
                                isSelected: index == state.selectedAppIndex,
                            )
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
                    .padding(.horizontal, AppSwitcherLayout.rowPadding.width)
                    .padding(.vertical, AppSwitcherLayout.rowPadding.height)
                    .frame(minWidth: width) // center the row when it's narrower than the panel
                }
                .onAppear {
                    // Cmd+Shift+Tab opens on the last app, which a long row would leave off screen
                    if let group = state.selectedGroup {
                        proxy.scrollTo(group.id, anchor: .center)
                    }
                }
                .onChange(of: state.selectedAppIndex) {
                    if state.selectionCameFromKeyboard, let group = state.selectedGroup {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(group.id, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            // Windows of the selected app. Always shown, even for a single window,
            // so the panel keeps its height while cycling through apps
            if let group = state.selectedGroup {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppSwitcherLayout.tileSpacing) {
                            ForEach(Array(group.windows.enumerated()), id: \.element.id) { index, window in
                                WindowTile(
                                    window: window,
                                    appIcon: group.icon,
                                    thumbnail: state.thumbnails[window.windowId],
                                    isSelected: index == state.selectedWindowIndex,
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
                        .padding(.horizontal, AppSwitcherLayout.rowPadding.width)
                        .padding(.vertical, AppSwitcherLayout.rowPadding.height)
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

            KeyHintFooter()
        }
        .frame(width: width)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 5)
        .padding(AppSwitcherLayout.shadowMargin)
    }

    private func switchToApp(at index: Int) {
        state.selectApp(at: index)
        dismissAppSwitcher(commit: true)
    }

    private func switchToWindow(at index: Int) {
        state.selectWindow(at: index)
        dismissAppSwitcher(commit: true)
    }
}

/// Solid accent behind white text, like the Quick Switcher's rows. A translucent accent over the
/// panel's material washes out in light mode
private struct SelectionBackground: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor : Color.clear)
    }
}

private struct AppIconView: View {
    let group: AppGroup
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: group.icon)
                    .resizable()
                    .frame(width: AppSwitcherLayout.iconSize, height: AppSwitcherLayout.iconSize)

                if group.windows.count > 1 {
                    // Gray would fade into the accent behind a selected app, so its badge inverts
                    Text("\(group.windows.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)))
                        .offset(x: 4, y: -4)
                }
            }

            Text(group.name)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .frame(width: AppSwitcherLayout.iconLabelWidth)
        }
        .padding(AppSwitcherLayout.itemPadding)
        .background(SelectionBackground(isSelected: isSelected))
    }
}

private struct WindowTile: View {
    let window: AppGroupWindow
    let appIcon: NSImage
    let thumbnail: CGImage?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                } else {
                    // Not captured yet, or screen recording isn't allowed
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 48, height: 48)
                }
            }
            .frame(width: AppSwitcherLayout.thumbnailSize.width, height: AppSwitcherLayout.thumbnailSize.height)

            Text(window.title)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .frame(maxWidth: AppSwitcherLayout.thumbnailSize.width)
        }
        .padding(AppSwitcherLayout.itemPadding)
        .background(SelectionBackground(isSelected: isSelected))
    }
}

// MARK: - Key Hints

/// The keys the switcher answers to, as a quiet footer. Its content never changes, so the panel
/// keeps the size it measured when it opened
private struct KeyHintFooter: View {
    var body: some View {
        WrappingRow(spacing: 14, lineSpacing: 6) {
            ForEach(appSwitcherKeyHints, id: \.title) { hint in
                HStack(spacing: 5) {
                    HStack(spacing: 3) {
                        ForEach(hint.symbols, id: \.self) { symbol in
                            Text(symbol)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary))
                        }
                    }
                    Text(hint.title)
                        .font(.system(size: 11))
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(hint.accessibilityLabel)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, AppSwitcherLayout.rowPadding.width)
        .padding(.vertical, 8)
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
