import Common

public struct ServerEvent: Codable, Sendable {
    private let _event: ServerEventType

    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var windowId: UInt32?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var workspace: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var prevWorkspace: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var monitorId: Int? // 1-based
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var appBundleId: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var appName: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var mode: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var binding: String?
    /// What made focus move: the refresh session event that produced this change. Absent for the
    /// initial state sent on connect, and for events fired outside a refresh session.
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var trigger: String?

    public var eventType: ServerEventType { _event }

    public static func focusChanged(windowId: UInt32?, workspace: String, trigger: String? = nil) -> ServerEvent {
        ServerEvent(_event: .focusChanged, windowId: windowId, workspace: workspace, trigger: trigger)
    }

    public static func focusedMonitorChanged(workspace: String, monitorId_oneBased: Int, trigger: String? = nil) -> ServerEvent {
        ServerEvent(_event: .focusedMonitorChanged, workspace: workspace, monitorId: monitorId_oneBased, trigger: trigger)
    }

    public static func workspaceChanged(workspace: String, prevWorkspace: String, trigger: String? = nil) -> ServerEvent {
        ServerEvent(_event: .workspaceChanged, workspace: workspace, prevWorkspace: prevWorkspace, trigger: trigger)
    }

    public static func modeChanged(mode: String?) -> ServerEvent {
        ServerEvent(_event: .modeChanged, mode: mode)
    }

    public static func windowDetected(windowId: UInt32, workspace: String?, appBundleId: String?, appName: String?) -> ServerEvent {
        ServerEvent(_event: .windowDetected, windowId: windowId, workspace: workspace, appBundleId: appBundleId, appName: appName)
    }

    public static func bindingTriggered(mode: String, binding: String) -> ServerEvent {
        ServerEvent(_event: .bindingTriggered, mode: mode, binding: binding)
    }
}
