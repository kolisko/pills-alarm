import XCTest
import PillCore
@testable import PillsAlarm

@MainActor
final class AlarmSchedulerTests: XCTestCase {
    func testExistingAlarmKitPreferenceIsPreserved() {
        let fixture = makeFixture(legacy: "alarmKit")
        XCTAssertTrue(fixture.scheduler.alarmsEnabled)
        XCTAssertTrue(fixture.defaults.bool(forKey: NotificationScheduler.alarmsEnabledKey))
        XCTAssertNil(fixture.defaults.object(forKey: "alarmDeliveryMethod.v1"))
    }

    func testNewInstallationAndLegacyNotificationsStartOff() async {
        for legacy in [nil, "localNotifications", "unknown"] as [String?] {
            let fixture = makeFixture(legacy: legacy)
            fixture.scheduler.restoreAlarmState()
            await fixture.scheduler.requestAuthorizationIfNeeded()
            await fixture.scheduler.waitForPendingOperations()
            XCTAssertFalse(fixture.scheduler.alarmsEnabled)
            XCTAssertEqual(fixture.client.authorizationRequests, 0)
            XCTAssertEqual(fixture.client.scheduleAttempts, 0)
            XCTAssertGreaterThan(fixture.cleanup.calls, 0)
        }
    }

    func testExplicitOffOverridesLegacyOnAndSurvivesRestart() async {
        let fixture = makeFixture(enabled: false, legacy: "alarmKit")
        fixture.client.addExisting(id: UUID())
        fixture.client.addExisting(id: NotificationScheduler.alarmKitTestID)
        fixture.scheduler.restoreAlarmState()
        await fixture.scheduler.waitForPendingOperations()
        let restarted = NotificationScheduler(
            defaults: fixture.defaults, alarmClient: fixture.client, removeLegacyNotifications: {}
        )
        XCTAssertFalse(restarted.alarmsEnabled)
        XCTAssertTrue(fixture.client.records.isEmpty)
    }

    func testEnablingSchedulesOnlyAlarmKitAndTestPreservesDoseAlarms() async throws {
        let fixture = makeFixture()
        let group = makeGroup("Morning")
        await fixture.scheduler.setAlarmsEnabled(true) { [group] }
        XCTAssertTrue(fixture.scheduler.alarmsEnabled)
        XCTAssertEqual(fixture.client.records.count, 1)
        XCTAssertEqual(fixture.scheduler.lastScheduledCount, 1)
        let before = Date()
        let date = try await fixture.scheduler.scheduleTestAlarm()
        XCTAssertGreaterThanOrEqual(date.timeIntervalSince(before), 60)
        XCTAssertLessThan(date.timeIntervalSince(before), 65)
        XCTAssertEqual(fixture.client.records.count, 2)
        XCTAssertNotNil(fixture.client.records[NotificationScheduler.alarmKitTestID])
        let audit = await fixture.scheduler.pendingDoseAlarms()
        XCTAssertEqual(audit.count, 2)
        XCTAssertTrue(audit.contains { $0.title == "Morning: Morning" })
    }

    func testReschedulingPreservesTestAlarmAndDisablingRemovesEverything() async throws {
        let fixture = makeFixture(enabled: true)
        _ = try await fixture.scheduler.scheduleTestAlarm()
        try await fixture.scheduler.rescheduleAlarmGroups([makeGroup("Morning")]).value
        XCTAssertEqual(fixture.client.records.count, 2)
        XCTAssertNotNil(fixture.client.records[NotificationScheduler.alarmKitTestID])

        await fixture.scheduler.setAlarmsEnabled(false) { XCTFail("Must not generate doses while off"); return [] }
        XCTAssertFalse(fixture.scheduler.alarmsEnabled)
        XCTAssertTrue(fixture.client.records.isEmpty)
        XCTAssertEqual(fixture.scheduler.lastScheduledCount, 0)
        XCTAssertNil(fixture.defaults.data(forKey: "alarmKitScheduledInfo.v1"))
        XCTAssertNil(fixture.scheduler.lastSchedulingError)
    }

