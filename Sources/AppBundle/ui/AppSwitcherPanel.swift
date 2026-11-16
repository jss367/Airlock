import AppKit
import Common
import os
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

// MARK: - Cmd Release

private let appSwitcherLogger = Logger(subsystem: airlockAppId, category: "appSwitcher")

/// Whether Cmd is down right now. This reads the key's state, not the events Airlock happened to receive
@MainActor
func isCommandKeyDown() -> Bool {
    NSEvent.modifierFlags.contains(.command)
}

/// What made the switcher act on its selection
enum AppSwitcherCommitTrigger: String {
    /// Cmd was already up when the shortcut ran, so the switch happened without the panel
    case cmdUpBeforeOpen
    /// Cmd went up while the panel was being built, before its monitors could see the release
    case cmdUpDuringOpen
    /// A monitor saw Cmd go up
    case releaseEvent
    /// No monitor reported the release. The poll found Cmd up
    case releasePoll
    case click

    /// A release that no event reported. Only the fallbacks keep these from leaving the panel open
    var isMissedRelease: Bool { self == .cmdUpDuringOpen || self == .releasePoll }
}

/// Missed releases are logged at a level that reaches the disk, so `log show` can tell how often they happen
private func logAppSwitcherCommit(_ trigger: AppSwitcherCommitTrigger) {
    if trigger.isMissedRelease {
        appSwitcherLogger.notice("Committed after a Cmd release that no event reported: \(trigger.rawValue, privacy: .public)")
    } else {
        appSwitcherLogger.info("Committed: \(trigger.rawValue, privacy: .public)")
    }
}

/// With Cmd held the user picks from the panel, so list the most recent app first: a quick tap
/// flips between the last two apps. A Cmd shortcut let go before its command ran is that same quick
/// tap. Anything else (e.g. CLI-triggered `focus app-next`) switches right away with nothing held,
/// and only a fixed order lets repeated calls reach every app
func appSwitcherOrder(isCmdHeld: Bool, hotkeyModifiers: NSEvent.ModifierFlags?) -> AppSwitcherOrder {
    isCmdHeld || hotkeyModifiers?.contains(.command) == true ? .recency : .tree
}

/// Finds Cmd up by reading the key's state. The panel's monitors see a release only as an event,
/// and an event that never reaches them would otherwise leave the panel open
@MainActor
final class AppSwitcherReleasePoll {
    static let interval: TimeInterval = 0.025
    private let isCommandDown: @MainActor () -> Bool
    private let onRelease: @MainActor () -> Void
    private var timer: Timer?
    private var sawCommandUp = false

    init(isCommandDown: @escaping @MainActor () -> Bool = isCommandKeyDown, onRelease: @escaping @MainActor () -> Void) {
        self.isCommandDown = isCommandDown
        self.onRelease = onRelease
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes, so the poll keeps running while the panel tracks a scroll or a drag
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sawCommandUp = false
    }

    /// A release normally arrives as an event well within one interval, so the first tick that
    /// finds Cmd up leaves it to the monitors. Cmd still up on the next tick means no event is coming
    func tick() {
        if isCommandDown() {
            sawCommandUp = false
        } else if sawCommandUp {
            stop()
            onRelease()
        } else {
            sawCommandUp = true
        }
    }
}

