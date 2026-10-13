import AppKit
import Common

final class MacWindow: Window {
    let macApp: MacApp
    @MainActor private var pendingDetection = WindowDetectionProgress()
    @MainActor private var detectionPrepared = false
    @MainActor private var completingDetection = false
    @MainActor private var detectionCallbacks: [WindowDetectedCallback]?
    private var prevUnhiddenProportionalPositionInsideWorkspaceRect: CGPoint?

    @MainActor
    private init(_ id: UInt32, _ actor: MacApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.macApp = actor
        super.init(id: id, actor, lastFloatingSize: lastFloatingSize, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static var allWindowsMap: [UInt32: MacWindow] = [:]
    @MainActor static var allWindows: [MacWindow] { Array(allWindowsMap.values) }

    @MainActor
    @discardableResult
    static func getOrRegister(windowId: UInt32, macApp: MacApp, beforeRegistration: @MainActor () throws -> Void = {}, beforeDetectionCallbacks: @MainActor () async throws -> Void = {}) async throws -> MacWindow {
        try beforeRegistration()
        if let existing = allWindowsMap[windowId] {
            try await existing.completePendingDetection(beforeCallbacks: beforeDetectionCallbacks)
            return existing
        }
        let rect = try await macApp.getAxRect(windowId)
        let data = try await unbindAndGetBindingDataForNewWindow(
            windowId,
            macApp,
            isStartup || !config.enableWindowManagement
                ? (rect?.center.monitorApproximation ?? mainMonitor).activeWorkspace
                : focus.workspace,
            window: nil,
        )

        // atomic synchronous section
        try beforeRegistration()
        if let existing = allWindowsMap[windowId] {
            try await existing.completePendingDetection(beforeCallbacks: beforeDetectionCallbacks)
            return existing
        }
        let window = MacWindow(windowId, macApp, lastFloatingSize: rect?.size, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        allWindowsMap[windowId] = window

        try await window.completePendingDetection(beforeCallbacks: beforeDetectionCallbacks)
        return window
    }

    @MainActor
    private func completePendingDetection(beforeCallbacks: @MainActor () async throws -> Void) async throws {
        guard !pendingDetection.finished, !completingDetection else { return }
        completingDetection = true
        defer { completingDetection = false }
        if !detectionPrepared {
            try await debugWindowsIfRecording(self)
            let restored = config.enableWindowManagement
                ? try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: self)
                : false
            detectionPrepared = true
            if restored { pendingDetection.finished = true; return }
        }
        // Preserve the rule list across cancellation/config reload so indices cannot replay rules.
        if detectionCallbacks == nil { detectionCallbacks = config.onWindowDetected }
        try await tryOnWindowDetected(self, beforeCallbacks: beforeCallbacks, progress: pendingDetection, callbacks: detectionCallbacks)
        pendingDetection.finished = true
        detectionCallbacks = nil
    }

    // var description: String {
    //     let description = [
    //         ("title", title),
    //         ("role", axWindow.get(Ax.roleAttr)),
    //         ("subrole", axWindow.get(Ax.subroleAttr)),
    //         ("identifier", axWindow.get(Ax.identifierAttr)),
    //         ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
    //         ("windowId", String(windowId)),
    //     ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
    //     return "Window(\(description))"
    // }

    func isWindowHeuristic(_ windowLevel: MacOsWindowLevel?) async throws -> Bool {
        try await macApp.isWindowHeuristic(windowId, windowLevel)
    }

    func isDialogHeuristic(_ windowLevel: MacOsWindowLevel?) async throws -> Bool {
        try await macApp.isDialogHeuristic(windowId, windowLevel)
    }

    func dumpAxInfo() async throws -> [String: Json] {
        try await macApp.dumpWindowAxInfo(windowId: windowId)
    }

    func setNativeFullscreen(_ value: Bool) {
        macApp.setNativeFullscreen(windowId, value)
    }

    func setNativeMinimized(_ value: Bool) {
        macApp.setNativeMinimized(windowId, value)
    }

    // skipClosedWindowsCache is an optimization when it's definitely not necessary to cache closed window.
    //                        If you are unsure, it's better to pass `false`
    @MainActor
    func garbageCollect(skipClosedWindowsCache: Bool) {
        if MacWindow.allWindowsMap.removeValue(forKey: windowId) == nil {
            return
        }
        if !skipClosedWindowsCache { cacheClosedWindowIfNeeded() }
        let parent = unbindFromParent().parent
        let deadWindowWorkspace = parent.nodeWorkspace
        let focus = focus
        if config.enableWindowManagement, let deadWindowWorkspace, deadWindowWorkspace == focus.workspace ||
            deadWindowWorkspace == prevFocusedWorkspace && prevFocusedWorkspaceDate.distance(to: .now) < 1
        {
            switch parent.cases {
                case .tilingContainer, .workspace, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
                    let deadWindowFocus = deadWindowWorkspace.toLiveFocus()
                    _ = setFocus(to: deadWindowFocus)
                    // Guard against "Apple Reminders popup" bug: https://github.com/nikitabobko/AeroSpace/issues/201
                    if focus.windowOrNil?.app.pid != app.pid {
                        // Force focus to fix macOS annoyance with focused apps without windows.
                        //   https://github.com/nikitabobko/AeroSpace/issues/65
                        deadWindowFocus.windowOrNil?.nativeFocus()
                    }
                case .macosPopupWindowsContainer, .macosMinimizedWindowsContainer:
                    break // Don't switch back on popup destruction
            }
        }
    }

    @MainActor override var title: String { get async throws { try await macApp.getAxTitle(windowId) ?? "" } }
    @MainActor override var isMacosFullscreen: Bool { get async throws { try await macApp.isMacosNativeFullscreen(windowId) == true } }
    @MainActor override var isMacosMinimized: Bool { get async throws { try await macApp.isMacosNativeMinimized(windowId) == true } }

    @MainActor
    override func nativeFocus() {
        macApp.nativeFocus(windowId)
    }

    override func closeAxWindow() {
        garbageCollect(skipClosedWindowsCache: true)
        macApp.closeAndUnregisterAxWindow(windowId)
    }

    @MainActor
    override func hideInCorner(_ corner: OptimalHideCorner, admissionCheck: @MainActor () async throws -> Void = {}) async throws {
        try await admissionCheck()
        guard let nodeMonitor else { return }
        // Don't accidentally override prevUnhiddenEmulationPosition in case of subsequent `hideInCorner` calls
        if !isHiddenInCorner {
            guard let windowRect = try await getAxRect() else { return }
            try await admissionCheck()
            // Check for isHiddenInCorner for the second time because of the suspension point above
            if !isHiddenInCorner {
                let topLeftCorner = windowRect.topLeftCorner
                let monitorRect = windowRect.center.monitorApproximation.rect // Similar to layoutFloatingWindow. Non idempotent
                let absolutePoint = topLeftCorner - monitorRect.topLeftCorner
                prevUnhiddenProportionalPositionInsideWorkspaceRect =
                    CGPoint(x: absolutePoint.x / monitorRect.width, y: absolutePoint.y / monitorRect.height)
            }
        }
        let p: CGPoint
        switch corner {
            case .bottomLeftCorner:
                let size = try await getAxSize()
                try await admissionCheck()
                guard let s = size else { fallthrough }
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: -1)
                p = nodeMonitor.visibleRect.bottomLeftCorner + onePixelOffset + CGPoint(x: -s.width, y: 0)
            case .bottomRightCorner:
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: 1)
                p = nodeMonitor.visibleRect.bottomRightCorner - onePixelOffset
        }
        try await admissionCheck()
        setAxFrame(p, nil)
    }