    func testRefreshAndSettingsResetCannotEnableOrScheduleWhenOff() async throws {
        let fixture = makeFixture(enabled: false)
        fixture.scheduler.alarmSettings = .defaultValue
        try await fixture.scheduler.rescheduleAlarmGroups([makeGroup("Cloud refresh")]).value
        fixture.scheduler.restoreAlarmState()
        await fixture.scheduler.waitForPendingOperations()
        XCTAssertFalse(fixture.scheduler.alarmsEnabled)
        XCTAssertEqual(fixture.client.scheduleAttempts, 0)
        do {
            _ = try await fixture.scheduler.scheduleTestAlarm()
            XCTFail("Test alarm must be rejected while off")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Alarmy jsou vypnuté.")
        }
        XCTAssertEqual(fixture.client.authorizationRequests, 0)
        XCTAssertTrue(fixture.client.records.isEmpty)
    }

    func testPermissionDeniedOrFailureDoesNotEnableAlarms() async {
        for shouldThrow in [false, true] {
            let fixture = makeFixture()
            fixture.client.authorizationStatus = .denied
            fixture.client.failAuthorization = shouldThrow
            await fixture.scheduler.setAlarmsEnabled(true) { [self.makeGroup("Morning")] }
            XCTAssertFalse(fixture.scheduler.alarmsEnabled)
            XCTAssertEqual(fixture.client.scheduleAttempts, 0)
            XCTAssertNotNil(fixture.scheduler.lastSchedulingError)
        }
    }

    func testUnavailableAlarmKitDoesNotEnableOrFallBack() async {
        let fixture = makeFixture(enabled: true, available: false)
        XCTAssertFalse(fixture.scheduler.alarmsEnabled)
        await fixture.scheduler.setAlarmsEnabled(true) { [self.makeGroup("Morning")] }
        XCTAssertFalse(fixture.scheduler.alarmsEnabled)
        XCTAssertEqual(fixture.client.authorizationRequests, 0)
        XCTAssertEqual(fixture.client.scheduleAttempts, 0)
        XCTAssertNotNil(fixture.scheduler.lastSchedulingError)
    }

    func testRevokedAuthorizationPreventsSchedulingWithoutFallback() async {
        let fixture = makeFixture(enabled: true)
        fixture.client.authorizationStatus = .denied
        _ = await fixture.scheduler.rescheduleAlarmGroups([makeGroup("Morning")]).result
        XCTAssertEqual(fixture.client.scheduleAttempts, 0)
        XCTAssertNotNil(fixture.scheduler.lastSchedulingError)
        XCTAssertNil(fixture.defaults.object(forKey: "alarmDeliveryMethod.v1"))
    }

    func testPartialSchedulingFailureCleansUpAndDoesNotFallBack() async {
        let fixture = makeFixture(enabled: true)
        fixture.client.failScheduleAttempt = 2
        _ = await fixture.scheduler.rescheduleAlarmGroups([makeGroup("First"), makeGroup("Second")]).result
        XCTAssertTrue(fixture.client.records.isEmpty)
        XCTAssertTrue(fixture.scheduler.alarmsEnabled)
        XCTAssertEqual(fixture.client.scheduleAttempts, 2)
        XCTAssertNotNil(fixture.scheduler.lastSchedulingError)
        XCTAssertNil(fixture.defaults.object(forKey: "alarmDeliveryMethod.v1"))
    }

