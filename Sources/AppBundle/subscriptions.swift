import Common
import Foundation
import Network

private struct Subscriber {
    let outbox: SubscriberOutbox
    let events: Set<ServerEventType>
}

/// Delivers events to one subscriber in order without making other subscribers wait on it.
/// A write only completes once the client reads, so a client that stops reading would otherwise
/// stall every broadcast. Its backlog is capped instead, and overflowing it closes the subscriber.
@MainActor
final class SubscriberOutbox {
    static let defaultBacklogLimit = 1000

    private let backlogLimit: Int
    private let send: @MainActor (ServerEvent) async -> Bool
    private let onClose: @MainActor () -> Void
    private var backlog: [ServerEvent] = []
    private var isDraining = false
    private(set) var isClosed = false

    /// `send` returns false on a write error. `onClose` runs once, on write error or backlog overflow.
    init(
        backlogLimit: Int = defaultBacklogLimit,
        send: @escaping @MainActor (ServerEvent) async -> Bool,
        onClose: @escaping @MainActor () -> Void,
    ) {
        self.backlogLimit = backlogLimit
        self.send = send
        self.onClose = onClose
    }

    func enqueue(_ event: ServerEvent) {
        guard !isClosed else { return }
        guard backlog.count < backlogLimit else {
            close()
            return
        }
        backlog.append(event)
        if !isDraining {
            isDraining = true
            Task { @MainActor in await drain() }
        }
    }

    private func drain() async {
        while !isClosed, !backlog.isEmpty {
            let event = backlog.removeFirst()
            if !(await send(event)) {
                close()
            }
        }
        isDraining = false
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        backlog.removeAll()
        onClose()
    }
}

@MainActor private var subscribers: [UniqueToken: Subscriber] = [:]

@MainActor
func registerSubscriber(_ outbox: SubscriberOutbox, events: Set<ServerEventType>) -> UniqueToken {
    let id = UniqueToken()
    subscribers[id] = Subscriber(outbox: outbox, events: events)
    return id
}

@MainActor
func removeSubscriber(_ id: UniqueToken) {
    subscribers.removeValue(forKey: id)
}

@MainActor
func handleSubscribeAndWaitTillError(_ connection: NWConnection, _ args: SubscribeCmdArgs) async {
    let outbox = SubscriberOutbox(
        send: { await connection.writeAtomic($0, jsonEncoder).error == nil },
        // Cancelling also fails a write stuck on a client that stopped reading, and ends readTillError below
        onClose: { connection.cancel() },
    )
    let id = registerSubscriber(outbox, events: args.events)
    defer {
        removeSubscriber(id)
        outbox.close()
    }
    if args.sendInitial {
        let f = focus
        for eventType in args.events {
            let event: ServerEvent
            switch eventType {
                case .focusChanged:
                    event = .focusChanged(windowId: f.windowOrNil?.windowId, workspace: f.workspace.name)
                case .workspaceChanged:
                    event = .workspaceChanged(workspace: f.workspace.name, prevWorkspace: f.workspace.name)
                case .modeChanged:
                    event = .modeChanged(mode: activeMode)
                case .focusedMonitorChanged:
                    event = .focusedMonitorChanged(
                        workspace: f.workspace.name,
                        monitorId_oneBased: f.workspace.workspaceMonitor.monitorId_oneBased ?? 0,
                    )
                case .windowDetected, .bindingTriggered: continue
            }
            outbox.enqueue(event)
        }
    }

    // Keep connection alive - wait for client to disconnect
    await connection.readTillError()
}

private let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    return e
}()

// Enqueue in the same actor turn as the state change. Deferring registration lookup to a task
// could deliver an older event to a new subscriber after its initial snapshot.
@MainActor
func broadcastEvent(_ event: ServerEvent) {
    for (id, subscriber) in subscribers {
        guard subscriber.events.contains(event.eventType) else { continue }
        subscriber.outbox.enqueue(event)
        if subscriber.outbox.isClosed { removeSubscriber(id) }
    }
}
