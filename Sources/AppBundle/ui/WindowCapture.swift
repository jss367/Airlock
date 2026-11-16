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

/// Capture windows in the given order, handing over each image as soon as it's ready.
/// Stops early when the task is cancelled.
///
/// A desktop-independent window filter captures only that window's own content, not the screen
/// region it occupies. Windows parked off screen in a corner come out whole, and a panel shown
/// above the windows (the app switcher, the workspace overview) is not part of the image.
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

/// Leads to the Screen Recording permission that window previews need. Cmd+Tab and the workspace
/// overview never ask for it themselves, so this is the one place Airlock does.
@MainActor
func openScreenRecordingSettings() {
    // The first request shows the system prompt and adds Airlock to the Screen Recording list.
    // macOS shows that prompt only once, so the list is opened as well.
    if CGRequestScreenCaptureAccess() { return }
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
        NSWorkspace.shared.open(url)
    }
}
