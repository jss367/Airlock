@testable import AppBundle
import XCTest

@MainActor final class UiResumePendingDetectionTest: XCTestCase {
    func testCachedLookupRetriesNeverAdmittedRulesExactlyOnce() async throws {
        let cache = FakeDetectionCache()
        var admitted = false
        var commands: [Int] = []
        func lookup() async throws {
            let progress = cache.getOrInsert(1)
            try await progress.run(callbacks: [0], matches: { _ in true }, beforeCallbacks: {
                if !admitted { throw UiResumeFocusError.focusKeptChanging }
            }, checkFurther: { _ in true }, command: { commands.append($0) })
        }
        do { try await lookup() } catch UiResumeFocusError.focusKeptChanging {}
        XCTAssertEqual(commands, [])
        let retained = cache.getOrInsert(1)
        XCTAssertEqual(retained.nextCallback, 0)
        admitted = true
        try await lookup()
        try await lookup()
        XCTAssertTrue(cache.getOrInsert(1) === retained)
        XCTAssertEqual(commands, [0])
    }

    func testRetryDoesNotReplayAdmittedRulesAfterLaterAdmissionRejects() async throws {
        let progress = WindowDetectionProgress()
        var checks = 0
        var commands: [Int] = []
        do {
            try await progress.run(callbacks: [0, 1], matches: { _ in true }, beforeCallbacks: {
                checks += 1
                if checks == 2 { throw UiResumeFocusError.focusKeptChanging }
            }, checkFurther: { _ in true }, command: { commands.append($0) })
            XCTFail("Second admission must reject")
        } catch UiResumeFocusError.focusKeptChanging {}
        XCTAssertEqual(commands, [0])
        XCTAssertEqual(progress.nextCallback, 1)
        try await progress.run(callbacks: [0, 1], matches: { _ in true }, beforeCallbacks: {}, checkFurther: { _ in true }, command: { commands.append($0) })
        XCTAssertEqual(commands, [0, 1])
    }

    func testThrowingAdmittedContinuingRuleRetriesOnlyTheFollowingRule() async throws {
        let progress = WindowDetectionProgress()
        var commands: [Int] = []
        do {
            try await progress.run(callbacks: [0, 1], matches: { _ in true }, beforeCallbacks: {}, checkFurther: { _ in true }, command: {
                commands.append($0)
                throw CancellationError()
            })
        } catch is CancellationError {}
        try await progress.run(callbacks: [0, 1], matches: { _ in true }, beforeCallbacks: {}, checkFurther: { _ in true }, command: { commands.append($0) })
        XCTAssertEqual(commands, [0, 1])
    }

    func testCancellationDuringMetadataMatchKeepsThatRulePending() async throws {
        let progress = WindowDetectionProgress()
        var commands = 0
        do {
            try await progress.run(callbacks: [0], matches: { _ in
                await Task.yield()
                throw CancellationError()
            }, beforeCallbacks: {}, checkFurther: { _ in true }, command: { _ in commands += 1 })
        } catch is CancellationError {}
        XCTAssertEqual(progress.nextCallback, 0)
        try await progress.run(callbacks: [0], matches: { _ in true }, beforeCallbacks: {}, checkFurther: { _ in true }, command: { _ in commands += 1 })
        XCTAssertEqual(commands, 1)
    }

    func testThrowingAdmittedStopRuleCannotReplayOrRunFurtherRules() async throws {
        let progress = WindowDetectionProgress()
        var commands: [Int] = []
        do {
            try await progress.run(callbacks: [0, 1], matches: { _ in true }, beforeCallbacks: {}, checkFurther: { _ in false }, command: {
                commands.append($0)
                throw CancellationError()
            })
        } catch is CancellationError {}
        try await progress.run(callbacks: [0, 1], matches: { _ in true }, beforeCallbacks: {}, checkFurther: { _ in true }, command: { commands.append($0) })
        XCTAssertEqual(commands, [0])
        XCTAssertTrue(progress.finished)
    }

    func testReentrantCachedLookupCannotDuplicateAdmittedCommands() async throws {
        let progress = WindowDetectionProgress()
        var commands: [Int] = []
        try await progress.run(callbacks: [0, 1], matches: { _ in true }, beforeCallbacks: {}, checkFurther: { _ in true }, command: { id in
            commands.append(id)
            try await progress.run(callbacks: [0, 1], matches: { _ in true }, beforeCallbacks: {}, checkFurther: { _ in true }, command: { commands.append($0) })
        })
        XCTAssertEqual(commands, [0, 1])
    }
}

@MainActor private final class FakeDetectionCache {
    private var models: [Int: WindowDetectionProgress] = [:]
    func getOrInsert(_ id: Int) -> WindowDetectionProgress {
        if let existing = models[id] { return existing }
        let inserted = WindowDetectionProgress()
        models[id] = inserted
        return inserted
    }
}