    @MainActor
    override func unhideFromCorner(restoreTilingPosition: Bool = false) {
        guard let prevUnhiddenProportionalPositionInsideWorkspaceRect else { return }
        guard let nodeWorkspace else { return } // hiding only makes sense for workspace windows
        guard let parent else { return }

        switch getChildParentRelation(child: self, parent: parent) {
            // Just a small optimization to avoid unnecessary AX calls for non floating windows
            // Tiling windows should be unhidden with layoutRecursive anyway
            case .floatingWindow:
                setAxFrame(unhiddenFloatingTopLeft(prevUnhiddenProportionalPositionInsideWorkspaceRect, nodeWorkspace), nil)
            case .tiling:
                if restoreTilingPosition {
                    let point = lastAppliedLayoutPhysicalRect?.topLeftCorner
                        ?? unhiddenFloatingTopLeft(prevUnhiddenProportionalPositionInsideWorkspaceRect, nodeWorkspace)
                    setAxFrame(point, nil)
                }
            case .macosNativeFullscreenWindow, .macosNativeHiddenAppWindow, .macosNativeMinimizedWindow,
                 .macosPopupWindow, .rootTilingContainer, .shimContainerRelation: break
        }

        self.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
    }

    @MainActor
    private func unhiddenFloatingTopLeft(_ proportionalPosition: CGPoint, _ workspace: Workspace) -> CGPoint {
        let workspaceRect = workspace.workspaceMonitor.rect
        var newX = workspaceRect.topLeftX + workspaceRect.width * proportionalPosition.x
        var newY = workspaceRect.topLeftY + workspaceRect.height * proportionalPosition.y
        // https://github.com/nikitabobko/AeroSpace/issues/1519
        let windowWidth = lastFloatingSize?.width ?? 0
        let windowHeight = lastFloatingSize?.height ?? 0
        newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
        newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))
        return CGPoint(x: newX, y: newY)
    }

    /// Where the window will be once its workspace is shown again, or nil if it isn't hidden in the corner.
    /// Tiling windows go back to their last layout rect, floating windows to their saved position.
    @MainActor
    func rectWhenUnhidden(currentSize: CGSize) -> Rect? {
        guard let prevUnhiddenProportionalPositionInsideWorkspaceRect, let nodeWorkspace else { return nil }
        if let lastAppliedLayoutPhysicalRect { return lastAppliedLayoutPhysicalRect }
        let topLeft = unhiddenFloatingTopLeft(prevUnhiddenProportionalPositionInsideWorkspaceRect, nodeWorkspace)
        return Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: currentSize.width, height: currentSize.height)
    }

    override var isHiddenInCorner: Bool {
        prevUnhiddenProportionalPositionInsideWorkspaceRect != nil
    }

    override func getAxSize() async throws -> CGSize? {
        try await macApp.getAxSize(windowId)
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        macApp.setAxFrame(windowId, topLeft, size)
    }

    func setAxFrameBlocking(_ topLeft: CGPoint?, _ size: CGSize?) async throws {
        try await macApp.setAxFrameBlocking(windowId, topLeft, size)
    }

    override func getAxRect() async throws -> Rect? {
        try await macApp.getAxRect(windowId)
    }
}

