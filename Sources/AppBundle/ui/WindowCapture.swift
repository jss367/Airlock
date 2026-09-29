import AppKit
import ScreenCaptureKit

func windowThumbnailCaptureSize(contentSize: CGSize, pointPixelScale: CGFloat) -> CGSize {
    let width = max(1, contentSize.width * pointPixelScale)
    let height = max(1, contentSize.height * pointPixelScale)
    // The largest thumbnail is 350 points wide; allow 2x pixels without retaining
    // full-resolution Retina screenshots for every window in every workspace.
    let scale = min(1, 700 / max(width, height))
    return CGSize(width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))
}

/// Capture windows once so individual thumbnails and workspace composites share the same images.
@MainActor
func captureWindowImages(windowIds: Set<CGWindowID>) async -> [CGWindowID: CGImage] {
    guard !windowIds.isEmpty, !Task.isCancelled,
          let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    else { return [:] }

    var images: [CGWindowID: CGImage] = [:]
    for window in content.windows where windowIds.contains(window.windowID) {
        guard !Task.isCancelled else { return [:] }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let size = windowThumbnailCaptureSize(
            contentSize: filter.contentRect.size,
            pointPixelScale: CGFloat(filter.pointPixelScale),
        )
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        // A closed window or denied screen-recording access leaves its thumbnail empty.
        images[window.windowID] = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration,
        )
    }
    return images
}
