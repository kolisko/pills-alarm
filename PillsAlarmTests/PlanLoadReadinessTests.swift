import XCTest
@testable import PillsAlarm

@MainActor
final class PlanLoadReadinessTests: XCTestCase {
    func testReadyPlansDoNotStartOrWaitForAnotherReload() async throws {
        let readiness = PlanLoadReadiness()
        readiness.beginReload()
        try await readiness.ensureReady(isReady: { true }) { XCTFail("Already loaded") }
        XCTAssertEqual(readiness.activeReloadCount, 1)
        readiness.endReload()
    }

    func testColdStartLoadsWhenNothingIsRunning() async throws {
        let readiness = PlanLoadReadiness()
        var ready = false
        var calls = 0
        try await readiness.ensureReady(isReady: { ready }) {
            calls += 1
            readiness.beginReload()
            ready = true
            readiness.endReload()
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(readiness.activeReloadCount, 0)
    }

    func testIntentWaitsForStartupReloadWithoutStartingAnother() async throws {
        let readiness = PlanLoadReadiness()
        readiness.beginReload()
        var ready = false
        var entered = false
        var finished = false
        let intent = Task {
            entered = true
            try await readiness.ensureReady(isReady: { ready }) { XCTFail("Must join the startup load") }
            finished = true
        }
        await waitUntil { entered }
        XCTAssertFalse(finished)
        ready = true
        readiness.endReload()
        try await intent.value
        XCTAssertTrue(finished)
    }

    func testSupersededReloadDoesNotFailWhileNewerLoadIsRunning() async throws {
        let readiness = PlanLoadReadiness()
        readiness.beginReload()
        readiness.beginReload()
        var ready = false
        var entered = false
        var finished = false
        let intent = Task {
            entered = true
            try await readiness.ensureReady(isReady: { ready }) { XCTFail("No third reload") }
            finished = true
        }
        await waitUntil { entered }
        readiness.endReload()
        await Task.yield()
        XCTAssertFalse(finished)
        ready = true
        readiness.endReload()
        try await intent.value
    }

    func testLatestReadyDataDoesNotWaitForOlderSupersededRequest() async throws {
        let readiness = PlanLoadReadiness()
        readiness.beginReload()
        readiness.beginReload()
        var ready = false
        var entered = false
        var finished = false
        let intent = Task {
            entered = true
            try await readiness.ensureReady(isReady: { ready }) { XCTFail("No extra reload") }
            finished = true
        }
        await waitUntil { entered }
        ready = true
        readiness.endReload()
        await waitUntil { finished }
        readiness.endReload()
        try await intent.value
    }

    func testFailedLoadReturnsErrorWithoutRetryLoop() async {
        let readiness = PlanLoadReadiness()
        var calls = 0
        do {
            try await readiness.ensureReady(isReady: { false }) {
                calls += 1
                readiness.beginReload()
                readiness.endReload()
            }
            XCTFail("Must not treat an unavailable account or failed load as ready")
        } catch {
            XCTAssertEqual(error.localizedDescription, AlarmControlError.plansUnavailable.localizedDescription)
        }
        XCTAssertEqual(calls, 1)
    }

    func testJoinedLoadFailureIsReturned() async {
        let readiness = PlanLoadReadiness()
        readiness.beginReload()
        var entered = false
        let intent = Task {
            entered = true
            try await readiness.ensureReady(isReady: { false }) { XCTFail("No retry") }
        }
        await waitUntil { entered }
        readiness.endReload()
        do {
            try await intent.value
            XCTFail("Load failure must reach the intent")
        } catch {
            XCTAssertEqual(error.localizedDescription, AlarmControlError.plansUnavailable.localizedDescription)
        }
    }

    func testCancellingOneWaiterDoesNotCancelLoadOrAnotherWaiter() async throws {
        let readiness = PlanLoadReadiness()
        readiness.beginReload()
        var ready = false
        var entered = 0
        let first = Task {
            entered += 1
            try await readiness.ensureReady(isReady: { ready }) { XCTFail("No reload") }
        }
        let second = Task {
            entered += 1
            try await readiness.ensureReady(isReady: { ready }) { XCTFail("No reload") }
        }
        await waitUntil { entered == 2 }
        first.cancel()
        do {
            try await first.value
            XCTFail("Cancelled waiter must finish without waiting for the network")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(readiness.activeReloadCount, 1)
        ready = true
        readiness.endReload()
        try await second.value
    }

    func testOwnReloadCanBeSupersededAndWaitForTheReplacement() async throws {
        let readiness = PlanLoadReadiness()
        var ready = false
        var started = false
        let intent = Task {
            try await readiness.ensureReady(isReady: { ready }) {
                readiness.beginReload()
                readiness.beginReload()
                readiness.endReload()
                started = true
            }
        }
        await waitUntil { started }
        ready = true
        readiness.endReload()
        try await intent.value
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition())
    }
}
