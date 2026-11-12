import AppKit
import Common
import SwiftUI

// MARK: - Global State

@MainActor private var appSwitcherPanel: AppSwitcherPanel?
/// The last thumbnail captured for each window, shown right away the next time the switcher opens
@MainActor private var appSwitcherThumbnailCache: [UInt32: CGImage] = [:]

@MainActor var isAppSwitcherVisible: Bool {
    appSwitcherPanel?.isVisible == true
}

/// Open the app switcher panel and highlight the next/prev app relative to the currently focused one.
@MainActor
func showAppSwitcher(direction: AppCycleDirection) {
    if let panel = appSwitcherPanel, panel.isVisible {
        cycleAppSwitcher(direction: direction)
        return
    }
    // With Cmd held the user picks from the panel, so list the most recent app first: a quick tap
    // flips between the last two apps. Without Cmd (e.g. CLI-triggered `focus app-next`) the switch
    // commits right away, and only a fixed order lets repeated calls reach every app
    let isCmdHeld = NSEvent.modifierFlags.contains(.command)
    let groups = buildAppGroups(order: isCmdHeld ? .recency : .tree)
    guard !groups.isEmpty else { return }

    let currentPid = focus.windowOrNil?.app.pid
    let startIndex: Int
    if let currentPid, let idx = groups.firstIndex(where: { $0.pid == currentPid }) {
        let offset = direction == .appPrev ? -1 : 1
        startIndex = (idx + offset + groups.count) % groups.count
    } else {
        startIndex = 0
    }

    appSwitcherThumbnailCache = appSwitcherThumbnailCache.filter { Window.get(byId: $0.key) != nil }
    let panel = AppSwitcherPanel(groups: groups, selectedAppIndex: startIndex, thumbnails: appSwitcherThumbnailCache)
    appSwitcherPanel = panel
    panel.show()

    // Commit immediately so the panel doesn't stay open indefinitely.
    if !isCmdHeld {
        Task { @MainActor in
            dismissAppSwitcher(commit: true)
        }
        return
    }

    panel.loadWindowDetails()
}

/// Move the app highlight in the given direction. Only meaningful when the panel is already visible.
@MainActor
func cycleAppSwitcher(direction: AppCycleDirection) {
    guard let panel = appSwitcherPanel, panel.isVisible else { return }
    switch direction {
        case .appNext:
            panel.contentState.cycleApp(offset: 1)
        case .appPrev:
            panel.contentState.cycleApp(offset: -1)
        case .sameAppNext, .sameAppPrev:
            break // same-app cycling doesn't use the panel
    }
}

/// Dismiss the app switcher. If `commit` is true, focus the selected window/app.
@MainActor
func dismissAppSwitcher(commit: Bool) {
    guard let panel = appSwitcherPanel else { return }
    let selectedGroup: AppGroup?
    let selectedWindowIndex: Int
    if commit {
        selectedGroup = panel.contentState.selectedGroup
        selectedWindowIndex = panel.contentState.selectedWindowIndex
    } else {
        selectedGroup = nil
        selectedWindowIndex = 0
    }
    panel.close()
    appSwitcherPanel = nil

    if commit, let group = selectedGroup {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task {
            await withErrorReporting("Switching apps", userMessage: "Airlock could not switch apps.") {
                try await runLightSession(.menuBarButton, token) {
                    let windowId = group.windows[safe: selectedWindowIndex]?.windowId ?? group.windows.first?.windowId
                    if let windowId, let window = Window.get(byId: windowId) {
                        _ = window.focusWindow()
                    }
                }
            }
        }
    }
}

// MARK: - Data Model

struct AppGroupWindow: Identifiable {
    let id: UInt32 // windowId
    let windowId: UInt32
    let title: String
}

struct AppGroup: Identifiable {
    let id: Int32 // pid
    let pid: Int32
    let name: String
    let icon: NSImage
    let windows: [AppGroupWindow]
}

enum AppSwitcherOrder {
    /// Most recently focused app first
    case recency
    /// The order apps appear in the workspace tree
    case tree
}

