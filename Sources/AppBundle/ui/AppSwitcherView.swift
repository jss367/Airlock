import AppKit
import Common
import SwiftUI

// MARK: - Global State

@MainActor private var appSwitcherPanel: AppSwitcherPanel?
/// The last thumbnail captured for each window, shown right away the next time the switcher opens
@MainActor private var appSwitcherThumbnailCache: [UInt32: CGImage] = [:]
/// The last title read for each window. Reading titles is async, so without this every open
/// would show app names first and swap in the real titles a moment later
@MainActor private var appSwitcherTitleCache: [UInt32: String] = [:]

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
    appSwitcherTitleCache = appSwitcherTitleCache.filter { Window.get(byId: $0.key) != nil }
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

    // Capturing without screen-recording access makes macOS prompt for it. Cmd+Tab must never do
    // that, so without access the tiles show app icons, even for windows captured before it was revoked
    let canCaptureWindows = CGPreflightScreenCaptureAccess()
    appSwitcherThumbnailCache = canCaptureWindows
        ? appSwitcherThumbnailCache.filter { Window.get(byId: $0.key) != nil }
        : [:]
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

    panel.loadWindowDetails(captureThumbnails: canCaptureWindows)
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
    var title: String
}

struct AppGroup: Identifiable {
    let id: Int32 // pid
    let pid: Int32
    let name: String
    let icon: NSImage
    var windows: [AppGroupWindow]
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
                title: appSwitcherTitleCache[window.windowId] ?? window.app.name ?? "Window \(window.windowId)",
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
    private var pendingCloseWindowIds: Set<UInt32> = []

    /// Reads the pointer position in screen coordinates
    private let pointerLocation: @MainActor () -> CGPoint
    /// Where the pointer was at the last keyboard selection. Hovering only selects once the pointer has
    /// moved away from here, so a pointer resting where the panel opens, or under a row that
    /// scrolls, doesn't override the keyboard
    private var pointerAnchor: CGPoint
    /// Rows scroll to keyboard selections only. Scrolling to a hovered item would move it out
    /// from under the pointer and select its neighbor
    private(set) var selectionCameFromKeyboard = true

    init(
        groups: [AppGroup],
        selectedAppIndex: Int,
        thumbnails: [UInt32: CGImage] = [:],
        pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
    ) {
        self.groups = groups
        self.selectedAppIndex = selectedAppIndex
        self.thumbnails = thumbnails
        self.pointerLocation = pointerLocation
        self.pointerAnchor = pointerLocation()
    }

    /// Every window, starting with the selected app's so the thumbnails on screen load first
    var windowIdsFromSelectedApp: [UInt32] {
        let rotated = groups[min(selectedAppIndex, groups.count)...] + groups[..<min(selectedAppIndex, groups.count)]
        return rotated.flatMap { $0.windows.map(\.windowId) }
    }

    var selectedGroup: AppGroup? {
        groups[safe: selectedAppIndex]
    }

    // MARK: Keyboard

    func cycleApp(offset: Int) {
        guard !groups.isEmpty else { return }
        markKeyboardSelection()
        selectedAppIndex = (selectedAppIndex + offset + groups.count) % groups.count
        selectedWindowIndex = 0
    }

    func cycleWindow(offset: Int) {
        guard let group = selectedGroup, !group.windows.isEmpty else { return }
        markKeyboardSelection()
        selectedWindowIndex = (selectedWindowIndex + offset + group.windows.count) % group.windows.count
    }

    /// Drop the selected window from the list and return its id. An app left without windows goes too
    func removeSelectedWindow() -> UInt32? {
        guard let windowId = selectedGroup?.windows[safe: selectedWindowIndex]?.windowId else { return nil }
        removeWindow(windowId: windowId)
        return windowId
    }

    /// Reserve a logical selection without hiding entries before their close is admitted.
    /// Repeated distinct presses advance through the list as if pending closes had succeeded.
    func reserveWindowForClose() -> UInt32? {
        let available = groups.enumerated().compactMap { index, group -> (Int, [AppGroupWindow])? in
            let windows = group.windows.filter { !pendingCloseWindowIds.contains($0.windowId) }
            return windows.isEmpty ? nil : (index, windows)
        }
        guard !available.isEmpty else { return nil }
        let removedBeforeApp = groups.indices.prefix(selectedAppIndex).count(where: { index in
            groups[index].windows.allSatisfy { pendingCloseWindowIds.contains($0.windowId) }
        })
        let appIndex = min(selectedAppIndex - removedBeforeApp, available.count - 1)
        let (originalIndex, windows) = available[appIndex]
        let removedBeforeWindow = groups[originalIndex].windows.prefix(selectedWindowIndex).count(where: {
            pendingCloseWindowIds.contains($0.windowId)
        })
        let windowIndex = originalIndex == selectedAppIndex
            ? min(selectedWindowIndex - removedBeforeWindow, windows.count - 1)
            : 0
        let windowId = windows[windowIndex].windowId
        pendingCloseWindowIds.insert(windowId)
        return windowId
    }