/// Switch to the next/prev app relative to the currently focused one. With Cmd held this opens the
/// panel and waits for the release. With nothing held it switches right away.
/// Runs inside the command session of the `focus` command that asked for it
@MainActor
func showAppSwitcher(direction: AppCycleDirection) {
    if let panel = appSwitcherPanel, panel.isVisible {
        cycleAppSwitcher(direction: direction)
        return
    }
    let isCmdHeld = isCommandKeyDown()
    appSwitcherTitleCache = appSwitcherTitleCache.filter { Window.get(byId: $0.key) != nil }
    let groups = buildAppGroups(order: appSwitcherOrder(isCmdHeld: isCmdHeld, hotkeyModifiers: runningHotkeyModifiers))
    guard !groups.isEmpty else { return }

    let currentPid = focus.windowOrNil?.app.pid
    let startIndex: Int
    if let currentPid, let idx = groups.firstIndex(where: { $0.pid == currentPid }) {
        let offset = direction == .appPrev ? -1 : 1
        startIndex = (idx + offset + groups.count) % groups.count
    } else {
        startIndex = 0
    }

    // There is no release to wait for, so building the panel would only delay the switch
    guard isCmdHeld else {
        logAppSwitcherCommit(.cmdUpBeforeOpen)
        if let windowId = groups[startIndex].windows.first?.windowId, let window = Window.get(byId: windowId) {
            _ = window.focusWindow()
        }
        return
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

    // Building the panel takes long enough for a quick tap to let go of Cmd meanwhile, and the
    // monitors that `show` installs only see releases from now on
    if !isCommandKeyDown() {
        commitAppSwitcher(.cmdUpDuringOpen)
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

/// Close the app switcher and focus its selection
@MainActor
func commitAppSwitcher(_ trigger: AppSwitcherCommitTrigger) {
    guard appSwitcherPanel != nil else { return }
    logAppSwitcherCommit(trigger)
    dismissAppSwitcher(commit: true)
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
                try await runLightSession(.appSwitcher, token) {
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

/// A key the switcher answers to. Key handling and the footer's hints both read `appSwitcherKeys`,
/// so the hints can't drift from what the keys do
struct AppSwitcherKey {
    let keyCode: UInt16
    /// Shown in the footer. Key codes are positions, so letters are the ones a QWERTY layout types there
    let symbol: String
    /// Read by VoiceOver
    let name: String
    let action: AppSwitcherKeyAction
    /// Shift turns the cycle around
    var shiftReverses = false
    /// Whether holding the key down repeats its action
    var repeats = true
}

let appSwitcherKeys: [AppSwitcherKey] = [
    AppSwitcherKey(keyCode: 48, symbol: "⇥", name: "Tab", action: .cycleApp(offset: 1), shiftReverses: true),
    AppSwitcherKey(keyCode: 123, symbol: "←", name: "Left Arrow", action: .cycleApp(offset: -1)),
    AppSwitcherKey(keyCode: 124, symbol: "→", name: "Right Arrow", action: .cycleApp(offset: 1)),
    AppSwitcherKey(keyCode: 126, symbol: "↑", name: "Up Arrow", action: .cycleWindow(offset: -1)),
    AppSwitcherKey(keyCode: 125, symbol: "↓", name: "Down Arrow", action: .cycleWindow(offset: 1)),
    AppSwitcherKey(keyCode: 38, symbol: "J", name: "J", action: .cycleWindow(offset: 1)),
    AppSwitcherKey(keyCode: 40, symbol: "K", name: "K", action: .cycleWindow(offset: -1)),
    // Holding the key down must not close one window after another
    AppSwitcherKey(keyCode: 13, symbol: "W", name: "W", action: .closeWindow, repeats: false),
    AppSwitcherKey(keyCode: 12, symbol: "Q", name: "Q", action: .quitApp, repeats: false),
    AppSwitcherKey(keyCode: 53, symbol: "esc", name: "Escape", action: .cancel),
]

/// The switcher's action for a key press, or nil for keys it doesn't use
func appSwitcherKeyAction(keyCode: UInt16, hasShift: Bool, isRepeat: Bool) -> AppSwitcherKeyAction? {
    guard let key = appSwitcherKeys.first(where: { $0.keyCode == keyCode }) else { return nil }
    if isRepeat && !key.repeats { return .ignore }
    if hasShift && key.shiftReverses, case .cycleApp(let offset) = key.action { return .cycleApp(offset: -offset) }
    return key.action
}

/// One footer entry: an action and every key that performs it
struct AppSwitcherKeyHint: Equatable {
    let title: String
    let symbols: [String]
    let names: [String]

    var accessibilityLabel: String { "\(title): \(names.joined(separator: ", "))" }
}

extension AppSwitcherKeyAction {
    /// The footer's name for the action. Both directions of a cycle share one entry
    var hintTitle: String? {
        switch self {
            case .cycleApp: "Apps"
            case .cycleWindow: "Windows"
            case .closeWindow: "Close window"
            case .quitApp: "Quit app"
            case .cancel: "Cancel"
            case .ignore: nil
        }
    }
}

/// The footer's hints, in the order their first key appears in `appSwitcherKeys`
let appSwitcherKeyHints: [AppSwitcherKeyHint] = groupedPreservingOrder(appSwitcherKeys, by: { $0.action.hintTitle })
    .compactMap { title, keys in
        title.map { AppSwitcherKeyHint(title: $0, symbols: keys.map(\.symbol), names: keys.map(\.name)) }
    }

// MARK: - Panel

/// Keep the chosen tile size, but make a tall panel scroll instead of placing its footer offscreen.
/// This also provides an offscreen-testable boundary without opening the panel or registering input monitors.
@MainActor
func appSwitcherContentView(state: AppSwitcherState, layout: AppSwitcherLayout, availableSize: CGSize) -> NSView {
    let width = layout.contentWidth(
        appCount: state.groups.count,
        maxWindowCount: state.groups.map(\.windows.count).max() ?? 0,
        availableWidth: availableSize.width - 2 * AppSwitcherLayout.shadowMargin,
    )
    let hosting = NSHostingView(rootView: AppSwitcherContent(state: state, width: width, layout: layout))
    let naturalSize = hosting.fittingSize
    hosting.setFrameSize(naturalSize)
    let boundedSize = CGSize(
        width: min(naturalSize.width, max(0, availableSize.width)),
        height: min(naturalSize.height, max(0, availableSize.height)),
    )
    guard boundedSize != naturalSize else { return hosting }
    let scrolling = NSScrollView(frame: NSRect(origin: .zero, size: boundedSize))
    scrolling.drawsBackground = false
    scrolling.hasVerticalScroller = boundedSize.height < naturalSize.height
    scrolling.hasHorizontalScroller = boundedSize.width < naturalSize.width
    scrolling.autohidesScrollers = true
    scrolling.scrollerStyle = .overlay
    scrolling.documentView = hosting
    // NSHostingView's coordinate orientation can differ from an ordinary AppKit document view.
    let top = hosting.isFlipped ? 0 : max(0, naturalSize.height - scrolling.contentSize.height)
    scrolling.contentView.scroll(to: NSPoint(x: 0, y: top))
    scrolling.reflectScrolledClipView(scrolling.contentView)
    return scrolling
}

func appSwitcherPanelFrame(contentSize: CGSize, visibleFrame: NSRect) -> NSRect {
    let size = CGSize(
        width: min(max(0, contentSize.width), visibleFrame.width),
        height: min(max(0, contentSize.height), visibleFrame.height),
    )
    let centerY = visibleFrame.midY + visibleFrame.height * 0.1
    return NSRect(
        x: visibleFrame.midX - size.width / 2,
        y: max(visibleFrame.minY, min(centerY - size.height / 2, visibleFrame.maxY - size.height)),
        width: size.width,
        height: size.height,
    )
}

@MainActor
private final class AppSwitcherPanel: NSPanelHud {
    let contentState: AppSwitcherState
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private lazy var releasePoll = AppSwitcherReleasePoll { [weak self] in self?.commit(.releasePoll) }
    private var detailTasks: [Task<Void, Never>] = []
    private let actionQueue = appSwitcherActionQueue
    /// Read once, so a size changed in Settings applies the next time the switcher opens
    private let layout = AppSwitcherLayout(size: TrayMenuModel.shared.experimentalUISettings.appSwitcherSize)

    override var canBecomeKey: Bool { true }

    init(groups: [AppGroup], selectedAppIndex: Int, thumbnails: [UInt32: CGImage]) {
        self.contentState = AppSwitcherState(groups: groups, selectedAppIndex: selectedAppIndex, thumbnails: thumbnails, actionQueue: appSwitcherActionQueue)
        super.init()

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let content = appSwitcherContentView(state: contentState, layout: layout, availableSize: visibleFrame.size)
        let frame = appSwitcherPanelFrame(contentSize: content.frame.size, visibleFrame: visibleFrame)
        self.contentView = content
        self.setFrame(frame, display: true)

        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
    }

    func show() {
        makeKeyAndOrderFront(nil)
        installEventMonitors()
        releasePoll.start()
    }

    override func close() {
        removeEventMonitors()
        releasePoll.stop()
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
                maxPixelDimension: layout.thumbnailMaxPixelDimension,
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

    /// Key handling answers in a later task, and by then this panel can be closed with another one
    /// open. A panel may only ever dismiss itself
    private var isCurrent: Bool { appSwitcherPanel === self }

    private func commit(_ trigger: AppSwitcherCommitTrigger) {
        if isCurrent { commitAppSwitcher(trigger) }
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
            Task { @MainActor in self.commit(.releaseEvent) }
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
            case .cancel: Task { @MainActor in if self.isCurrent { dismissAppSwitcher(commit: false) } }
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
                try await runLightSession(.appSwitcher, token) { try await body() }
                if self.contentState.groups.isEmpty, appSwitcherPanel === self {
                    dismissAppSwitcher(commit: false)
                }
            }
        }
    }
}
