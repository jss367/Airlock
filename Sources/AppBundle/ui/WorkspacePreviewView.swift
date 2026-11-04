import AppKit
import Common
import SwiftUI

struct WorkspacePreviewView: View {
    let workspaceName: String
    @State private var preview: NSImage?

    var body: some View {
        Group {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 300, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1),
                    )
            } else {
                Text("Empty workspace")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(width: 200, height: 50)
            }
        }
        .task(id: workspaceName) { await capturePreview() }
    }

    @MainActor
    private func capturePreview() async {
        let workspace = Workspace.get(byName: workspaceName)
        let windows = workspace.allLeafWindowsRecursive

        if windows.isEmpty {
            preview = nil
            return
        }

        let windowsById = Dictionary(windows.map { (CGWindowID($0.windowId), $0) }, uniquingKeysWith: { first, _ in first })

        let images = await captureWindowImages(windowIds: Set(windowsById.keys))
        guard !Task.isCancelled else { return }

        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[CFString: Any]] else {
            return
        }

        // Windows of hidden workspaces all sit parked in one corner, so draw them where they'll be when shown
        let unhiddenRect = { (wid: CGWindowID, size: CGSize) -> CGRect? in
            guard let unhidden = (windowsById[wid] as? MacWindow)?.rectWhenUnhidden(currentSize: size) else { return nil }
            return CGRect(x: unhidden.topLeftX, y: unhidden.topLeftY, width: unhidden.width, height: unhidden.height)
        }
        guard let layout = Self.previewLayout(
            windowInfoList: windowInfoList,
            windowIds: Set(windowsById.keys),
            unhiddenRect: unhiddenRect,
        ) else {
            preview = nil
            return
        }
        let captureRect = layout.captureRect

        // Capture each window individually and composite them
        let scale: CGFloat = 0.5
        let scaledSize = NSSize(width: captureRect.width * scale, height: captureRect.height * scale)
        let composited = NSImage(size: scaledSize)
        composited.lockFocus()

        // Draw background
        NSColor.windowBackgroundColor.withAlphaComponent(0.3).setFill()
        NSBezierPath.fill(NSRect(origin: .zero, size: scaledSize))

        for (wid, rect) in layout.windows {
            if let cgImage = images[wid] {
                let destRect = NSRect(
                    x: (rect.minX - captureRect.minX) * scale,
                    y: (captureRect.height - (rect.minY - captureRect.minY) - rect.height) * scale, // Flip Y
                    width: rect.width * scale,
                    height: rect.height * scale,
                )
                let nsImage = NSImage(cgImage: cgImage, size: rect.size)
                nsImage.draw(in: destRect)
            }
        }

        composited.unlockFocus()
        preview = composited
    }

    /// Where each window goes in the composite, and the rect bounding all of them.
    /// `unhiddenRect` overrides the reported bounds for windows parked in the corner by a hidden workspace.
    static func previewLayout(
        windowInfoList: [[CFString: Any]],
        windowIds: Set<CGWindowID>,
        unhiddenRect: (CGWindowID, CGSize) -> CGRect?,
    ) -> (captureRect: CGRect, windows: [(wid: CGWindowID, rect: CGRect)])? {
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        var foundWindows: [(wid: CGWindowID, rect: CGRect)] = []

        for info in windowInfoList {
            guard let windowNumber = info[kCGWindowNumber] as? NSNumber else { continue }
            let wid = CGWindowID(windowNumber.uint32Value)
            guard windowIds.contains(wid) else { continue }

            if let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
               let x = boundsDict["X"], let y = boundsDict["Y"],
               let w = boundsDict["Width"], let h = boundsDict["Height"]
            {
                var rect = CGRect(x: x, y: y, width: w, height: h)
                if let unhidden = unhiddenRect(wid, rect.size) { rect = unhidden }
                minX = min(minX, rect.minX)
                minY = min(minY, rect.minY)
                maxX = max(maxX, rect.maxX)
                maxY = max(maxY, rect.maxY)
                foundWindows.append((wid, rect))
            }
        }

        guard !foundWindows.isEmpty else { return nil }
        return (CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), foundWindows)
    }
}
