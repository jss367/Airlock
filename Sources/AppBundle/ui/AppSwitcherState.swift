import AppKit
import Combine
import Common

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

// MARK: - Observable State

@MainActor
final class AppSwitcherState: ObservableObject {
    @Published var groups: [AppGroup]
    @Published var selectedAppIndex: Int
    @Published var selectedWindowIndex: Int = 0
    @Published var thumbnails: [UInt32: CGImage]
    private let actionQueue: AppSwitcherActionQueue

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
        actionQueue: AppSwitcherActionQueue = AppSwitcherActionQueue(),
    ) {
        self.groups = groups
        self.selectedAppIndex = selectedAppIndex
        self.thumbnails = thumbnails
        self.pointerLocation = pointerLocation
        self.pointerAnchor = pointerLocation()
        self.actionQueue = actionQueue
        actionQueue.register(self)
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

    /// Reserve a logical selection without hiding entries before their close is admitted.
    /// Repeated distinct presses advance through the list as if pending closes had succeeded.
    func reserveWindowForClose() -> UInt32? {
        let available = groups.enumerated().compactMap { index, group -> (Int, [AppGroupWindow])? in
            if actionQueue.pendingQuitPids.contains(group.pid) { return nil }
            let windows = group.windows.filter { !actionQueue.pendingCloseWindowIds.contains($0.windowId) }
            return windows.isEmpty ? nil : (index, windows)
        }
        guard !available.isEmpty else { return nil }
        let removedBeforeApp = groups.indices.prefix(selectedAppIndex).count(where: { index in
            isPendingRemoval(groups[index])
        })
        let appIndex = min(selectedAppIndex - removedBeforeApp, available.count - 1)
        let (originalIndex, windows) = available[appIndex]
        let removedBeforeWindow = groups[originalIndex].windows.prefix(selectedWindowIndex).count(where: {
            actionQueue.pendingCloseWindowIds.contains($0.windowId)
        })
        let windowIndex = originalIndex == selectedAppIndex
            ? min(selectedWindowIndex - removedBeforeWindow, windows.count - 1)
            : 0
        let windowId = windows[windowIndex].windowId
        actionQueue.pendingCloseWindowIds.insert(windowId)
        return windowId
    }

    func finishClosingWindow(_ windowId: UInt32) {
        actionQueue.pendingCloseWindowIds.remove(windowId)
    }

    /// Keep the target visible until its close is confirmed. A rejected or failed close leaves it intact.
    func closeWindowAfterConfirmation(windowId: UInt32, operation: () async throws -> Bool) async throws -> Bool {
        guard try await operation() else { return false }
        actionQueue.didCloseWindow(windowId)
        return true
    }

    /// Drop the window from the list. An app left without windows goes too
    fileprivate func removeWindow(windowId: UInt32) {
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

    private func isPendingRemoval(_ group: AppGroup) -> Bool {
        actionQueue.pendingQuitPids.contains(group.pid) || group.windows.allSatisfy { actionQueue.pendingCloseWindowIds.contains($0.windowId) }
    }

    /// Reserve each queued quit independently while keeping failed targets in the visible list.
    func reserveAppForQuit() -> Int32? {
        let available = groups.filter { !isPendingRemoval($0) }
        guard !available.isEmpty else { return nil }
        let removedBeforeSelection = groups.prefix(selectedAppIndex).count(where: { isPendingRemoval($0) })
        let index = min(selectedAppIndex - removedBeforeSelection, available.count - 1)
        let pid = available[index].pid
        actionQueue.pendingQuitPids.insert(pid)
        return pid
    }

    func finishQuittingApp(_ pid: Int32) {
        actionQueue.pendingQuitPids.remove(pid)
    }

    /// Keep the target visible until its quit request succeeds, even if selection changed while waiting.
    func quitApp(pid: Int32, requestQuit: () -> Bool) -> Bool {
        guard groups.contains(where: { $0.pid == pid }), requestQuit() else { return false }
        actionQueue.didQuitApp(pid)
        return true
    }

    fileprivate func removeApp(pid: Int32) {
        guard let index = groups.firstIndex(where: { $0.pid == pid }) else { return }
        markKeyboardSelection()
        removeGroup(at: index)
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

// MARK: - Action Queue

/// Close and quit requests run in key-press order, including their asynchronous admission and AX work.
@MainActor
final class AppSwitcherActionQueue {
    private var tail: Task<Void, Never>?
    fileprivate var pendingCloseWindowIds: Set<UInt32> = []
    fileprivate var pendingQuitPids: Set<Int32> = []
    private var states: [WeakState] = []
    /// Runs after a confirmed close or quit has dropped its entry from every registered list
    private let onEntryRemoved: @MainActor () -> Void

    init(onEntryRemoved: @escaping @MainActor () -> Void = {}) {
        self.onEntryRemoved = onEntryRemoved
    }

    private final class WeakState {
        weak var value: AppSwitcherState?
        init(_ value: AppSwitcherState) { self.value = value }
    }

    fileprivate func register(_ state: AppSwitcherState) {
        states.removeAll { $0.value == nil }
        states.append(WeakState(state))
    }

    fileprivate func didCloseWindow(_ windowId: UInt32) {
        for state in states { state.value?.removeWindow(windowId: windowId) }
        onEntryRemoved()
    }

    fileprivate func didQuitApp(_ pid: Int32) {
        for state in states { state.value?.removeApp(pid: pid) }
        onEntryRemoved()
    }

    @discardableResult
    func enqueue(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task {
            await previous?.value
            await body()
        }
        tail = task
        return task
    }
}
