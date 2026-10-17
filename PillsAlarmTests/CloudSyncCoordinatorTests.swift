import XCTest
@testable import PillsAlarm

@MainActor
final class CloudSyncCoordinatorTests: XCTestCase {
    func testCompletionWaitsForCloudThenAlarms() async {
        let cloud = SyncGate()
        let alarms = SyncGate()
        let coordinator = CloudSyncCoordinator(
            reloadStore: { _, _, _ in await cloud.wait() },
            waitForAlarms: { await alarms.wait() }
        )
        let store = MedicationStore()
        var completed = false
        coordinator.scheduleReload(store: store, delayNanoseconds: 0) { completed = true }
        await waitUntil { cloud.calls == 1 }
        XCTAssertEqual(alarms.calls, 0)
        XCTAssertFalse(completed)
        cloud.release(0)
        await waitUntil { alarms.calls == 1 }
        XCTAssertFalse(completed, "Finishing iCloud alone must not signal completion")
        alarms.release(0)
        await waitUntil { completed }
    }

    func testNewCloudDataCanReplaceAlarmWorkBeforeCompletionIsDelivered() async {
        let cloud = SyncGate()
        let alarms = SyncGate()
        var fullRecoveryRequests: [Bool] = []
        let coordinator = CloudSyncCoordinator(
            reloadStore: { _, _, fullRecovery in
                fullRecoveryRequests.append(fullRecovery)
                await cloud.wait()
            },
            waitForAlarms: { await alarms.wait() }
        )
        let store = MedicationStore()
        var completions = 0
        coordinator.scheduleReload(store: store, delayNanoseconds: 0) { completions += 1 }
        await waitUntil { cloud.calls == 1 }
        cloud.release(0)
        await waitUntil { alarms.calls == 1 }

        coordinator.scheduleReload(store: store, delayNanoseconds: 0, forceFullRecovery: true) { completions += 1 }
        await waitUntil { cloud.calls == 2 }
        // The first waiter must not finish the sync while a newer cloud reload is still running.
        alarms.release(0)
        await Task.yield()
        XCTAssertEqual(completions, 0)
        cloud.release(1)
        await waitUntil { alarms.calls == 2 }
        XCTAssertEqual(completions, 0)
        alarms.release(1)
        await waitUntil { completions == 2 }
        XCTAssertEqual(fullRecoveryRequests, [false, true])
    }

    func testUpdatesReceivedDuringCloudFetchAreAppliedBeforeWaitingForAlarms() async {
        let cloud = SyncGate()
        let alarms = SyncGate()
        let coordinator = CloudSyncCoordinator(
            reloadStore: { _, _, _ in await cloud.wait() },
            waitForAlarms: { await alarms.wait() }
        )
        let store = MedicationStore()
        var completions = 0
        coordinator.scheduleReload(store: store, delayNanoseconds: 0) { completions += 1 }
        await waitUntil { cloud.calls == 1 }
        coordinator.scheduleReload(store: store, delayNanoseconds: 0) { completions += 1 }
        cloud.release(0)
        await waitUntil { cloud.calls == 2 }
        XCTAssertEqual(alarms.calls, 0)
        XCTAssertEqual(completions, 0)
        cloud.release(1)
        await waitUntil { alarms.calls == 1 }
        alarms.release(0)
        await waitUntil { completions == 2 }
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Expected sync checkpoint was not reached", file: file, line: line)
    }
}

@MainActor
private final class SyncGate {
    private(set) var calls = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func wait() async {
        let id = calls
        calls += 1
        await withCheckedContinuation { continuations[id] = $0 }
    }

    func release(_ id: Int) { continuations.removeValue(forKey: id)?.resume() }
}
