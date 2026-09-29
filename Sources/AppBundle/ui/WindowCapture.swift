import AppKit
import ScreenCaptureKit

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
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int(filter.contentRect.width * scale))
        configuration.height = max(1, Int(filter.contentRect.height * scale))
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
