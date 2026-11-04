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
        stalled.resumeAll()
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

    func resumeAll() {
        let toResume = pending
        pending.removeAll()
        for cont in toResume { cont.resume(returning: true) }
    }
}
