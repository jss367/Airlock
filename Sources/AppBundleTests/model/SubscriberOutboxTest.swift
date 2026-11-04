@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class SubscriberOutboxTest: XCTestCase {
    func testStalledSubscriberDoesNotBlockOthers() async {
        let stalled = StalledSend()
        let stalledOutbox = SubscriberOutbox(send: stalled.send, onClose: {})
        var received: [String] = []
        let healthyOutbox = SubscriberOutbox(send: { received.append(modeOf($0)); return true }, onClose: {})

        let modes = ["a", "b", "c"]
        for mode in modes {
            stalledOutbox.enqueue(.modeChanged(mode: mode))
            healthyOutbox.enqueue(.modeChanged(mode: mode))
        }
        await waitUntil { received.count == modes.count }
        assertEquals(received, modes)
        assertEquals(stalled.sent, ["a"])
        stalled.isStalled = false
        stalled.resumeAll()
        await waitUntil { stalled.sent.count == modes.count }
    }

    func testEventsAreDeliveredInOrderAfterStall() async {
        let stalled = StalledSend()
        let outbox = SubscriberOutbox(send: stalled.send, onClose: {})
        let modes = ["a", "b", "c", "d", "e"]
        for mode in modes { outbox.enqueue(.modeChanged(mode: mode)) }
        await waitUntil { stalled.sent.count == 1 }
        stalled.isStalled = false
        stalled.resumeAll()
        await waitUntil { stalled.sent.count == modes.count }
        assertEquals(stalled.sent, modes)
        XCTAssertFalse(outbox.isClosed)
    }

    func testBacklogOverflowClosesSubscriber() async {
        let stalled = StalledSend()
        var closeCount = 0
        let outbox = SubscriberOutbox(backlogLimit: 2, send: stalled.send, onClose: { closeCount += 1 })
        outbox.enqueue(.modeChanged(mode: "in-flight"))
        await waitUntil { stalled.sent.count == 1 }
        outbox.enqueue(.modeChanged(mode: "queued1"))
        outbox.enqueue(.modeChanged(mode: "queued2"))
        XCTAssertFalse(outbox.isClosed)
        outbox.enqueue(.modeChanged(mode: "overflow"))
        XCTAssertTrue(outbox.isClosed)
        assertEquals(closeCount, 1)

        // Queued events are dropped once closed, even after the stuck write returns
        stalled.isStalled = false
        stalled.resumeAll()
        outbox.enqueue(.modeChanged(mode: "late"))
        for _ in 0 ..< 10 { await Task.yield() }
        assertEquals(stalled.sent, ["in-flight"])
        assertEquals(closeCount, 1)
    }

    func testWriteErrorClosesSubscriber() async {
        var closeCount = 0
        var attempts = 0
        let outbox = SubscriberOutbox(send: { _ in attempts += 1; return false }, onClose: { closeCount += 1 })
        outbox.enqueue(.modeChanged(mode: "a"))
        outbox.enqueue(.modeChanged(mode: "b"))
        await waitUntil { outbox.isClosed }
        assertEquals(attempts, 1)
        assertEquals(closeCount, 1)
    }

    func testInitialSnapshotDoesNotReceiveBroadcastFromBeforeRegistration() async {
        var received: [String] = []
        broadcastEvent(.modeChanged(mode: "before-subscription"))
        let outbox = SubscriberOutbox(send: { received.append(modeOf($0)); return true }, onClose: {})
        let id = registerSubscriber(outbox, events: [.modeChanged])
        defer { removeSubscriber(id); outbox.close() }
        // Registration and initial snapshot enqueue are synchronous, as in handleSubscribeAndWaitTillError.
        outbox.enqueue(.modeChanged(mode: "initial-snapshot"))
        broadcastEvent(.modeChanged(mode: "after-subscription"))
        await waitUntil { received.contains("after-subscription") }
        assertEquals(received, ["initial-snapshot", "after-subscription"])
    }

    func testCloseBeforeDrainDropsEventsAndClosesOnce() async {
        var attempts = 0
        var closeCount = 0
        let outbox = SubscriberOutbox(send: { _ in attempts += 1; return true }, onClose: { closeCount += 1 })
        outbox.enqueue(.modeChanged(mode: "queued"))
        outbox.close()
        outbox.close()
        outbox.enqueue(.modeChanged(mode: "late"))
        for _ in 0 ..< 10 { await Task.yield() }
        assertEquals(attempts, 0)
        assertEquals(closeCount, 1)
    }

    func testCloseUnblocksPendingSendAndReleasesOutbox() async {
        let stalled = StalledSend()
        var closeCount = 0
        var outbox: SubscriberOutbox? = SubscriberOutbox(send: stalled.send, onClose: {
            closeCount += 1
            stalled.resumeAll(success: false)
        })
        weak var weakOutbox = outbox
        outbox?.enqueue(.modeChanged(mode: "in-flight"))
        outbox?.enqueue(.modeChanged(mode: "queued"))
        await waitUntil { stalled.sent.count == 1 }
        outbox?.close()
        outbox = nil
        await waitUntil { weakOutbox == nil }
        assertEquals(stalled.sent, ["in-flight"])
        assertEquals(closeCount, 1)
    }

    func testDelayedWriteFailureDropsQueuedEventsAndReleasesOutbox() async {
        let stalled = StalledSend()
        var closeCount = 0
        var outbox: SubscriberOutbox? = SubscriberOutbox(send: stalled.send, onClose: { closeCount += 1 })
        weak var weakOutbox = outbox
        outbox?.enqueue(.modeChanged(mode: "in-flight"))
        outbox?.enqueue(.modeChanged(mode: "queued"))
        await waitUntil { stalled.sent.count == 1 }
        stalled.resumeAll(success: false)
        await waitUntil { outbox?.isClosed == true }
        outbox?.enqueue(.modeChanged(mode: "late"))
        outbox = nil
        await waitUntil { weakOutbox == nil }
        assertEquals(stalled.sent, ["in-flight"])
        assertEquals(closeCount, 1)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was never met")
    }
}

private func modeOf(_ event: ServerEvent) -> String {
    let json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as! [String: Any]
    return json["mode"] as! String
}

/// Stands in for a client that stopped reading: writes don't complete until resumed.
@MainActor
private final class StalledSend {
    var sent: [String] = []
    var isStalled = true
    private var pending: [CheckedContinuation<Bool, Never>] = []

    func send(_ event: ServerEvent) async -> Bool {
        sent.append(modeOf(event))
        guard isStalled else { return true }
        return await withCheckedContinuation { pending.append($0) }
    }

    func resumeAll(success: Bool = true) {
        let toResume = pending
        pending.removeAll()
        for cont in toResume { cont.resume(returning: success) }
    }
}