extension Window {
    @MainActor
    func relayoutWindow(on workspace: Workspace, forceTile: Bool = false) async throws {
        let data = forceTile
            ? unbindAndGetBindingDataForNewTilingWindow(workspace, window: self)
            : try await unbindAndGetBindingDataForNewWindow(self.asMacWindow().windowId, self.asMacWindow().macApp, workspace, window: self)
        bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
@MainActor
private func unbindAndGetBindingDataForNewWindow(_ windowId: UInt32, _ macApp: MacApp, _ workspace: Workspace, window: Window?) async throws -> BindingData {
    let windowLevel = getWindowLevel(for: windowId)
    return switch try await macApp.getAxUiElementWindowType(windowId, windowLevel) {
        case .popup: BindingData(parent: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .dialog: BindingData(parent: workspace, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .window: unbindAndGetBindingDataForNewTilingWindow(workspace, window: window)
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
@MainActor
private func unbindAndGetBindingDataForNewTilingWindow(_ workspace: Workspace, window: Window?) -> BindingData {
    window?.unbindFromParent() // It's important to unbind to get correct data from below
    let mruWindow = workspace.mostRecentWindowRecursive
    if let mruWindow, let tilingParent = mruWindow.parent as? TilingContainer {
        return BindingData(
            parent: tilingParent,
            adaptiveWeight: WEIGHT_AUTO,
            index: mruWindow.ownIndex.orDie() + 1,
        )
    } else {
        return BindingData(
            parent: workspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: INDEX_BIND_LAST,
        )
    }
}

@MainActor
func tryOnWindowDetected(_ window: Window, beforeCallbacks: @MainActor () async throws -> Void = {}, progress: WindowDetectionProgress = WindowDetectionProgress(), callbacks: [WindowDetectedCallback]? = nil) async throws {
    guard let parent = window.parent else { return }
    switch parent.cases {
        case .tilingContainer, .workspace, .macosMinimizedWindowsContainer,
             .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            try await onWindowDetected(window, beforeCallbacks: beforeCallbacks, progress: progress, callbacks: callbacks ?? config.onWindowDetected)
        case .macosPopupWindowsContainer:
            break
    }
}

@MainActor
private func onWindowDetected(_ window: Window, beforeCallbacks: @MainActor () async throws -> Void, progress: WindowDetectionProgress, callbacks: [WindowDetectedCallback]) async throws {
    if !progress.eventBroadcast {
        progress.eventBroadcast = true
        broadcastEvent(.windowDetected(
            windowId: window.windowId,
            workspace: window.nodeWorkspace?.name,
            appBundleId: window.app.rawAppBundleId,
            appName: window.app.name,
        ))
    }
    guard config.enableWindowManagement else { return }
    try await progress.run(
        callbacks: callbacks,
        matches: { try await $0.matches(window) },
        beforeCallbacks: beforeCallbacks,
        checkFurther: { $0.checkFurtherCallbacks },
        command: { callback in
            let event: RefreshSessionEvent = isStartup ? .startup : .onWindowDetected
            _ = try await $refreshSessionEvent.withValue(event) {
                try await callback.run.runCmdSeq(.defaultEnv.copy(\.windowId, window.windowId), .emptyStdin)
            }
        },
    )
}

extension WindowDetectedCallback {
    @MainActor
    func matches(_ window: Window) async throws -> Bool {
        if let startupMatcher = matcher.duringAirlockStartup, startupMatcher != isStartup {
            return false
        }
        if let regex = matcher.windowTitleRegexSubstring, !(try await window.title).contains(regex) {
            return false
        }
        if let appId = matcher.appId, appId != window.app.rawAppBundleId {
            return false
        }
        if let regex = matcher.appNameRegexSubstring, !(window.app.name ?? "").contains(regex) {
            return false
        }
        if let workspace = matcher.workspace, workspace != window.nodeWorkspace?.name {
            return false
        }
        return true
    }
}

/// Check after metadata/title awaits and immediately before admitting configured commands.
/// Commands already admitted are not rolled back if focus changes while they run.
@MainActor
func runAdmittedWindowDetectionCallback(beforeCallbacks: @MainActor () async throws -> Void, onAdmission: @MainActor () -> Void = {}, run: @MainActor () async throws -> Void) async throws {
    try await beforeCallbacks()
    onAdmission()
    try await run()
}

/// A rejected admission remains pending on the cached model. Advance before running commands so
/// an admitted rule (even one that throws after changing windows) is never replayed on retry.
@MainActor
final class WindowDetectionProgress {
    var nextCallback = 0
    var eventBroadcast = false
    var finished = false
    private(set) var running = false

    func run<Callback>(callbacks: [Callback], matches: @MainActor (Callback) async throws -> Bool,
                       beforeCallbacks: @MainActor () async throws -> Void, checkFurther: @MainActor (Callback) -> Bool,
                       command: @MainActor (Callback) async throws -> Void) async throws
    {
        guard !finished, !running else { return }
        running = true
        defer { running = false }
        while nextCallback < callbacks.count {
            let callback = callbacks[nextCallback]
            guard try await matches(callback) else { nextCallback += 1; continue }
            try await runAdmittedWindowDetectionCallback(beforeCallbacks: beforeCallbacks, onAdmission: {
                self.nextCallback = checkFurther(callback) ? self.nextCallback + 1 : callbacks.count
            }, run: { try await command(callback) })
        }
        finished = true
    }
}