@MainActor
private func buildAppGroups(order: AppSwitcherOrder) -> [AppGroup] {
    let workspace = focus.workspace

    // Each app's windows are listed most recent first, so committing the switcher
    // lands on the window the user last used rather than the app's first one
    var windowsByApp = groupedPreservingOrder(windowsByFocusRecency(workspace), by: { $0.app.pid })
    if order == .tree {
        let treeOrder = groupedPreservingOrder(workspace.allLeafWindowsRecursive, by: { $0.app.pid }).map(\.key)
        windowsByApp.sort { a, b in
            (treeOrder.firstIndex(of: a.key) ?? .max) < (treeOrder.firstIndex(of: b.key) ?? .max)
        }
    }

    return windowsByApp.map { pid, windows in
        let app = NSRunningApplication(processIdentifier: pid)
        let name = app?.localizedName ?? "Unknown"
        let icon = app?.icon ?? NSImage(named: NSImage.applicationIconName)!
        let groupWindows = windows.map { window in
            AppGroupWindow(
                id: window.windowId,
                windowId: window.windowId,
                title: window.app.name ?? "Window \(window.windowId)",
            )
        }
        return AppGroup(id: pid, pid: pid, name: name, icon: icon, windows: groupWindows)
    }
}

/// Group items by key. Groups are ordered by their first item, and items keep their order within a group
func groupedPreservingOrder<Item, Key: Hashable>(_ items: [Item], by key: (Item) -> Key) -> [(key: Key, items: [Item])] {
    var groups: [(key: Key, items: [Item])] = []
    var indexByKey: [Key: Int] = [:]
    for item in items {
        let itemKey = key(item)
        if let index = indexByKey[itemKey] {
            groups[index].items.append(item)
        } else {
            indexByKey[itemKey] = groups.count
            groups.append((itemKey, [item]))
        }
    }
    return groups
}

/// The workspace's windows, most recently focused first. Never-focused windows come last, in tree order
@MainActor
func windowsByFocusRecency(_ workspace: Workspace) -> [Window] {
    workspace.allLeafWindowsRecursive.enumerated()
        .sorted { a, b in
            a.element.focusRecency != b.element.focusRecency
                ? a.element.focusRecency > b.element.focusRecency
                : a.offset < b.offset
        }
        .map(\.element)
}

// MARK: - Observable State

@MainActor
final class AppSwitcherState: ObservableObject {
    @Published var groups: [AppGroup]
    @Published var selectedAppIndex: Int
    @Published var selectedWindowIndex: Int = 0
    @Published var thumbnails: [UInt32: CGImage]

    init(groups: [AppGroup], selectedAppIndex: Int, thumbnails: [UInt32: CGImage] = [:]) {
        self.groups = groups
        self.selectedAppIndex = selectedAppIndex
        self.thumbnails = thumbnails
    }

    /// Every window, starting with the selected app's so the thumbnails on screen load first
    var windowIdsFromSelectedApp: [UInt32] {
        let rotated = groups[min(selectedAppIndex, groups.count)...] + groups[..<min(selectedAppIndex, groups.count)]
        return rotated.flatMap { $0.windows.map(\.windowId) }
    }

    var selectedGroup: AppGroup? {
        groups[safe: selectedAppIndex]
    }

    func cycleApp(offset: Int) {
        guard !groups.isEmpty else { return }
        selectedAppIndex = (selectedAppIndex + offset + groups.count) % groups.count
        selectedWindowIndex = 0
    }

    func cycleWindow(offset: Int) {
        guard let group = selectedGroup, !group.windows.isEmpty else { return }
        selectedWindowIndex = (selectedWindowIndex + offset + group.windows.count) % group.windows.count
    }

    func refreshWindowTitles() async {
        var updatedGroups = groups
        for groupIndex in updatedGroups.indices {
            var updatedWindows = updatedGroups[groupIndex].windows
            for windowIndex in updatedWindows.indices {
                let windowId = updatedWindows[windowIndex].windowId
                if let window = Window.get(byId: windowId),
                   let realTitle = try? await window.title,
                   !realTitle.isEmpty
                {
                    updatedWindows[windowIndex] = AppGroupWindow(
                        id: updatedWindows[windowIndex].id,
                        windowId: windowId,
                        title: realTitle,
                    )
                }
            }
            updatedGroups[groupIndex] = AppGroup(
                id: updatedGroups[groupIndex].id,
                pid: updatedGroups[groupIndex].pid,
                name: updatedGroups[groupIndex].name,
                icon: updatedGroups[groupIndex].icon,
                windows: updatedWindows,
            )
        }
        groups = updatedGroups
    }
}