    func testDisablingDuringDoseSchedulingDrainsLateCompletionEvenWithCloudRefresh() async {
        let fixture = makeFixture(enabled: true)
        fixture.client.suspendNextSchedule = true
        let planning = fixture.scheduler.rescheduleAlarmGroups([makeGroup("Morning")])
        await waitUntil { fixture.client.waitingSchedule != nil }
        let disabling = Task { await fixture.scheduler.setAlarmsEnabled(false) { [] } }
        await waitUntil { !fixture.scheduler.alarmsEnabled }
        fixture.scheduler.rescheduleAlarmGroups([makeGroup("Cloud refresh")])
        fixture.client.resumeSchedule()
        _ = await planning.result
        await disabling.value
        await fixture.scheduler.waitForPendingOperations()
        XCTAssertTrue(fixture.client.records.isEmpty)
        XCTAssertEqual(fixture.client.scheduleAttempts, 1)
        XCTAssertEqual(fixture.scheduler.lastScheduledCount, 0)
        XCTAssertNil(fixture.scheduler.lastSchedulingError)
    }

    func testDisablingDuringTestSchedulingDrainsLateCompletion() async {
        let fixture = makeFixture(enabled: true)
        fixture.client.suspendNextSchedule = true
        let testing = Task { try await fixture.scheduler.scheduleTestAlarm() }
        await waitUntil { fixture.client.waitingSchedule != nil }
        let disabling = Task { await fixture.scheduler.setAlarmsEnabled(false) { [] } }
        await waitUntil { !fixture.scheduler.alarmsEnabled }
        fixture.client.resumeSchedule()
        let result = await testing.result
        await disabling.value
        if case .success = result { XCTFail("Cancelled test must not report success") }
        XCTAssertTrue(fixture.client.records.isEmpty)
        XCTAssertFalse(fixture.scheduler.alarmsEnabled)
        XCTAssertNil(fixture.scheduler.lastSchedulingError)
    }

    func testReplacementWaitsForOldSchedulingCleanup() async throws {
        let fixture = makeFixture(enabled: true)
        fixture.client.suspendNextSchedule = true
        let old = fixture.scheduler.rescheduleAlarmGroups([makeGroup("Old")])
        await waitUntil { fixture.client.waitingSchedule != nil }
        let replacement = fixture.scheduler.rescheduleAlarmGroups([makeGroup("New")])
        fixture.client.resumeSchedule()
        _ = await old.result
        try await replacement.value
        XCTAssertEqual(fixture.client.records.values.map(\.title), ["Morning: New"])
        let audit = await fixture.scheduler.pendingDoseAlarms()
        XCTAssertEqual(audit.map(\.title), ["Morning: New"])
    }

    func testCancellationFailureAttemptsEveryAlarmAndRetriesOnReturn() async {
        let fixture = makeFixture(enabled: true)
        let failedID = UUID()
        fixture.client.addExisting(id: failedID)
        fixture.client.addExisting(id: NotificationScheduler.alarmKitTestID)
        fixture.client.failCancellationIDs = [failedID]
        await fixture.scheduler.setAlarmsEnabled(false) { [] }
        XCTAssertFalse(fixture.scheduler.alarmsEnabled)
        XCTAssertEqual(Set(fixture.client.records.keys), [failedID])
        XCTAssertNotNil(fixture.scheduler.lastSchedulingError)
        XCTAssertEqual(fixture.client.cancellationAttempts.count, 2)

        fixture.client.failCancellationIDs = []
        fixture.scheduler.restoreAlarmState()
        await fixture.scheduler.waitForPendingOperations()
        XCTAssertTrue(fixture.client.records.isEmpty)
        XCTAssertNil(fixture.scheduler.lastSchedulingError)
        XCTAssertEqual(fixture.client.authorizationRequests, 0)
    }

    func testTurningBackOnSchedulesAgainWithoutChangingRepeatSettings() async {
        let fixture = makeFixture(enabled: true)
        let settings = AlarmSettings(repeatIntervalMinutes: 20, repeatDurationMinutes: 100, repeatingDoseLimit: 3)
        fixture.scheduler.alarmSettings = settings
        await fixture.scheduler.setAlarmsEnabled(false) { [] }
        await fixture.scheduler.setAlarmsEnabled(true) { [self.makeGroup("Morning")] }
        XCTAssertTrue(fixture.scheduler.alarmsEnabled)
        XCTAssertEqual(fixture.client.records.count, 1)
        XCTAssertEqual(fixture.scheduler.alarmSettings, settings)
    }

