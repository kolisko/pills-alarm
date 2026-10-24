import AlarmKit
import XCTest
import PillCore
@testable import PillsAlarm

@MainActor
final class AlarmControlTests: XCTestCase {
    func testMissingControlStateDoesNotPretendAlarmsAreOff() {
        let defaults = isolatedDefaults()
        XCTAssertThrowsError(try AlarmControlState.currentValue(defaults: defaults))
        defaults.set(true, forKey: AlarmControlState.enabledKey)
        XCTAssertEqual(try AlarmControlState.currentValue(defaults: defaults), true)
        defaults.set(false, forKey: AlarmControlState.enabledKey)
        XCTAssertEqual(try AlarmControlState.currentValue(defaults: defaults), false)
    }

    func testExistingPreferenceIsPublishedWithoutChangingOtherSettings() async throws {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: NotificationScheduler.alarmsEnabledKey)
        defaults.set("spoken", forKey: NotificationScheduler.soundModeKey)
        let client = FakeAlarmKitClient()
        var states: [Bool] = []
        let scheduler = NotificationScheduler(
            defaults: defaults, alarmClient: client, removeLegacyNotifications: {},
            publishControlState: { states.append($0) }
        )
        XCTAssertEqual(states, [true])
        try await scheduler.setAlarmsEnabledAndWait(false) {
            XCTFail("Disabling must not read plans or iCloud")
            return []
        }
        XCTAssertEqual(states.last, false)
        XCTAssertFalse(defaults.bool(forKey: NotificationScheduler.alarmsEnabledKey))
        XCTAssertEqual(defaults.string(forKey: NotificationScheduler.soundModeKey), "spoken")
    }

    func testControlDisablesRingingFutureAndTestAlarmsWithoutAuthorization() async throws {
        let (scheduler, client) = fixture(enabled: true)
        let ringing = UUID()
        for id in [ringing, UUID(), NotificationScheduler.alarmKitTestID] { client.addExisting(id: id) }
        client.alertingIDs.insert(ringing)
        client.authorizationStatus = .denied
        try await scheduler.setAlarmsEnabledAndWait(false) {
            XCTFail("Disabling must work without loading any plans")
            return []
        }
        XCTAssertTrue(client.records.isEmpty)
        XCTAssertTrue(client.alertingIDs.isEmpty)
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertEqual(client.authorizationRequests, 0)
        try await scheduler.rescheduleAlarmGroups([group()]).value
        XCTAssertTrue(client.records.isEmpty)
    }

    func testEnableUsesCurrentPlansAndDoesNotRestoreOldTestAlarm() async throws {
        let (scheduler, client) = fixture()
        try await scheduler.setAlarmsEnabledAndWait(true) { [self.group()] }
        XCTAssertTrue(scheduler.alarmsEnabled)
        XCTAssertEqual(client.records.count, 1)
        XCTAssertNil(client.records[NotificationScheduler.alarmKitTestID])
        XCTAssertFalse(scheduler.isChangingAlarmState)
    }

    func testLoadFailureLeavesAlarmsOffAndReturnsErrorToControl() async {
        let (scheduler, client) = fixture()
        do {
            try await scheduler.setAlarmsEnabledAndWait(true) { throw AlarmControlError.plansUnavailable }
            XCTFail("Must not report success without plans")
        } catch {
            XCTAssertEqual(error.localizedDescription, AlarmControlError.plansUnavailable.localizedDescription)
        }
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
        XCTAssertFalse(scheduler.isChangingAlarmState)
        XCTAssertNotNil(scheduler.lastSchedulingError)
    }

    func testDeniedPermissionDoesNotLoadPlansOrReportSuccess() async {
        let (scheduler, client) = fixture()
        client.authorizationStatus = .denied
        do {
            try await scheduler.setAlarmsEnabledAndWait(true) { XCTFail("No permission"); return [] }
            XCTFail("Must throw")
        } catch {}
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
    }

    func testCancellationFailureIsReturnedAndCanBeRetried() async throws {
        let (scheduler, client) = fixture(enabled: true)
        let id = UUID()
        client.addExisting(id: id)
        client.failCancellationIDs.insert(id)
        do {
            try await scheduler.setAlarmsEnabledAndWait(false) { [] }
            XCTFail("The control must not report successful cancellation")
        } catch {}
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertNotNil(scheduler.lastSchedulingError)
        client.failCancellationIDs = []
        try await scheduler.setAlarmsEnabledAndWait(false) { [] }
        XCTAssertTrue(client.records.isEmpty)
        XCTAssertNil(scheduler.lastSchedulingError)
    }

    func testOffSupersedesEnableWaitingForPlans() async throws {
        let (scheduler, client) = fixture()
        var continuation: CheckedContinuation<Void, Never>?
        let enabling = Task {
            try await scheduler.setAlarmsEnabledAndWait(true) {
                await withCheckedContinuation { continuation = $0 }
                return [self.group()]
            }
        }
        await waitUntil { continuation != nil }
        try await scheduler.setAlarmsEnabledAndWait(false) { [] }
        continuation?.resume()
        if case .success = await enabling.result { XCTFail("Stale enable must be cancelled") }
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
        XCTAssertFalse(scheduler.isChangingAlarmState)
        XCTAssertNil(scheduler.lastSchedulingError)
    }

    func testOffSupersedesEnableAlreadyScheduling() async throws {
        let (scheduler, client) = fixture()
        client.suspendNextSchedule = true
        let enabling = Task { try await scheduler.setAlarmsEnabledAndWait(true) { [self.group()] } }
        await waitUntil { client.waitingSchedule != nil }
        let disabling = Task { try await scheduler.setAlarmsEnabledAndWait(false) { [] } }
        await waitUntil { !scheduler.alarmsEnabled }
        client.resumeSchedule()
        _ = await enabling.result
        try await disabling.value
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
        XCTAssertFalse(scheduler.isChangingAlarmState)
    }

    func testControlAndSettingsOperateOnSameState() async throws {
        let (scheduler, client) = fixture()
        await scheduler.setAlarmsEnabled(true) { [self.group()] }
        try await scheduler.setAlarmsEnabledAndWait(false) { [] }
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
        try await scheduler.setAlarmsEnabledAndWait(true) { [self.group()] }
        await scheduler.setAlarmsEnabled(false) { [] }
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
    }

    func testActualControlTapCancelsRealAlarms() async throws {
#if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["PILLCARE_CONTROL_UI_TEST"] == "1" else {
            throw XCTSkip("Opt-in: add and tap Alarmy Pills in the isolated simulator Control Center")
        }
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires AlarmKit") }
        let scheduler = NotificationScheduler.shared
        await scheduler.waitForPendingOperations()
        guard try AlarmManager.shared.alarms.isEmpty else { throw XCTSkip("Requires no existing alarms") }
        let original = scheduler.alarmsEnabled
        var failure: Error?
        do {
            try await scheduler.setAlarmsEnabledAndWait(true) {
                [self.group(at: Date().addingTimeInterval(30)), self.group(at: Date().addingTimeInterval(600))]
            }
            XCTAssertEqual(try AlarmManager.shared.alarms.count, 2)
            print("CONTROL_UI_TEST_READY: add Alarmy Pills, wait for ringing, then toggle off")
            let deadline = Date().addingTimeInterval(180)
            while scheduler.alarmsEnabled, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
            await scheduler.waitForPendingOperations()
            XCTAssertFalse(scheduler.alarmsEnabled, "Use the actual Control Center toggle")
            XCTAssertTrue(try AlarmManager.shared.alarms.isEmpty)
            XCTAssertEqual(try AlarmControlState.currentValue(), false)
            print("CONTROL_UI_TEST_PASSED: all real alarms removed by Control Center")
        } catch { failure = error }
        await scheduler.setAlarmsEnabled(false) { [] }
        if original { await scheduler.setAlarmsEnabled(true) { [] } }
        if let failure { throw failure }