// MARK: - Panel

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

@MainActor
private final class AppSwitcherPanel: NSPanelHud {
    let contentState: AppSwitcherState
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var detailTasks: [Task<Void, Never>] = []

    override var canBecomeKey: Bool { true }

    init(groups: [AppGroup], selectedAppIndex: Int, thumbnails: [UInt32: CGImage]) {
        self.contentState = AppSwitcherState(groups: groups, selectedAppIndex: selectedAppIndex, thumbnails: thumbnails)
        super.init()

        let screen = NSScreen.main
        let margin = AppSwitcherLayout.shadowMargin
        let contentWidth = AppSwitcherLayout.contentWidth(
            appCount: groups.count,
            maxWindowCount: groups.map(\.windows.count).max() ?? 0,
            availableWidth: (screen?.visibleFrame.width ?? 1200) - 2 * margin,
        )
        let hosting = NSHostingView(rootView: AppSwitcherContent(state: contentState, width: contentWidth))
        self.contentView = hosting

        if let screen {
            let size = hosting.fittingSize
            let x = screen.frame.midX - size.width / 2
            // Centered a little above the middle of the screen, without running off the top
            let centerY = screen.frame.midY + screen.frame.height * 0.1
            let y = min(centerY - size.height / 2, screen.visibleFrame.maxY - size.height)
            self.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        }

        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
    }

    func show() {
        makeKeyAndOrderFront(nil)
        installEventMonitors()
    }

    override func close() {
        removeEventMonitors()
        detailTasks.forEach { $0.cancel() }
        detailTasks = []
        super.close()
    }

    /// Fill in real window titles and thumbnails after the panel is already on screen
    func loadWindowDetails() {
        detailTasks.append(Task { [contentState] in
            await contentState.refreshWindowTitles()
        })
        // Capturing without screen-recording access makes macOS prompt for it. Cmd+Tab must never
        // do that, so the tiles keep showing app icons until the user grants access elsewhere
        guard CGPreflightScreenCaptureAccess() else { return }
        let windowIds = contentState.windowIdsFromSelectedApp
        detailTasks.append(Task { [contentState] in
            await captureWindowImages(
                orderedWindowIds: windowIds,
                maxPixelDimension: AppSwitcherLayout.thumbnailMaxPixelDimension,
            ) { windowId, image in
                contentState.thumbnails[windowId] = image
                appSwitcherThumbnailCache[windowId] = image
            }
        })
    }

    private func installEventMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleEvent(event) ? nil : event
        }
        // Global monitor for Cmd release when we don't have focus
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }
            _ = self.handleFlagsChanged(event)
        }
    }

    private func removeEventMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func handleEvent(_ event: NSEvent) -> Bool {
        switch event.type {
            case .flagsChanged:
                return handleFlagsChanged(event)
            case .keyDown:
                return handleKeyDown(event)
            default:
                return false
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) -> Bool {
        // If Cmd key was released, commit selection
        if !event.modifierFlags.contains(.command) {
            Task { @MainActor in
                dismissAppSwitcher(commit: true)
            }
            return true
        }
        return false
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let hasShift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
            case 48: // Tab
                if hasShift {
                    contentState.cycleApp(offset: -1)
                } else {
                    contentState.cycleApp(offset: 1)
                }
                return true
            case 38: // j
                contentState.cycleWindow(offset: 1)
                return true
            case 40: // k
                contentState.cycleWindow(offset: -1)
                return true
            case 53: // Escape
                Task { @MainActor in
                    dismissAppSwitcher(commit: false)
                }
                return true
            default:
                return false
        }
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
                        }
                    }
                    .padding(.horizontal, AppSwitcherLayout.rowPadding.width)
                    .padding(.vertical, AppSwitcherLayout.rowPadding.height)
                    .frame(minWidth: width) // center the row when it's narrower than the panel
                }
                .onChange(of: state.selectedAppIndex) {
                    if let group = state.selectedGroup {
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
                            }
                        }
                        .padding(.horizontal, AppSwitcherLayout.rowPadding.width)
                        .padding(.vertical, AppSwitcherLayout.rowPadding.height)
                        .frame(minWidth: width)
                    }
                    .onChange(of: state.selectedWindowIndex) {
                        if let window = group.windows[safe: state.selectedWindowIndex] {
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
