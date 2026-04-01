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
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            } else {
                Text("Empty workspace")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(width: 200, height: 50)
            }
        }
        .onAppear { capturePreview() }
    }

    @MainActor
    private func capturePreview() {
        let workspace = Workspace.get(byName: workspaceName)
        let windows = workspace.allLeafWindowsRecursive

        if windows.isEmpty {
            preview = nil
            return
        }

        // Get window IDs for this workspace
        let windowIds = windows.map { CGWindowID($0.windowId) }

        // Use CGWindowListCreateImage to capture all windows on this workspace
        // We need to find the bounding rect of all windows
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[CFString: Any]] else {
            return
        }

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

        guard !foundWindows.isEmpty else {
            preview = nil
            return
        }

        let captureRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // Capture each window individually and composite them
        let scale: CGFloat = 0.5
        let scaledSize = NSSize(width: captureRect.width * scale, height: captureRect.height * scale)
        let composited = NSImage(size: scaledSize)
        composited.lockFocus()

        // Draw background
        NSColor.windowBackgroundColor.withAlphaComponent(0.3).setFill()
        NSBezierPath.fill(NSRect(origin: .zero, size: scaledSize))

        for wid in foundWindows {
            if let cgImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                wid,
                [.boundsIgnoreFraming, .bestResolution]
            ) {
                // Get this window's bounds to position it correctly
                if let info = windowInfoList.first(where: {
                    ($0[kCGWindowNumber] as? NSNumber)?.uint32Value == wid
                }),
                   let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
                   let x = boundsDict["X"], let y = boundsDict["Y"],
                   let w = boundsDict["Width"], let h = boundsDict["Height"]
                {
                    let destRect = NSRect(
                        x: (x - minX) * scale,
                        y: (captureRect.height - (y - minY) - h) * scale, // Flip Y
                        width: w * scale,
                        height: h * scale
                    )
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: w, height: h))
                    nsImage.draw(in: destRect)
                }
            }
        }

        composited.unlockFocus()
        preview = composited
    }
}
