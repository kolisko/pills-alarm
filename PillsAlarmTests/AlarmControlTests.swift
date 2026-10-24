import AlarmKit
import XCTest
import PillCore
import UIKit
@testable import PillsAlarm

@MainActor
final class AlarmControlTests: XCTestCase {
    func testControlSymbolsAreBundledAndHaveDistinctStates() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let controls = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("PillsAlarmControls.appex")))
        let on = try XCTUnwrap(UIImage(named: "PillsAlarmsOn", in: controls, compatibleWith: nil))
        let off = try XCTUnwrap(UIImage(named: "PillsAlarmsOff", in: controls, compatibleWith: nil))
        XCTAssertTrue(on.isSymbolImage)
        XCTAssertTrue(off.isSymbolImage)
        let weights: [UIImage.SymbolWeight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        let scales: [UIImage.SymbolScale] = [.small, .medium, .large]
        for size: CGFloat in [20, 32, 64] {
            for weight in weights {
                for scale in scales {
                    let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: weight, scale: scale)
                    let onImage = try XCTUnwrap(on.applyingSymbolConfiguration(configuration))
                    let offImage = try XCTUnwrap(off.applyingSymbolConfiguration(configuration))
                    XCTAssertTrue(onImage.isSymbolImage)
                    XCTAssertTrue(offImage.isSymbolImage)
                    XCTAssertGreaterThan(onImage.size.width, 0)
                    XCTAssertGreaterThan(offImage.size.height, 0)
                    XCTAssertEqual(onImage.size.width, offImage.size.width, accuracy: 0.5)
                    XCTAssertEqual(onImage.size.height, offImage.size.height, accuracy: 0.5)
                    let onAlignment = CGRect(origin: .zero, size: onImage.size).inset(by: onImage.alignmentRectInsets)
                    let offAlignment = CGRect(origin: .zero, size: offImage.size).inset(by: offImage.alignmentRectInsets)
                    let pixel = 1 / onImage.scale
                    XCTAssertEqual(onAlignment.minX, offAlignment.minX, accuracy: pixel)
                    XCTAssertEqual(onAlignment.minY, offAlignment.minY, accuracy: pixel)
                    XCTAssertEqual(onAlignment.width, offAlignment.width, accuracy: pixel)
                    XCTAssertEqual(onAlignment.height, offAlignment.height, accuracy: pixel)
                    // Exclude the lower-right bell from the tablet's optical alignment.
                    XCTAssertGreaterThan(onImage.alignmentRectInsets.right, onImage.alignmentRectInsets.left)
                    XCTAssertLessThan(onImage.alignmentRectInsets.top, onImage.alignmentRectInsets.bottom)
                    XCTAssertNotEqual(try XCTUnwrap(onImage.pngData()), try XCTUnwrap(offImage.pngData()))
                }
            }
        }
    }

    func testMissingControlStateDoesNotPretendAlarmsAreOff() {
        let defaults = isolatedDefaults()
        XCTAssertThrowsError(try AlarmControlState.currentValue(defaults: defaults))
        defaults.set(true, forKey: AlarmControlState.enabledKey)
        XCTAssertEqual(try AlarmControlState.currentValue(defaults: defaults), true)
        defaults.set(false, forKey: AlarmControlState.enabledKey)
        XCTAssertEqual(try AlarmControlState.currentValue(defaults: defaults), false)
    }

    func testMuteControlInvertsOnlyTheIntentValue() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires AlarmKit") }
        XCTAssertFalse(SetPillsAlarmsMutedIntent(value: true).alarmIntent.value)
        XCTAssertTrue(SetPillsAlarmsMutedIntent(value: false).alarmIntent.value)
        XCTAssertTrue(SetPillsAlarmsIntent(value: true).value)
        XCTAssertFalse(SetPillsAlarmsIntent(value: false).value)
    }

    func testBothStoredAlarmStatesSurviveControlInitialization() throws {
        for enabled in [true, false] {
            let defaults = isolatedDefaults()
            let controlDefaults = isolatedDefaults()
            defaults.set(enabled, forKey: NotificationScheduler.alarmsEnabledKey)
            for _ in 0..<2 {
                let scheduler = NotificationScheduler(
                    defaults: defaults, alarmClient: FakeAlarmKitClient(), removeLegacyNotifications: {},
                    publishControlState: { controlDefaults.set($0, forKey: AlarmControlState.enabledKey) }
                )
                XCTAssertEqual(scheduler.alarmsEnabled, enabled)
                XCTAssertEqual(defaults.bool(forKey: NotificationScheduler.alarmsEnabledKey), enabled)
                XCTAssertEqual(try AlarmControlState.currentValue(defaults: controlDefaults), enabled)
            }
        }
    }

    func testMuteControlRequestsUseExistingSchedulerInBothDirections() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires AlarmKit") }
        let (scheduler, client) = fixture(enabled: true)
        client.addExisting(id: UUID())
        try await scheduler.setAlarmsEnabledAndWait(SetPillsAlarmsMutedIntent(value: true).alarmIntent.value) {
            XCTFail("Muting must not load plans")
            return []
        }
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
        try await scheduler.setAlarmsEnabledAndWait(SetPillsAlarmsMutedIntent(value: false).alarmIntent.value) {
            [self.group()]
        }
        XCTAssertTrue(scheduler.alarmsEnabled)
        XCTAssertEqual(client.records.count, 1)
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

    func testActualControlTapsRoundTripWithLoadedPlan() async throws {
#if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["PILLCARE_CONTROL_UI_TEST"] == "1",
              ProcessInfo.processInfo.environment["PILLCARE_ALARM_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in: tap the real Control Center toggle in both directions")
        }
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires AlarmKit") }
        let scheduler = NotificationScheduler.shared
        let store = MedicationStore.shared
        await scheduler.waitForPendingOperations()
        guard try AlarmManager.shared.alarms.isEmpty, store.medicationItems.isEmpty else {
            throw XCTSkip("Requires an isolated simulator without plans or alarms")
        }
        guard AlarmManager.shared.authorizationState == .authorized else {
            throw XCTSkip("Requires AlarmKit permission in the isolated simulator")
        }
        let originalEnabled = scheduler.alarmsEnabled
        let originalSound = scheduler.soundMode
        let nextDose = Date().addingTimeInterval(1200)
        let time = DoseTime(
            id: UUID(), label: "UI test",
            time: TimeOfDay(hour: Calendar.current.component(.hour, from: nextDose),
                            minute: Calendar.current.component(.minute, from: nextDose))
        )
        let medication = Medication(
            id: UUID(), name: "Control UI test", note: "", colorHex: "#009999",
            startDate: Calendar.current.startOfDay(for: nextDose), doseTimes: [time],
            phases: [PlanPhase(title: "Phase 1", durationDays: 1, doses: [DoseEntry(timeId: time.id, amount: 1)])]
        )
        var failure: Error?
        do {
            scheduler.soundMode = .tone
            try await scheduler.setAlarmsEnabledAndWait(false) { [] }
            try await store.withAlarmControlUITestMedication(medication) {
                let expectedCount = scheduler.makeUpcomingDoseAlarmGroups(store: store).count
                XCTAssertGreaterThan(expectedCount, 0)
                for (index, enabled) in [true, false, true, false, true, false].enumerated() {
                    print("CONTROL_ROUNDTRIP_READY: step=\(index + 1) targetEnabled=\(enabled)")
                    let deadline = Date().addingTimeInterval(90)
                    while scheduler.alarmsEnabled != enabled, Date() < deadline {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    await scheduler.waitForPendingOperations()
                    try await Task.sleep(for: .seconds(2))
                    XCTAssertEqual(scheduler.alarmsEnabled, enabled, "Tap the actual Control Center button")
                    XCTAssertEqual(try AlarmControlState.currentValue(), enabled)
                    XCTAssertNil(scheduler.lastSchedulingError)
                    let count = try AlarmManager.shared.alarms.count
                    XCTAssertEqual(count, enabled ? expectedCount : 0)
                    print("CONTROL_ROUNDTRIP_VERIFIED: step=\(index + 1) enabled=\(scheduler.alarmsEnabled) alarms=\(count)")
                }
            }
        } catch { failure = error }
        await scheduler.setAlarmsEnabled(false) { [] }
        scheduler.soundMode = originalSound
        if originalEnabled { await scheduler.setAlarmsEnabled(true) { [] } }
        XCTAssertTrue(try AlarmManager.shared.alarms.isEmpty)
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
            _ = try await SetPillsAlarmsMutedIntent(value: true).perform()
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
