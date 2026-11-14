import AppKit
import Common
import SwiftUI

// MARK: - Global State

@MainActor private var appSwitcherPanel: AppSwitcherPanel?
/// Shared by every panel, so a close or quit accepted by one panel still runs in order after it is
/// replaced. Removing the last entry closes whichever panel is open by then
@MainActor private let appSwitcherActionQueue = AppSwitcherActionQueue(onEntryRemoved: {
    if appSwitcherPanel?.contentState.groups.isEmpty == true {
        dismissAppSwitcher(commit: false)
    }
})
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

// MARK: - App List

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

// MARK: - Keys

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

@MainActor
private final class AppSwitcherPanel: NSPanelHud {
    let contentState: AppSwitcherState
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var detailTasks: [Task<Void, Never>] = []
    private let actionQueue = appSwitcherActionQueue

    override var canBecomeKey: Bool { true }

    init(groups: [AppGroup], selectedAppIndex: Int, thumbnails: [UInt32: CGImage]) {
        self.contentState = AppSwitcherState(groups: groups, selectedAppIndex: selectedAppIndex, thumbnails: thumbnails, actionQueue: appSwitcherActionQueue)
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
              let pid = contentState.reserveAppForQuit()
        else { return }
        runWhileOpen(
            token,
            operation: "Quitting an app from the app switcher",
            userMessage: "Airlock could not quit the app.",
            onCompletion: { self.contentState.finishQuittingApp(pid) },
        ) {
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
        // Closing the panel does not cancel explicit close/quit requests already accepted.
        // Each request still validates session admission, and may dismiss only its own panel.
        actionQueue.enqueue {
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
