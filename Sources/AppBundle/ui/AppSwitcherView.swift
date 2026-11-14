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
                            .onTapGesture {
                                state.selectApp(at: index)
                                dismissAppSwitcher(commit: true)
                            }
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
                                .onTapGesture {
                                    state.selectWindow(at: index)
                                    dismissAppSwitcher(commit: true)
                                }
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
        }
        .frame(width: width)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 5)
        .padding(AppSwitcherLayout.shadowMargin)
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
                    Text("\(group.windows.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.secondary))
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
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.6) : Color.clear),
        )
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
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.6) : Color.clear),
        )
    }
}