#else
        throw XCTSkip("Simulator-only")
#endif
    }

    func testControlIntentCancelsRealRingingAndFutureAlarms() async throws {
#if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["PILLCARE_CONTROL_INTENT_TEST"] == "1",
              ProcessInfo.processInfo.environment["PILLCARE_ALARM_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in real AlarmKit test with cloud rescheduling disabled")
        }
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires AlarmKit") }
        let scheduler = NotificationScheduler.shared
        await scheduler.waitForPendingOperations()
        guard try AlarmManager.shared.alarms.isEmpty else { throw XCTSkip("Requires no existing alarms") }
        guard AlarmManager.shared.authorizationState == .authorized else {
            throw XCTSkip("Requires previously granted AlarmKit permission in the isolated simulator")
        }
        let original = scheduler.alarmsEnabled
        var failure: Error?
        do {
            try await scheduler.setAlarmsEnabledAndWait(true) {
                [self.group(at: Date().addingTimeInterval(8)), self.group(at: Date().addingTimeInterval(600))]
            }
            XCTAssertEqual(try AlarmManager.shared.alarms.count, 2)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, try !AlarmManager.shared.alarms.contains(where: { $0.state == .alerting }) {
                try await Task.sleep(for: .milliseconds(200))
            }
            XCTAssertTrue(try AlarmManager.shared.alarms.contains { $0.state == .alerting })
            _ = try await SetPillsAlarmsIntent(value: false).perform()
            XCTAssertFalse(scheduler.alarmsEnabled)
            XCTAssertTrue(try AlarmManager.shared.alarms.isEmpty)
            XCTAssertEqual(try AlarmControlState.currentValue(), false)
            _ = try await SetPillsAlarmsIntent(value: false).perform()
            XCTAssertTrue(try AlarmManager.shared.alarms.isEmpty)
        } catch { failure = error }
        await scheduler.setAlarmsEnabled(false) { [] }
        if original { await scheduler.setAlarmsEnabled(true) { [] } }
        if let failure { throw failure }
#else
        throw XCTSkip("Simulator-only")
#endif
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "AlarmControlTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private func fixture(enabled: Bool = false) -> (NotificationScheduler, FakeAlarmKitClient) {
        let defaults = isolatedDefaults()
        defaults.set(enabled, forKey: NotificationScheduler.alarmsEnabledKey)
        let client = FakeAlarmKitClient()
        return (NotificationScheduler(defaults: defaults, alarmClient: client, removeLegacyNotifications: {}), client)
    }

    private func group(at date: Date = Date().addingTimeInterval(600)) -> ScheduledDoseAlarmGroup {
        let dose = GeneratedDose(
            id: UUID().uuidString, baseEventId: UUID().uuidString, workspaceId: "control-test",
            isShared: false, workspaceName: "", medicationId: UUID(), medicationName: "Control test",
            medicationNote: "", medicationColorHex: "#009999", timeId: UUID(), timeLabel: "Morning",
            scheduledDate: date, scheduledTime: TimeOfDay(hour: 8, minute: 0), amount: "1", phaseTitle: "Phase 1"
        )
        return ScheduledDoseAlarmGroup(scheduledDate: date, alarms: [ScheduledDoseAlarm(dose: dose, scheduledDate: date, repeatIndex: 0)])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition())
    }
}
