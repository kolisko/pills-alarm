import XCTest
import AlarmKit
import Combine
import PillCore
@testable import PillsAlarm

@MainActor
final class AlarmSchedulerTests: XCTestCase {
    func testOpenIntentStopsRealAlarmKitAlarm() async throws {
#if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["PILLCARE_REAL_ALARMKIT_TEST"] == "1" else {
            throw XCTSkip("Opt-in real AlarmKit test; requires permission in an isolated simulator")
        }
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit requires iOS 26") }
        guard try AlarmManager.shared.alarms.isEmpty else {
            throw XCTSkip("Run only in a simulator without existing alarms")
        }
        let scheduler = NotificationScheduler.shared
        let previouslyEnabled = scheduler.alarmsEnabled
        await scheduler.setAlarmsEnabled(true) { [] }
        guard scheduler.alarmsEnabled else {
            XCTFail("Allow AlarmKit in the simulator to run this test")
            return
        }
        var failure: Error?
        do {
            let firingDate = Date().addingTimeInterval(8)
            let futureDate = Date().addingTimeInterval(300)
            try await scheduler.rescheduleAlarmGroups([
                makeGroup("AlarmKit stop smoke test", at: firingDate),
                makeGroup("Preserved future alarm", at: futureDate)
            ]).value
            let initialAlarms = try AlarmManager.shared.alarms
            let firingAlarm = try XCTUnwrap(initialAlarms.first {
                if case .fixed(let date)? = $0.schedule { return abs(date.timeIntervalSince(firingDate)) < 1 }
                return false
            })
            let futureAlarm = try XCTUnwrap(initialAlarms.first { $0.id != firingAlarm.id })
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline,
                  try !AlarmManager.shared.alarms.contains(where: { $0.id == firingAlarm.id && $0.state == .alerting }) {
                try await Task.sleep(for: .milliseconds(200))
            }
            XCTAssertTrue(try AlarmManager.shared.alarms.contains { $0.id == firingAlarm.id && $0.state == .alerting })
            let navigation = AppNavigation.shared
            navigation.selectedTab = .settings
            _ = try await OpenPillsAppIntent(alarmID: firingAlarm.id).perform()
            try await Task.sleep(for: .milliseconds(300))
            let remaining = try AlarmManager.shared.alarms
            XCTAssertFalse(remaining.contains { $0.id == firingAlarm.id && $0.state == .alerting })
            XCTAssertTrue(remaining.contains { $0.id == futureAlarm.id && $0.state == .scheduled })
            XCTAssertEqual(navigation.selectedTab, .today)
        } catch {
            failure = error
        }
        await scheduler.setAlarmsEnabled(false) { [] }
        if previouslyEnabled { await scheduler.setAlarmsEnabled(true) { [] } }
        if let failure { throw failure }
#else
        throw XCTSkip("Real AlarmKit smoke test is simulator-only")
#endif
    }

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
        let date = try await fixture.scheduler.scheduleTestAlarm { [group] }
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
        _ = try await fixture.scheduler.scheduleTestAlarm { [self.makeGroup("Morning")] }
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
            _ = try await fixture.scheduler.scheduleTestAlarm {
                XCTFail("Must not read doses while alarms are disabled")
                return []
            }
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
        let testing = Task {
            try await fixture.scheduler.scheduleTestAlarm { [self.makeGroup("Morning")] }
        }
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

    func testSchedulingIndicatorCoversQueuedWorkAndFinishesAfterLastAlarm() async throws {
        let fixture = makeFixture(enabled: true)
        XCTAssertFalse(fixture.scheduler.isScheduling)
        fixture.client.suspendNextSchedule = true
        let planning = fixture.scheduler.rescheduleAlarmGroups([makeGroup("Morning")])
        XCTAssertTrue(fixture.scheduler.isScheduling, "Must publish before the queued task starts")
        await waitUntil { fixture.client.waitingSchedule != nil }
        XCTAssertTrue(fixture.scheduler.isScheduling)
        fixture.client.resumeSchedule()
        try await planning.value
        XCTAssertFalse(fixture.scheduler.isScheduling)
    }

    func testSchedulingIndicatorStaysVisibleWhileCancelledWorkIsReplaced() async throws {
        let fixture = makeFixture(enabled: true)
        var states: [Bool] = []
        let observation = fixture.scheduler.$isScheduling.sink { states.append($0) }
        defer { observation.cancel() }
        fixture.client.suspendNextSchedule = true
        let old = fixture.scheduler.rescheduleAlarmGroups([makeGroup("Old")])
        await waitUntil { fixture.client.waitingSchedule != nil }
        fixture.client.suspendNextSchedule = true
        let replacement = fixture.scheduler.rescheduleAlarmGroups([makeGroup("New")])
        fixture.client.resumeSchedule()
        _ = await old.result
        await waitUntil { fixture.client.waitingSchedule != nil }
        XCTAssertTrue(fixture.scheduler.isScheduling)
        fixture.client.resumeSchedule()
        try await replacement.value
        XCTAssertFalse(fixture.scheduler.isScheduling)
        XCTAssertEqual(states.first, false)
        XCTAssertEqual(states.last, false)
        XCTAssertTrue(states.dropFirst().dropLast().allSatisfy { $0 }, "No idle gap before the replacement finishes")
    }

    func testSchedulingFailureClearsBusyStateAndKeepsErrorVisible() async {
        let fixture = makeFixture(enabled: true)
        fixture.client.failScheduleAttempt = 1
        _ = await fixture.scheduler.rescheduleAlarmGroups([makeGroup("Failure")]).result
        XCTAssertFalse(fixture.scheduler.isScheduling)
        XCTAssertNotNil(fixture.scheduler.lastSchedulingError)
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

    func testSoundModeDefaultsToToneAndPersistsOnThisDevice() {
        let fixture = makeFixture()
        XCTAssertEqual(fixture.scheduler.soundMode, .tone)
        fixture.scheduler.soundMode = .spoken
        let restarted = NotificationScheduler(
            defaults: fixture.defaults, alarmClient: fixture.client, alarmSounds: fixture.sounds,
            removeLegacyNotifications: {}
        )
        XCTAssertEqual(restarted.soundMode, .spoken)
        XCTAssertFalse(restarted.alarmsEnabled)
        fixture.defaults.set("unknown-mode", forKey: NotificationScheduler.soundModeKey)
        let unknownMode = NotificationScheduler(
            defaults: fixture.defaults, alarmClient: fixture.client, alarmSounds: fixture.sounds,
            removeLegacyNotifications: {}
        )
        XCTAssertEqual(unknownMode.soundMode, .tone)
    }

    func testToneDoesNotRequestSpeech() async throws {
        let fixture = makeFixture(enabled: true)
        try await fixture.scheduler.rescheduleAlarmGroups([makeGroup("Morning")]).value
        XCTAssertTrue(fixture.sounds.contents.isEmpty)
        XCTAssertEqual(fixture.client.records.values.first?.soundName, NotificationScheduler.doseAlarmSoundName)
    }

    func testSpokenModeStillCancelsAndRecreatesAllAlarmsUsingStableSoundNames() async throws {
        let fixture = makeFixture(enabled: true)
        fixture.scheduler.soundMode = .spoken
        let now = Date()
        let first = makeGroup("Lék", at: now.addingTimeInterval(600))
        let second = makeGroup("Lék", at: now.addingTimeInterval(1_200))
        try await fixture.scheduler.rescheduleAlarmGroups([first, second]).value
        let oldIDs = Set(fixture.client.records.keys)
        let names = Set(fixture.client.records.values.compactMap(\.soundName))
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(fixture.sounds.contents.first?.lines, ["Jedna tableta Lék."])
        try await fixture.scheduler.rescheduleAlarmGroups([first, second]).value
        XCTAssertTrue(oldIDs.isDisjoint(with: fixture.client.records.keys))
        XCTAssertTrue(oldIDs.isSubset(of: Set(fixture.client.cancellationAttempts)))
        XCTAssertEqual(Set(fixture.client.records.values.compactMap(\.soundName)), names)

        var reduced = first
        reduced.alarms[0].dose.amount = "½"
        try await fixture.scheduler.rescheduleAlarmGroups([reduced]).value
        XCTAssertFalse(names.contains(try XCTUnwrap(fixture.client.records.values.first?.soundName)))
        XCTAssertEqual(fixture.sounds.contents.last?.lines, ["Půl tablety Lék."])
    }

    func testSpeechFailureStillSchedulesEveryAlarmWithExistingTone() async throws {
        let fixture = makeFixture(enabled: true)
        fixture.scheduler.soundMode = .spoken
        fixture.sounds.fail = true
        try await fixture.scheduler.rescheduleAlarmGroups([makeGroup("One"), makeGroup("Two")]).value
        XCTAssertEqual(fixture.client.records.count, 2)
        XCTAssertTrue(fixture.client.records.values.allSatisfy { $0.soundName == NotificationScheduler.doseAlarmSoundName })
        XCTAssertNotNil(fixture.scheduler.lastSoundWarning)
        XCTAssertNil(fixture.scheduler.lastSchedulingError)
        fixture.scheduler.soundMode = .tone
        try await fixture.scheduler.rescheduleAlarmGroups([makeGroup("One")]).value
        XCTAssertNil(fixture.scheduler.lastSoundWarning)
    }

    func testDisablingDuringSpeechCancelsSynthesisAndLeavesNoAlarm() async {
        let fixture = makeFixture(enabled: true)
        fixture.scheduler.soundMode = .spoken
        fixture.sounds.suspend = true
        let planning = fixture.scheduler.rescheduleAlarmGroups([makeGroup("One")])
        await waitUntil { !fixture.sounds.contents.isEmpty }
        XCTAssertTrue(fixture.scheduler.isScheduling, "Speech generation is part of alarm activity")
        await fixture.scheduler.setAlarmsEnabled(false) { [] }
        _ = await planning.result
        XCTAssertEqual(fixture.client.scheduleAttempts, 0)
        XCTAssertTrue(fixture.client.records.isEmpty)
        XCTAssertNil(fixture.scheduler.lastSoundWarning)
        XCTAssertNil(fixture.scheduler.lastSchedulingError)
        XCTAssertFalse(fixture.scheduler.isScheduling)
    }

    func testTestAlarmUsesRealPhasedDosesAndSameSoundAsNearestRegularAlarm() async throws {
        let fixture = makeFixture(enabled: true)
        fixture.scheduler.soundMode = .spoken
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 7))!
        let morning = DoseTime(label: "Ráno", time: TimeOfDay(hour: 8, minute: 0))
        func medication(_ name: String, amount: Double, form: MedicationForm = .tablet) -> Medication {
            Medication(
                name: name, note: "", form: form, colorHex: "#009999", startDate: start,
                doseTimes: [morning], phases: [
                    PlanPhase(title: "První den", durationDays: 1, doses: [DoseEntry(timeId: morning.id, amount: 4)]),
                    PlanPhase(title: "Aktuální dávka", durationDays: nil, doses: [DoseEntry(timeId: morning.id, amount: amount)])
                ]
            )
        }
        var medications = [
            medication("Ospolut", amount: 0.5), medication("Trelema", amount: 1),
            medication("Sirup", amount: 2.5, form: .syrup), medication("Vynechaný", amount: 0),
            medication("Už podaný", amount: 3)
        ]
        let confirmedDose = try XCTUnwrap(ScheduleEngine.doses(on: now, medications: medications, calendar: calendar)
            .first { $0.medicationName == "Už podaný" })
        let confirmation = DoseConfirmation(
            eventId: confirmedDose.id, medicationId: confirmedDose.medicationId, timeId: confirmedDose.timeId,
            scheduledDate: confirmedDose.scheduledDate, amount: confirmedDose.amount, status: .confirmed,
            memberId: UUID(), memberName: "", timestamp: now, note: ""
        )
        func groups() -> [ScheduledDoseAlarmGroup] {
            AlarmSchedulingRules.groupedByMinute(AlarmSchedulingRules.upcomingAlarms(
                now: now, settings: fixture.scheduler.alarmSettings,
                dosesForDate: { ScheduleEngine.doses(on: $0, medications: medications, calendar: calendar) },
                confirmationForDose: { $0.id == confirmation.eventId ? confirmation : nil },
                calendar: calendar
            ), calendar: calendar)
        }
        let regularGroups = groups()
        let nearest = try XCTUnwrap(regularGroups.first)
        XCTAssertEqual(nearest.alarms.count, 3)
        try await fixture.scheduler.rescheduleAlarmGroups(regularGroups).value
        let regularRecords = fixture.client.records
        let nearestRecord = try XCTUnwrap(regularRecords.values.first { $0.scheduledDate == nearest.scheduledDate })
        let soundCalls = fixture.sounds.contents.count

        _ = try await fixture.scheduler.scheduleTestAlarm { groups() }
        let testRecord = try XCTUnwrap(fixture.client.records[NotificationScheduler.alarmKitTestID])
        XCTAssertEqual(fixture.sounds.contents.count, soundCalls + 1, "Only the selected group is prepared for the test")
        XCTAssertEqual(fixture.sounds.contents.last?.lines, [
            "Půl tablety Ospolut.", "2,5 mililitru Sirup.", "Jedna tableta Trelema."
        ])
        XCTAssertEqual(testRecord.soundName, nearestRecord.soundName)
        XCTAssertEqual(testRecord.title, "Test: \(nearestRecord.title)")
        XCTAssertEqual(testRecord.body, nearestRecord.body)

        medications[0].phases[1].doses[0].amount = 0.75
        _ = try await fixture.scheduler.scheduleTestAlarm { groups() }
        XCTAssertEqual(fixture.sounds.contents.last?.lines.first, "Tři čtvrtě tablety Ospolut.")
        XCTAssertNotEqual(fixture.client.records[NotificationScheduler.alarmKitTestID]?.soundName, testRecord.soundName)
        XCTAssertEqual(Set(fixture.client.records.keys), Set(regularRecords.keys).union([NotificationScheduler.alarmKitTestID]))
        for (id, record) in regularRecords {
            XCTAssertEqual(fixture.client.records[id]?.soundName, record.soundName)
            XCTAssertEqual(fixture.client.records[id]?.scheduledDate, record.scheduledDate)
            XCTAssertFalse(fixture.client.cancellationAttempts.contains(id))
        }
    }

    func testTestAlarmReadsLatestGroupAfterPendingSchedulingFinishes() async throws {
        let fixture = makeFixture(enabled: true)
        fixture.scheduler.soundMode = .spoken
        fixture.client.suspendNextSchedule = true
        let planning = fixture.scheduler.rescheduleAlarmGroups([makeGroup("Původní")])
        await waitUntil { fixture.client.waitingSchedule != nil }
        var upcoming = [makeGroup("Stará dávka")]
        var didReadPlans = false
        var testQueued = false
        let testing = Task {
            testQueued = true
            return try await fixture.scheduler.scheduleTestAlarm {
                didReadPlans = true
                return upcoming
            }
        }
        await waitUntil { testQueued }
        XCTAssertFalse(didReadPlans)
        upcoming = [makeGroup("Aktuální dávka")]
        fixture.client.resumeSchedule()
        try await planning.value
        _ = try await testing.value
        XCTAssertTrue(didReadPlans)
        XCTAssertEqual(fixture.sounds.contents.last?.lines, ["Jedna tableta Aktuální dávka."])
    }

    func testTestAlarmWithoutUpcomingDosesReportsErrorAndPreservesAlarms() async {
        for mode in AlarmSoundMode.allCases {
            let fixture = makeFixture(enabled: true)
            fixture.scheduler.soundMode = mode
            let regularID = UUID()
            fixture.client.addExisting(id: regularID)
            fixture.client.addExisting(id: NotificationScheduler.alarmKitTestID)
            do {
                _ = try await fixture.scheduler.scheduleTestAlarm { [] }
                XCTFail("No test alarm should be made from an invented message")
            } catch {
                XCTAssertEqual(error.localizedDescription, "Pro test nejsou k dispozici žádná nadcházející nepotvrzená podání.")
            }
            XCTAssertEqual(Set(fixture.client.records.keys), [regularID, NotificationScheduler.alarmKitTestID])
            XCTAssertTrue(fixture.client.cancellationAttempts.isEmpty)
            XCTAssertTrue(fixture.sounds.contents.isEmpty)
            XCTAssertEqual(fixture.client.scheduleAttempts, 0)
            XCTAssertFalse(fixture.scheduler.isScheduling)
        }
    }

    private func makeFixture(
        enabled: Bool? = nil, legacy: String? = nil, available: Bool = true
    ) -> (scheduler: NotificationScheduler, client: FakeAlarmKitClient, defaults: UserDefaults, cleanup: CleanupSpy, sounds: FakeAlarmSounds) {
        let suiteName = "AlarmSchedulerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        if let enabled { defaults.set(enabled, forKey: NotificationScheduler.alarmsEnabledKey) }
        if let legacy { defaults.set(legacy, forKey: "alarmDeliveryMethod.v1") }
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let client = FakeAlarmKitClient()
        client.isAvailable = available
        let cleanup = CleanupSpy()
        let sounds = FakeAlarmSounds()
        let scheduler = NotificationScheduler(
            defaults: defaults, alarmClient: client, alarmSounds: sounds, removeLegacyNotifications: { cleanup.calls += 1 }
        )
        return (scheduler, client, defaults, cleanup, sounds)
    }

    private func makeGroup(_ name: String, at date: Date = Date().addingTimeInterval(600)) -> ScheduledDoseAlarmGroup {
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
private final class FakeAlarmSounds: AlarmSoundProviding {
    var contents: [AlarmSpeechContent] = []
    var fail = false
    var suspend = false

    func soundName(for content: AlarmSpeechContent) async throws -> String {
        contents.append(content)
        if suspend { try await Task.sleep(for: .seconds(30)) }
        if fail { throw AlarmAudioError.emptySpeech }
        return content.fileName(voiceIdentifier: "test")
    }
}

@MainActor
private final class CleanupSpy {
    var calls = 0
}

@MainActor
final class FakeAlarmKitClient: AlarmKitScheduling {
    var isAvailable = true
    var authorizationStatus: AlarmAuthorizationStatus = .authorized
    var authorizationRequests = 0
    var failAuthorization = false
    var scheduleAttempts = 0
    var failScheduleAttempt: Int?
    var records: [UUID: StoredAlarmKitInfo] = [:]
    var cancellationAttempts: [UUID] = []
    var failCancellationIDs: Set<UUID> = []
    var alertingIDs: Set<UUID> = []
    var stopAttempts: [UUID] = []
    var failStop = false
    var removeBeforeStopFailure = false
    var failAlarmLookup = false
    var suspendNextSchedule = false
    var waitingSchedule: CheckedContinuation<Void, Never>?

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        if failAuthorization { throw TestError.injected }
        return authorizationStatus == .authorized
    }

    func alarms() throws -> [AlarmKitAlarm] {
        if failAlarmLookup { throw TestError.injected }
        return records.values.map {
            AlarmKitAlarm(id: $0.id, scheduledDate: $0.scheduledDate, isAlerting: alertingIDs.contains($0.id))
        }
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
        alertingIDs.remove(id)
    }

    func stop(id: UUID) throws {
        stopAttempts.append(id)
        if removeBeforeStopFailure { records.removeValue(forKey: id) }
        if failStop { throw TestError.injected }
        records.removeValue(forKey: id)
        alertingIDs.remove(id)
    }

    func addExisting(id: UUID) {
        records[id] = StoredAlarmKitInfo(id: id, title: "Existing", body: "", scheduledDate: Date().addingTimeInterval(600))
    }

    private enum TestError: Error {
        case injected
    }
}