    func finishClosingWindow(_ windowId: UInt32) {
        pendingCloseWindowIds.remove(windowId)
    }

    /// Apply an admitted close before changing the list. A failed operation leaves the target intact.
    func closeWindow(windowId: UInt32, operation: () throws -> Void) rethrows {
        try operation()
        removeWindow(windowId: windowId)
    }

    func closeWindowAfterConfirmation(windowId: UInt32, operation: () async throws -> Bool) async throws -> Bool {
        guard try await operation() else { return false }
        removeWindow(windowId: windowId)
        return true
    }

    private func removeWindow(windowId: UInt32) {
        guard let appIndex = groups.firstIndex(where: { $0.windows.contains(where: { $0.windowId == windowId }) }),
              let windowIndex = groups[appIndex].windows.firstIndex(where: { $0.windowId == windowId })
        else { return }
        markKeyboardSelection()
        groups[appIndex].windows.remove(at: windowIndex)
        if groups[appIndex].windows.isEmpty {
            removeGroup(at: appIndex)
        } else if appIndex == selectedAppIndex {
            if windowIndex < selectedWindowIndex { selectedWindowIndex -= 1 }
            selectedWindowIndex = min(selectedWindowIndex, groups[appIndex].windows.count - 1)
        }
    }

    /// Drop the selected app from the list and return its pid
    func removeSelectedApp() -> Int32? {
        guard let group = selectedGroup else { return nil }
        markKeyboardSelection()
        removeGroup(at: selectedAppIndex)
        return group.pid
    }

    /// Keep the target visible until its quit request succeeds, even if selection changed while waiting.
    func quitApp(pid: Int32, requestQuit: () -> Bool) -> Bool {
        guard let index = groups.firstIndex(where: { $0.pid == pid }), requestQuit() else { return false }
        markKeyboardSelection()
        removeGroup(at: index)
        return true
    }

    private func removeGroup(at index: Int) {
        let removedSelectedGroup = index == selectedAppIndex
        groups.remove(at: index)
        if index < selectedAppIndex { selectedAppIndex -= 1 }
        selectedAppIndex = max(0, min(selectedAppIndex, groups.count - 1))
        if removedSelectedGroup { selectedWindowIndex = 0 }
    }

    private func markKeyboardSelection() {
        selectionCameFromKeyboard = true
        pointerAnchor = pointerLocation()
    }

    // MARK: Pointer

    func hoverApp(at index: Int) {
        if pointerHasMoved { selectApp(at: index) }
    }

    func hoverWindow(at index: Int) {
        if pointerHasMoved { selectWindow(at: index) }
    }

    func selectApp(at index: Int) {
        guard groups.indices.contains(index), index != selectedAppIndex else { return }
        selectionCameFromKeyboard = false
        selectedAppIndex = index
        selectedWindowIndex = 0
    }

    func selectWindow(at index: Int) {
        guard let group = selectedGroup, group.windows.indices.contains(index), index != selectedWindowIndex else { return }
        selectionCameFromKeyboard = false
        selectedWindowIndex = index
    }

    private var pointerHasMoved: Bool {
        let location = pointerLocation()
        return hypot(location.x - pointerAnchor.x, location.y - pointerAnchor.y) > 2
    }

    // MARK: Titles

    /// Read each window's real title, handing over every title found. Windows can be closed from
    /// the switcher while this runs, so each title is applied to whatever the list holds by then
    func refreshWindowTitles(onTitle: @MainActor (UInt32, String) -> Void = { _, _ in }) async {
        for windowId in windowIdsFromSelectedApp {
            guard let window = Window.get(byId: windowId),
                  let title = try? await window.title,
                  !title.isEmpty
            else { continue }
            onTitle(windowId, title)
            setTitle(title, forWindow: windowId)
        }
    }