    private func makeFixture(
        enabled: Bool? = nil, legacy: String? = nil, available: Bool = true
    ) -> (scheduler: NotificationScheduler, client: FakeAlarmKitClient, defaults: UserDefaults, cleanup: CleanupSpy) {
        let suiteName = "AlarmSchedulerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        if let enabled { defaults.set(enabled, forKey: NotificationScheduler.alarmsEnabledKey) }
        if let legacy { defaults.set(legacy, forKey: "alarmDeliveryMethod.v1") }
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let client = FakeAlarmKitClient()
        client.isAvailable = available
        let cleanup = CleanupSpy()
        let scheduler = NotificationScheduler(
            defaults: defaults, alarmClient: client, removeLegacyNotifications: { cleanup.calls += 1 }
        )
        return (scheduler, client, defaults, cleanup)
    }

    private func makeGroup(_ name: String) -> ScheduledDoseAlarmGroup {
        let date = Date().addingTimeInterval(600)
        let dose = GeneratedDose(
            id: UUID().uuidString, baseEventId: UUID().uuidString, workspaceId: "personal",
            isShared: false, workspaceName: "", medicationId: UUID(), medicationName: name,
            medicationNote: "", medicationColorHex: "#009999", timeId: UUID(), timeLabel: "Morning",
            scheduledDate: date, scheduledTime: TimeOfDay(hour: 8, minute: 0), amount: "1", phaseTitle: "Phase 1"
        )
        return ScheduledDoseAlarmGroup(
            scheduledDate: date, alarms: [ScheduledDoseAlarm(dose: dose, scheduledDate: date, repeatIndex: 0)]
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Expected suspended operation to reach the test checkpoint")
    }
}

@MainActor
private final class CleanupSpy {
    var calls = 0
}

@MainActor
private final class FakeAlarmKitClient: AlarmKitScheduling {
    var isAvailable = true
    var authorizationStatus: AlarmAuthorizationStatus = .authorized
    var authorizationRequests = 0
    var failAuthorization = false
    var scheduleAttempts = 0
    var failScheduleAttempt: Int?
    var records: [UUID: StoredAlarmKitInfo] = [:]
    var cancellationAttempts: [UUID] = []
    var failCancellationIDs: Set<UUID> = []
    var suspendNextSchedule = false
    var waitingSchedule: CheckedContinuation<Void, Never>?

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        if failAuthorization { throw TestError.injected }
        return authorizationStatus == .authorized
    }

    func alarms() throws -> [AlarmKitAlarm] {
        records.values.map { AlarmKitAlarm(id: $0.id, scheduledDate: $0.scheduledDate) }
    }

    func schedule(_ info: StoredAlarmKitInfo) async throws {
        scheduleAttempts += 1
        if suspendNextSchedule {
            suspendNextSchedule = false
            await withCheckedContinuation { waitingSchedule = $0 }
        }
        if scheduleAttempts == failScheduleAttempt { throw TestError.injected }
        records[info.id] = info
    }

    func resumeSchedule() {
        waitingSchedule?.resume()
        waitingSchedule = nil
    }

    func cancel(id: UUID) throws {
        cancellationAttempts.append(id)
        if failCancellationIDs.contains(id) { throw TestError.injected }
        records.removeValue(forKey: id)
    }

    func addExisting(id: UUID) {
        records[id] = StoredAlarmKitInfo(id: id, title: "Existing", body: "", scheduledDate: Date().addingTimeInterval(600))
    }

    private enum TestError: Error {
        case injected
    }
}
