import AppKit
import Common
import SwiftUI

@MainActor private var missionControlPanel: MissionControlPanel?

@MainActor
func toggleMissionControl() {
    if let panel = missionControlPanel, panel.isVisible {
        dismissMissionControl()
    } else {
        // Capture all thumbnails BEFORE showing the overlay panel,
        // otherwise the panel occludes windows and captures come back blank
        let data = MissionControlContent.captureAllWorkspaces()

        let panel = MissionControlPanel(preloadedData: data)
        missionControlPanel = panel
        panel.show()
    }
}

@MainActor
func dismissMissionControl() {
    missionControlPanel?.close()
    missionControlPanel = nil
}

private class MissionControlPanel: NSPanelHud {
    private var hostingView: NSHostingView<MissionControlContent>?

    init(preloadedData: [MissionControlContent.WorkspaceInfo]) {
        super.init()
        let content = MissionControlContent(preloadedData: preloadedData)
        let hosting = NSHostingView(rootView: content)
        self.contentView = hosting
        self.hostingView = hosting

        if let screen = NSScreen.main {
            self.setFrame(screen.frame, display: true)
        }

        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
    }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MissionControlContent: View {
    let preloadedData: [WorkspaceInfo]
    @State private var selectedWorkspaceIndex: Int = 0
    @State private var keyMonitor: Any?
    @State private var isVisible: Bool = false

    struct WorkspaceInfo: Identifiable {
        let id: String
        let name: String
        let isFocused: Bool
        let windows: [WindowInfo]
        let compositeThumbnail: NSImage?
    }

    struct WindowInfo: Identifiable {
        let id: UInt32
        let appName: String
        let thumbnail: NSImage?
        let windowId: UInt32
    }

    var body: some View {
        ZStack {
            // Translucent blur background like Mission Control
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // Workspace bar at top
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(Array(preloadedData.enumerated()), id: \.element.id) { index, ws in
                            WorkspaceCard(workspace: ws, isSelected: index == selectedWorkspaceIndex)
                                .onTapGesture { switchToWorkspace(ws) }
                        }
                    }
                    .padding(.horizontal, 40)
                }
                .padding(.top, 40)

                // Window grid area
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 350), spacing: 16)], spacing: 16) {
                        ForEach(preloadedData) { ws in
                            Section {
                                ForEach(ws.windows) { window in
                                    WindowThumbnail(window: window)
                                        .onTapGesture { focusWindow(window) }
                                }
                            } header: {
                                if preloadedData.count > 1 {
                                    HStack {
                                        Text(ws.name)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(ws.isFocused ? .primary : .secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.top, 8)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                }

                Spacer()
            }
            .scaleEffect(isVisible ? 1.0 : 0.95)
            .opacity(isVisible ? 1.0 : 0.0)
        }
        .onAppear {
            // Select the focused workspace
            if let focusedIndex = preloadedData.firstIndex(where: { $0.isFocused }) {
                selectedWorkspaceIndex = focusedIndex
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                return handleKeyEvent(event) ? nil : event
            }
            withAnimation(.easeOut(duration: 0.2)) {
                isVisible = true
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Hyper+A (ctrl+option+shift+cmd + A) toggles off
        let hyperMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == hyperMask
            && event.keyCode == 0 /* 'a' */
        {
            Task { @MainActor in dismissMissionControl() }
            return true
        }

        switch event.keyCode {
        case 53: // Escape
            Task { @MainActor in dismissMissionControl() }
            return true
        case 123: // Left arrow
            if selectedWorkspaceIndex > 0 { selectedWorkspaceIndex -= 1 }
            return true
        case 124: // Right arrow
            if selectedWorkspaceIndex < preloadedData.count - 1 { selectedWorkspaceIndex += 1 }
            return true
        case 36: // Return
            if let ws = preloadedData[safe: selectedWorkspaceIndex] {
                switchToWorkspace(ws)
            }
            return true
        default:
            return false
        }
    }

    @MainActor
    static func captureAllWorkspaces() -> [WorkspaceInfo] {
        let persistentOrder = config.persistentWorkspaces
        let workspaces = Workspace.all.sorted { a, b in
            let ai = persistentOrder.firstIndex(of: a.name)
            let bi = persistentOrder.firstIndex(of: b.name)
            switch (ai, bi) {
            case (.some(let ai), .some(let bi)): return ai < bi
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a < b
            }
        }

        let focusedWorkspaceName = focus.workspace.name
        let windowInfoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[CFString: Any]] ?? []

        var result: [WorkspaceInfo] = []
        for ws in workspaces {
            let leafWindows = ws.allLeafWindowsRecursive
            let isFocused = ws.name == focusedWorkspaceName

            var windowInfos: [WindowInfo] = []
            for window in leafWindows {
                let wid = CGWindowID(window.windowId)
                let thumbnail = captureWindowThumbnail(wid: wid, maxWidth: 350)
                windowInfos.append(WindowInfo(
                    id: window.windowId,
                    appName: window.app.name ?? "Unknown",
                    thumbnail: thumbnail,
                    windowId: window.windowId
                ))
            }

            let windowIds = Set(leafWindows.map { CGWindowID($0.windowId) })
            let compositeThumbnail = captureWorkspaceComposite(
                windowIds: windowIds,
                windowInfoList: windowInfoList
            )

            result.append(WorkspaceInfo(
                id: ws.name,
                name: ws.name,
                isFocused: isFocused,
                windows: windowInfos,
                compositeThumbnail: compositeThumbnail
            ))
        }

        return result
    }

    private static func captureWindowThumbnail(wid: CGWindowID, maxWidth: CGFloat) -> NSImage? {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            wid,
            [.boundsIgnoreFraming, .bestResolution]
        ) else { return nil }

        let srcWidth = CGFloat(cgImage.width)
        let srcHeight = CGFloat(cgImage.height)
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        let scale = min(1.0, maxWidth / srcWidth)
        let destSize = NSSize(width: srcWidth * scale, height: srcHeight * scale)
        let scaled = NSImage(size: destSize)
        scaled.lockFocus()
        let src = NSImage(cgImage: cgImage, size: NSSize(width: srcWidth, height: srcHeight))
        src.draw(in: NSRect(origin: .zero, size: destSize))
        scaled.unlockFocus()
        return scaled
    }

    private static func captureWorkspaceComposite(
        windowIds: Set<CGWindowID>,
        windowInfoList: [[CFString: Any]]
    ) -> NSImage? {
        if windowIds.isEmpty { return nil }

        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        var foundWindows: [CGWindowID] = []

        for info in windowInfoList {
            guard let windowNumber = info[kCGWindowNumber] as? NSNumber else { continue }
            let wid = CGWindowID(windowNumber.uint32Value)
            guard windowIds.contains(wid) else { continue }

            if let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
               let x = boundsDict["X"], let y = boundsDict["Y"],
               let w = boundsDict["Width"], let h = boundsDict["Height"]
            {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x + w)
                maxY = max(maxY, y + h)
                foundWindows.append(wid)
            }
        }

        guard !foundWindows.isEmpty else { return nil }

        let captureRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let scale: CGFloat = 0.3
        let scaledSize = NSSize(width: captureRect.width * scale, height: captureRect.height * scale)
        let composited = NSImage(size: scaledSize)
        composited.lockFocus()

        NSColor.windowBackgroundColor.withAlphaComponent(0.3).setFill()
        NSBezierPath.fill(NSRect(origin: .zero, size: scaledSize))

        for wid in foundWindows {
            if let cgImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                wid,
                [.boundsIgnoreFraming, .bestResolution]
            ) {
                if let info = windowInfoList.first(where: {
                    ($0[kCGWindowNumber] as? NSNumber)?.uint32Value == wid
                }),
                   let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
                   let x = boundsDict["X"], let y = boundsDict["Y"],
                   let w = boundsDict["Width"], let h = boundsDict["Height"]
                {
                    let destRect = NSRect(
                        x: (x - minX) * scale,
                        y: (captureRect.height - (y - minY) - h) * scale,
                        width: w * scale,
                        height: h * scale
                    )
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: w, height: h))
                    nsImage.draw(in: destRect)
                }
            }
        }

        composited.unlockFocus()
        return composited
    }

    @MainActor
    private func switchToWorkspace(_ ws: WorkspaceInfo) {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task {
            try await runLightSession(.menuBarButton, token) {
                _ = Workspace.get(byName: ws.name).focusWorkspace()
            }
            dismissMissionControl()
        }
    }

    @MainActor
    private func focusWindow(_ window: WindowInfo) {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task {
            try await runLightSession(.menuBarButton, token) {
                if let w = Window.get(byId: window.windowId) {
                    _ = w.focusWindow()
                }
            }
            dismissMissionControl()
        }
    }
}

private struct WorkspaceCard: View {
    let workspace: MissionControlContent.WorkspaceInfo
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Thumbnail
            if let thumb = workspace.compositeThumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 180, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 180, height: 110)
                    .overlay(
                        Text("Empty")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    )
            }

            // Workspace name
            Text(workspace.name)
                .font(.system(size: 13, weight: workspace.isFocused ? .bold : .medium))
                .foregroundStyle(.primary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(workspace.isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
}

private struct WindowThumbnail: View {
    let window: MissionControlContent.WindowInfo

    var body: some View {
        VStack(spacing: 0) {
            if let thumb = window.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(height: 150)
            }
            Text(window.appName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 6)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }
}