    private func setTitle(_ title: String, forWindow windowId: UInt32) {
        for groupIndex in groups.indices {
            guard let windowIndex = groups[groupIndex].windows.firstIndex(where: { $0.windowId == windowId }) else { continue }
            if groups[groupIndex].windows[windowIndex].title != title {
                groups[groupIndex].windows[windowIndex].title = title
            }
            return
        }
    }
}

/// What a key does while the switcher is open
enum AppSwitcherKeyAction: Equatable {
    case cycleApp(offset: Int)
    case cycleWindow(offset: Int)
    case closeWindow
    case quitApp
    case cancel
    /// Swallow the key without acting on it
    case ignore
}

/// The switcher's action for a key press, or nil for keys it doesn't use
func appSwitcherKeyAction(keyCode: UInt16, hasShift: Bool, isRepeat: Bool) -> AppSwitcherKeyAction? {
    switch keyCode {
        case 48: .cycleApp(offset: hasShift ? -1 : 1) // Tab
        case 124: .cycleApp(offset: 1) // Right arrow
        case 123: .cycleApp(offset: -1) // Left arrow
        case 38, 125: .cycleWindow(offset: 1) // j, Down arrow
        case 40, 126: .cycleWindow(offset: -1) // k, Up arrow
        // Holding the key down must not close one window after another
        case 13: isRepeat ? .ignore : .closeWindow // w
        case 12: isRepeat ? .ignore : .quitApp // q
        case 53: .cancel // Escape
        default: nil
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
    func loadWindowDetails(captureThumbnails: Bool) {
        detailTasks.append(Task { [contentState] in
            await contentState.refreshWindowTitles { appSwitcherTitleCache[$0] = $1 }
        })
        guard captureThumbnails else { return }
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
        let action = appSwitcherKeyAction(
            keyCode: event.keyCode,
            hasShift: event.modifierFlags.contains(.shift),
            isRepeat: event.isARepeat,
        )
        switch action {
            case .cycleApp(let offset): contentState.cycleApp(offset: offset)
            case .cycleWindow(let offset): contentState.cycleWindow(offset: offset)
            case .closeWindow: closeSelectedWindow()
            case .quitApp: quitSelectedApp()
            case .cancel: Task { @MainActor in dismissAppSwitcher(commit: false) }
            case .ignore: break
            case nil: return false
        }
        return true
    }

    private func closeSelectedWindow() {
        guard let token: RunSessionGuard = .isServerEnabled,
              let windowId = contentState.reserveWindowForClose()
        else { return }
        runWhileOpen(
            token,
            operation: "Closing a window from the app switcher",
            userMessage: "Airlock could not close the window.",
            onCompletion: { self.contentState.finishClosingWindow(windowId) },
        ) {
            guard try await self.contentState.closeWindowAfterConfirmation(windowId: windowId, operation: {
                guard let window = Window.get(byId: windowId) as? MacWindow else { return false }
                return try await window.closeAxWindowConfirmed()
            }) else {
                throw NSError(domain: "Airlock.AppSwitcher", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "The window could not be closed. It may be unavailable, read-only, or lack a close button.",
                ])
            }
        }
    }

    private func quitSelectedApp() {
        guard let token: RunSessionGuard = .isServerEnabled,
              let pid = contentState.selectedGroup?.pid
        else { return }
        runWhileOpen(token, operation: "Quitting an app from the app switcher", userMessage: "Airlock could not quit the app.") {
            guard self.contentState.quitApp(pid: pid, requestQuit: {
                MacApp.allAppsMap[pid]?.nsApp.terminate() == true
            }) else {
                throw NSError(domain: "Airlock.AppSwitcher", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The app could not be found or refused the quit request.",
                ])
            }
            for workspace in Workspace.all {
                for window in workspace.allLeafWindowsRecursive where window.app.pid == pid {
                    (window as? MacWindow)?.garbageCollect(skipClosedWindowsCache: true)
                }
            }
        }
    }

    /// Run an action that leaves the switcher open, unless it just removed the last entry
    private func runWhileOpen(
        _ token: RunSessionGuard,
        operation: String,
        userMessage: String,
        onCompletion: @escaping @MainActor () -> Void = {},
        _ body: @escaping @MainActor () async throws -> Void,
    ) {
        Task {
            defer { onCompletion() }
            await withErrorReporting(operation, userMessage: userMessage) {
                try await runLightSession(.menuBarButton, token) { try await body() }
                if self.contentState.groups.isEmpty, appSwitcherPanel === self {
                    dismissAppSwitcher(commit: false)
                }
            }
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
