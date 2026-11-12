import AppKit
import ScreenCaptureKit

/// The workspace overview's largest thumbnail is 350 points wide; allow 2x pixels without retaining
/// full-resolution Retina screenshots for every window in every workspace.
let defaultThumbnailMaxPixelDimension: CGFloat = 700

func windowThumbnailCaptureSize(
    contentSize: CGSize,
    pointPixelScale: CGFloat,
    maxPixelDimension: CGFloat = defaultThumbnailMaxPixelDimension,
) -> CGSize {
    let width = max(1, contentSize.width * pointPixelScale)
    let height = max(1, contentSize.height * pointPixelScale)
    let scale = min(1, maxPixelDimension / max(width, height))
    return CGSize(width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))
}

/// Capture windows once so individual thumbnails and workspace composites share the same images.
@MainActor
func captureWindowImages(windowIds: Set<CGWindowID>) async -> [CGWindowID: CGImage] {
    var images: [CGWindowID: CGImage] = [:]
    await captureWindowImages(orderedWindowIds: Array(windowIds)) { images[$0] = $1 }
    return Task.isCancelled ? [:] : images
}

/// Capture windows in the given order, handing over each image as soon as it's ready.
/// Stops early when the task is cancelled.
@MainActor
func captureWindowImages(
    orderedWindowIds: [CGWindowID],
    maxPixelDimension: CGFloat = defaultThumbnailMaxPixelDimension,
    onCapture: @MainActor (CGWindowID, CGImage) -> Void,
) async {
    guard !orderedWindowIds.isEmpty, !Task.isCancelled,
          let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    else { return }

    let shareableWindows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
    for windowId in orderedWindowIds {
        guard !Task.isCancelled else { return }
        guard let window = shareableWindows[windowId] else { continue }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let size = windowThumbnailCaptureSize(
            contentSize: filter.contentRect.size,
            pointPixelScale: CGFloat(filter.pointPixelScale),
            maxPixelDimension: maxPixelDimension,
        )
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        // A closed window or denied screen-recording access leaves its thumbnail empty.
        let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        if let image, !Task.isCancelled { onCapture(windowId, image) }
    }
}
