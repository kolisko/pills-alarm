import XCTest
@testable import PillCore

final class AlarmGroupRegressionTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Prague")!
        return value
    }

    private var morning: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 8))!
    }

    func testEveryRepeatIncludesAllDosesAtTheSameTimeRegardlessOfLimit() {
        for count in [3, 8] {
            let doses = (0..<count).map { makeDose("drug-\($0)") }
            for limit in [1, 2, 5] {
                for minutesAfterMorning in [-60, 0, 1] {
                    let now = morning.addingTimeInterval(Double(minutesAfterMorning * 60))
                    let result = groups(doses, now: now, limit: limit)
                    XCTAssertEqual(result.count, minutesAfterMorning < 0 ? 9 : 8)
                    for group in result {
                        XCTAssertEqual(Set(group.alarms.map(\.dose.id)), Set(doses.map(\.id)))
                        XCTAssertEqual(group.medicationCount, count)
                        XCTAssertGreaterThan(group.scheduledDate, now)
                    }
                }
            }
        }
    }

    func testConfirmingOrSkippingDosesReducesRepeatsAndUndoRestoresThem() {
        let doses = (0..<3).map { makeDose("drug-\($0)") }
        let now = morning.addingTimeInterval(60)

        for status in DoseStatus.allCases {
            for resolvedCount in 0...3 {
                let resolved = Set(doses.prefix(resolvedCount).map(\.id))
                let result = groups(doses, now: now, resolved: resolved, status: status)
                XCTAssertEqual(result.count, resolvedCount == 3 ? 0 : 8)
                for group in result {
                    XCTAssertEqual(group.medicationCount, 3 - resolvedCount)
                    XCTAssertEqual(Set(group.alarms.map(\.dose.id)), Set(doses.dropFirst(resolvedCount).map(\.id)))
                }
            }
        }

        let restored = groups(doses, now: now)
        XCTAssertEqual(restored.count, 8)
        XCTAssertTrue(restored.allSatisfy { $0.medicationCount == 3 })
    }

    func testLimitCountsDistinctTimesAndPromotesNextTimeWhenEarlierDosesAreResolved() {
        let first = (0..<3).map { makeDose("morning-\($0)") }
        let second = (0..<2).map { makeDose("noon-\($0)", date: morning.addingTimeInterval(4 * 3600)) }
        let third = (0..<2).map { makeDose("evening-\($0)", date: morning.addingTimeInterval(10 * 3600)) }
        let doses = first + second + third
        let initial = groups(doses, now: morning.addingTimeInterval(-3600)).flatMap(\.alarms)

        XCTAssertEqual(Set(initial.filter { $0.repeatIndex > 0 }.map(\.dose.id)), Set((first + second).map(\.id)))
        XCTAssertEqual(Set(initial.filter { $0.repeatIndex == 0 }.map(\.dose.id)), Set(doses.map(\.id)))

        let afterConfirmation = groups(
            doses, now: morning.addingTimeInterval(60), resolved: Set(first.map(\.id))
        ).flatMap(\.alarms)
        XCTAssertEqual(Set(afterConfirmation.filter { $0.repeatIndex > 0 }.map(\.dose.id)), Set((second + third).map(\.id)))
        XCTAssertTrue(afterConfirmation.allSatisfy { !Set(first.map(\.id)).contains($0.dose.id) })
    }

    func testSameClockTimeOnDifferentDaysRemainsSeparate() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: morning)!
        let doses = [makeDose("today-a"), makeDose("today-b"), makeDose("tomorrow", date: tomorrow)]
        let alarms = groups(doses, now: morning.addingTimeInterval(-60), limit: 1).flatMap(\.alarms)

        XCTAssertEqual(Set(alarms.filter { $0.repeatIndex > 0 }.map(\.dose.id)), ["today-a", "today-b"])
        XCTAssertEqual(alarms.filter { $0.dose.id == "tomorrow" }.map(\.repeatIndex), [0])
    }

    func testDailyAndAlternateDayMedicationsRemainCompleteWhenPlannedTheDayBefore() {
        let start = calendar.startOfDay(for: morning)
        let medications = [
            makeMedication("daily-a", start: start, interval: 1),
            makeMedication("daily-b", start: start, interval: 1),
            makeMedication("alternate", start: start, interval: 2)
        ]
        let now = calendar.date(byAdding: .day, value: -1, to: morning.addingTimeInterval(12 * 3600))!
        let alarms = AlarmSchedulingRules.upcomingAlarms(
            now: now, settings: .defaultValue,
            dosesForDate: { ScheduleEngine.doses(on: $0, medications: medications, calendar: self.calendar) },
            confirmationForDose: { _ in nil }, calendar: calendar
        )
        let result = AlarmSchedulingRules.groupedByMinute(alarms, calendar: calendar)

        for (day, expectedCount) in [(0, 3), (1, 2), (2, 3)] {
            let date = calendar.date(byAdding: .day, value: day, to: morning)!
            let first = result.first { $0.scheduledDate == date }
            XCTAssertEqual(first?.medicationCount, expectedCount)
            let sameDay = result.filter { calendar.isDate($0.scheduledDate, inSameDayAs: date) }
            XCTAssertEqual(sameDay.count, day < 2 ? 9 : 1)
            XCTAssertTrue(sameDay.allSatisfy { $0.medicationCount == expectedCount })
        }
    }

    func testMidnightRepeatsIncludeAllUnresolvedDosesAndRespectSeriesEnd() {
        let midnight = calendar.startOfDay(for: morning)
        let scheduled = midnight.addingTimeInterval(-15 * 60)
        let doses = (0..<3).map { makeDose("drug-\($0)", date: scheduled) }
        let result = groups(doses, now: midnight.addingTimeInterval(60), limit: 1)

        XCTAssertEqual(result.count, 7)
        XCTAssertTrue(result.allSatisfy { $0.medicationCount == 3 })
        XCTAssertEqual(result.last?.scheduledDate, scheduled.addingTimeInterval(120 * 60))
        XCTAssertTrue(groups(doses, now: scheduled.addingTimeInterval(120 * 60)).isEmpty)
    }

    func testRepeatingTimeUsesTheSameMinuteBoundaryAsAlarmGrouping() {
        let doses = [0, 20, 59].enumerated().map {
            makeDose("drug-\($0.offset)", date: morning.addingTimeInterval(Double($0.element)))
        }
        let result = groups(doses, now: morning.addingTimeInterval(-60), limit: 1)

        XCTAssertEqual(result.count, 9)
        XCTAssertTrue(result.allSatisfy { $0.medicationCount == 3 })
    }

    func testCountUsesMedicationIdentityNotDisplayNameOrNumberOfDoseEntries() {
        var first = makeDose("first")
        var second = makeDose("second")
        first.medicationName = "Same name"
        second.medicationName = "Same name"
        var extraDoseOfFirst = first
        extraDoseOfFirst.id = "first-extra-dose"
        extraDoseOfFirst.timeId = UUID()
        let result = groups([first, second, extraDoseOfFirst], now: morning.addingTimeInterval(-60))

        XCTAssertEqual(result.count, 9)
        XCTAssertTrue(result.allSatisfy { $0.alarms.count == 3 && $0.medicationCount == 2 })
    }

    func testExistingAlarmSettingsDecodeAndRoundTripWithoutMigration() throws {
        let data = Data(#"{"repeatIntervalMinutes":20,"repeatDurationMinutes":100,"repeatingDoseLimit":2}"#.utf8)
        let settings = try JSONDecoder().decode(AlarmSettings.self, from: data).normalized
        XCTAssertEqual(settings, AlarmSettings(repeatIntervalMinutes: 20, repeatDurationMinutes: 100, repeatingDoseLimit: 2))
        let encoded = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Int])
        XCTAssertEqual(object, ["repeatIntervalMinutes": 20, "repeatDurationMinutes": 100, "repeatingDoseLimit": 2])
        XCTAssertEqual(try JSONDecoder().decode(AlarmSettings.self, from: encoded), settings)
    }

    func testNoDosesProducesNoAlarmGroups() {
        XCTAssertTrue(groups([], now: morning).isEmpty)
    }

    private func groups(
        _ doses: [GeneratedDose], now: Date, limit: Int = 2,
        resolved: Set<String> = [], status: DoseStatus = .confirmed
    ) -> [ScheduledDoseAlarmGroup] {
        let alarms = AlarmSchedulingRules.upcomingAlarms(
            now: now,
            settings: AlarmSettings(repeatIntervalMinutes: 15, repeatDurationMinutes: 120, repeatingDoseLimit: limit),
            dosesForDate: { date in doses.filter { self.calendar.isDate($0.scheduledDate, inSameDayAs: date) } },
            confirmationForDose: { dose in
                guard resolved.contains(dose.id) else { return nil }
                return DoseBusinessRules.makeConfirmation(for: dose, status: status, memberId: UUID(), timestamp: now)
            },
            calendar: calendar
        )
        return AlarmSchedulingRules.groupedByMinute(alarms, calendar: calendar)
    }

    private func makeDose(_ id: String, date: Date? = nil) -> GeneratedDose {
        let scheduledDate = date ?? morning
        return GeneratedDose(
            id: id, baseEventId: id, workspaceId: "personal", isShared: false,
            workspaceName: "Personal", medicationId: UUID(), medicationName: id,
            medicationNote: "", medicationColorHex: "#009999", timeId: UUID(),
            timeLabel: "Morning", scheduledDate: scheduledDate,
            scheduledTime: TimeOfDay(hour: calendar.component(.hour, from: scheduledDate), minute: calendar.component(.minute, from: scheduledDate)),
            amount: "1", phaseTitle: "Phase 1"
        )
    }

    private func makeMedication(_ name: String, start: Date, interval: Int) -> Medication {
        let time = DoseTime(label: "Morning", time: TimeOfDay(hour: 8, minute: 0))
        return Medication(
            name: name, note: "", colorHex: "#009999", startDate: start, doseTimes: [time],
            phases: [PlanPhase(title: "Phase 1", durationDays: nil, doses: [DoseEntry(timeId: time.id, amount: 1)], repeatEveryDays: interval)]
        )
    }
}


final class BusinessRulesTests: XCTestCase {
    func testDoseActionsAreAvailableOnlyAfterConfiguredLeadTime() {
        let dose = makeDose(scheduledDate: Date(timeIntervalSince1970: 1_725_778_800))
        let beforeLeadTime = DoseBusinessRules.presentationState(
            for: dose,
            confirmation: nil,
            canRecordDose: true,
            now: Date(timeIntervalSince1970: 1_725_777_899),
            actionLeadTimeMinutes: 15
        )
        let insideLeadTime = DoseBusinessRules.presentationState(
            for: dose,
            confirmation: nil,
            canRecordDose: true,
            now: Date(timeIntervalSince1970: 1_725_777_900),
            actionLeadTimeMinutes: 15
        )

        XCTAssertFalse(beforeLeadTime.showsActions)
        XCTAssertTrue(beforeLeadTime.isLockedFutureDose)
        XCTAssertTrue(insideLeadTime.showsActions)
        XCTAssertFalse(insideLeadTime.isLockedFutureDose)
    }

    func testResolvedDoseIsSubduedAndDoesNotShowActions() {
        let dose = makeDose(scheduledDate: Date(timeIntervalSince1970: 1_725_778_800))
        let confirmation = DoseBusinessRules.makeConfirmation(
            for: dose,
            status: .confirmed,
            memberId: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            timestamp: Date(timeIntervalSince1970: 1_725_778_900)
        )

        let state = DoseBusinessRules.presentationState(
            for: dose,
            confirmation: confirmation,
            canRecordDose: true,
            now: Date(timeIntervalSince1970: 1_725_779_000),
            actionLeadTimeMinutes: 15
        )

        XCTAssertTrue(state.isResolved)
        XCTAssertTrue(state.isSubdued)
        XCTAssertFalse(state.showsActions)
        XCTAssertFalse(state.isOverdueToday)
    }

    func testConfirmationEventIdsIncludeLegacyWorkspaceIdWithoutDuplicates() {
        let dose = makeDose(
            id: "workspace|event",
            baseEventId: "event",
            workspaceId: "workspace",
            scheduledDate: Date(timeIntervalSince1970: 1_725_778_800)
        )
        let confirmation = DoseBusinessRules.makeConfirmation(
            for: dose,
            status: .skipped,
            memberId: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )

        XCTAssertEqual(
            DoseBusinessRules.confirmationEventIds(for: dose, including: confirmation),
            ["workspace|event", "event"]
        )
    }

    func testAccessRulesRequireNamedMemberOnlyForGroupContext() {
        XCTAssertTrue(MedicationAccessRules.canRecordDose(contextIsShared: false, contextHasMembers: false, currentMemberName: ""))
        XCTAssertFalse(MedicationAccessRules.canRecordDose(contextIsShared: true, contextHasMembers: true, currentMemberName: " "))
        XCTAssertTrue(MedicationAccessRules.canRecordDose(contextIsShared: true, contextHasMembers: true, currentMemberName: "Tata"))
    }

    func testOnlyOwnerCanManageExistingMedicationSharing() {
        let owner = "owner-record"
        let otherUser = "other-record"
        let item = MedicationListItem(
            medication: makeMedication(ownerUserRecordName: owner),
            source: WorkspaceSource(id: "shared", name: "Rodina", isShared: true)
        )

        XCTAssertTrue(
            MedicationAccessRules.canManageMedication(
                item,
                currentUserRecordName: owner,
                personalWorkspaceId: "personal",
                ownedGroupWorkspaceId: "shared"
            )
        )
        XCTAssertFalse(
            MedicationAccessRules.canManageMedication(
                item,
                currentUserRecordName: otherUser,
                personalWorkspaceId: "personal",
                ownedGroupWorkspaceId: "shared"
            )
        )
    }

    func testSharingRulesMoveMedicationAndNormalizeConfirmationEventId() {
        let medication = makeMedication(ownerUserRecordName: nil)
        let updatedMedication = MedicationSharingRules.medicationForSharingChange(
            medication,
            currentUserRecordName: "owner-record",
            shouldShare: true,
            destinationWorkspaceId: "shared"
        )
        var confirmation = makeConfirmation(medicationId: medication.id, timeId: medication.doseTimes[0].id)
        confirmation.eventId = "personal|\(confirmation.eventId)"

        XCTAssertEqual(updatedMedication.ownerUserRecordName, "owner-record")
        XCTAssertEqual(updatedMedication.sharedGroupId, "shared")
        XCTAssertEqual(
            MedicationSharingRules.confirmationForSharingChange(confirmation).eventId,
            makeConfirmation(medicationId: medication.id, timeId: medication.doseTimes[0].id).eventId
        )
    }

    func testConfirmDoseUseCaseBuildsConfirmationAndConflictLookupIds() {
        let dose = makeDose(
            id: "personal|event",
            baseEventId: "event",
            workspaceId: "personal",
            scheduledDate: Date(timeIntervalSince1970: 1_725_778_800)
        )
        let memberId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let timestamp = Date(timeIntervalSince1970: 1_725_778_900)

        let command = ConfirmDoseUseCase.makeCommand(
            dose: dose,
            status: .confirmed,
            memberId: memberId,
            timestamp: timestamp,
            note: "ok"
        )

        XCTAssertEqual(command.confirmation.eventId, "event")
        XCTAssertEqual(command.confirmation.status, .confirmed)
        XCTAssertEqual(command.confirmation.memberId, memberId)
        XCTAssertEqual(command.confirmation.timestamp, timestamp)
        XCTAssertEqual(command.confirmation.note, "ok")
        XCTAssertEqual(command.eventIdsToCheck, ["personal|event", "event"])
    }

    func testShareMedicationUseCasePreparesMedicationAndConfirmationMove() {
        var medication = makeMedication(ownerUserRecordName: nil)
        medication.sharedGroupId = nil
        let item = MedicationListItem(
            medication: medication,
            source: WorkspaceSource(id: "personal", name: "Vlastní", isShared: false)
        )
        var confirmation = makeConfirmation(medicationId: medication.id, timeId: medication.doseTimes[0].id)
        confirmation.eventId = "personal|\(confirmation.eventId)"

        let change = ShareMedicationUseCase.makeChange(
            item: item,
            updatedMedication: nil,
            shouldShare: true,
            destinationWorkspaceId: "shared",
            currentUserRecordName: "owner-record",
            sourceConfirmations: [confirmation]
        )

        XCTAssertEqual(change.medication.ownerUserRecordName, "owner-record")
        XCTAssertEqual(change.medication.sharedGroupId, "shared")
        XCTAssertEqual(change.originalConfirmationEventIds, [confirmation.eventId])
        XCTAssertEqual(change.updatedConfirmations.map(\.eventId), [MedicationSharingRules.baseEventId(from: confirmation.eventId)])
        XCTAssertEqual(change.updatedConfirmationEventIds, Set(change.updatedConfirmations.map(\.eventId)))
    }

    func testMedicationFactoryCreatesDefaultPrivateMedicationStartingToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_725_778_800)

        let medication = MedicationFactory.newMedication(now: now, calendar: calendar)

        XCTAssertEqual(medication.name, "Nový lék")
        XCTAssertEqual(medication.note, "")
        XCTAssertEqual(medication.colorHex, "#2F80ED")
        XCTAssertEqual(medication.startDate, calendar.startOfDay(for: now))
        XCTAssertEqual(medication.doseTimes.map(\.label), ["Ráno", "Poledne", "Večer"])
        XCTAssertEqual(medication.phases.first?.title, "Fáze 1")
        XCTAssertEqual(medication.phases.first?.doses.map(\.amount), [0, 0, 0])
        XCTAssertEqual(medication.form, .tablet)
        XCTAssertNil(medication.ownerUserRecordName)
        XCTAssertNil(medication.sharedGroupId)
    }

    func testMedicationDecodingDefaultsMissingFormToTablet() throws {
        let data = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Vitamin",
          "note": "",
          "colorHex": "#2F80ED",
          "startDate": 1725753600,
          "doseTimes": [],
          "phases": []
        }
        """.data(using: .utf8)!

        let medication = try JSONDecoder().decode(Medication.self, from: data)

        XCTAssertEqual(medication.form, .tablet)
        XCTAssertFalse(medication.isPublishedToMedicalTimeline)
    }

    func testMedicationDecodingTreatsLegacyMedicalTimelineTokenAsPublished() throws {
        let data = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Vitamin",
          "note": "",
          "colorHex": "#2F80ED",
          "startDate": 1725753600,
          "doseTimes": [],
          "phases": [],
          "medicalTimelinePublicToken": "legacy-token"
        }
        """.data(using: .utf8)!

        let medication = try JSONDecoder().decode(Medication.self, from: data)

        XCTAssertTrue(medication.isPublishedToMedicalTimeline)
    }

    func testPlanPhaseDecodingDefaultsMissingRepeatIntervalToDaily() throws {
        let data = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "Původní fáze",
          "doses": []
        }
        """.data(using: .utf8)!

        let phase = try JSONDecoder().decode(PlanPhase.self, from: data)

        XCTAssertEqual(phase.repeatEveryDays, 1)
    }

    func testPlanPhaseEncodingPreservesRepeatInterval() throws {
        let original = PlanPhase(
            title: "Fáze",
            durationDays: nil,
            doses: [],
            repeatEveryDays: 3
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlanPhase.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.repeatEveryDays, 3)
    }

    func testPlanPhaseNormalizesRepeatIntervalToSupportedRange() {
        let belowRange = PlanPhase(title: "Fáze", durationDays: nil, doses: [], repeatEveryDays: 0)
        let aboveRange = PlanPhase(title: "Fáze", durationDays: nil, doses: [], repeatEveryDays: 31)

        XCTAssertEqual(belowRange.repeatEveryDays, 1)
        XCTAssertEqual(aboveRange.repeatEveryDays, 30)
    }

    func testScheduleEngineRepeatsFromStartOfPhase() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var medication = makeMedication(ownerUserRecordName: nil)
        medication.phases[0].repeatEveryDays = 2

        let doseCounts = (0...4).map { dayOffset in
            let date = calendar.date(byAdding: .day, value: dayOffset, to: medication.startDate)!
            return ScheduleEngine.doses(on: date, medication: medication, calendar: calendar).count
        }

        XCTAssertEqual(doseCounts, [1, 0, 1, 0, 1])
    }

    func testScheduleEngineRestartsRepeatIntervalForNewPhase() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var medication = makeMedication(ownerUserRecordName: nil)
        let dose = medication.phases[0].doses[0]
        medication.phases = [
            PlanPhase(title: "Fáze 1", durationDays: 2, doses: [dose], repeatEveryDays: 2),
            PlanPhase(title: "Fáze 2", durationDays: nil, doses: [dose], repeatEveryDays: 3)
        ]

        let generatedPhases = (0...5).map { dayOffset -> String? in
            let date = calendar.date(byAdding: .day, value: dayOffset, to: medication.startDate)!
            return ScheduleEngine.doses(on: date, medication: medication, calendar: calendar).first?.phaseTitle
        }

        XCTAssertEqual(generatedPhases, ["Fáze 1", nil, "Fáze 2", nil, nil, "Fáze 2"])
    }

    func testScheduleEngineGeneratesSyrupDoseWithMilliliterAmount() {
        let time = DoseTime(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            label: "Ráno",
            time: TimeOfDay(hour: 7, minute: 0)
        )
        let medication = Medication(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Sirup",
            note: "",
            form: .syrup,
            colorHex: "#2F80ED",
            startDate: Date(timeIntervalSince1970: 1_725_753_600),
            doseTimes: [time],
            phases: [
                PlanPhase(
                    title: "Základní dávkování",
                    durationDays: nil,
                    doses: [DoseEntry(timeId: time.id, amount: 6)]
                )
            ]
        )

        let doses = ScheduleEngine.doses(on: Date(timeIntervalSince1970: 1_725_776_400), medication: medication)

        XCTAssertEqual(doses.map(\.amount), ["6ml"])
        XCTAssertEqual(doses.first?.medicationForm, .syrup)
    }

    func testMemberIdentityRulesKeepLegacyPersonalMemberWhenClaimingOldConfirmations() {
        let stableId = MemberIdentityRules.memberId(forUserRecordName: "record-a")
        let legacyId = MemberIdentityRules.memberIdForNewGroup(
            userRecordName: "record-a",
            membersAreEmpty: true,
            hasLegacyPersonalConfirmations: true
        )
        let normalId = MemberIdentityRules.memberIdForNewGroup(
            userRecordName: "record-a",
            membersAreEmpty: false,
            hasLegacyPersonalConfirmations: true
        )

        XCTAssertEqual(legacyId, MemberIdentityRules.legacyPersonalConfirmationMemberId)
        XCTAssertEqual(normalId, stableId)
    }

    func testMemberIdentityRulesBuildCurrentUserMemberForSaving() {
        let member = MemberIdentityRules.currentUserMemberForSaving(
            displayName: "  Tata  ",
            userRecordName: "record-a",
            currentMember: nil,
            memberCount: 1,
            membersAreEmpty: false,
            hasLegacyPersonalConfirmations: false
        )

        XCTAssertEqual(member.id, MemberIdentityRules.memberId(forUserRecordName: "record-a"))
        XCTAssertEqual(member.displayName, "Tata")
        XCTAssertEqual(member.colorHex, MemberIdentityRules.memberColors[1])
        XCTAssertEqual(member.userRecordName, "record-a")
    }

    func testAlarmSchedulingRulesScheduleFutureRepeatsForLateSyncedDose() {
        let dose = makeDose(scheduledDate: Date(timeIntervalSince1970: 1_725_778_800))
        let settings = AlarmSettings(repeatIntervalMinutes: 15, repeatDurationMinutes: 45, repeatingDoseLimit: 1)
        let calendar = Calendar(identifier: .gregorian)

        let alarms = AlarmSchedulingRules.upcomingAlarms(
            now: Date(timeIntervalSince1970: 1_725_779_400),
            settings: settings,
            dosesForDate: { date in calendar.isDate(date, inSameDayAs: dose.scheduledDate) ? [dose] : [] },
            confirmationForDose: { _ in nil },
            calendar: calendar
        )

        XCTAssertEqual(alarms.map(\.scheduledDate), [
            Date(timeIntervalSince1970: 1_725_779_700),
            Date(timeIntervalSince1970: 1_725_780_600),
            Date(timeIntervalSince1970: 1_725_781_500)
        ])
        XCTAssertEqual(alarms.map(\.repeatIndex), [1, 2, 3])
    }

    func testAlarmSchedulingRulesSkipConfirmedDose() {
        let dose = makeDose(scheduledDate: Date(timeIntervalSince1970: 1_725_778_800))
        let confirmation = DoseBusinessRules.makeConfirmation(
            for: dose,
            status: .confirmed,
            memberId: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )

        let alarms = AlarmSchedulingRules.upcomingAlarms(
            now: Date(timeIntervalSince1970: 1_725_778_700),
            settings: .defaultValue,
            dosesForDate: { _ in [dose] },
            confirmationForDose: { _ in confirmation },
            calendar: Calendar(identifier: .gregorian)
        )

        XCTAssertTrue(alarms.isEmpty)
    }

    func testAlarmSchedulingRulesGroupEveryAlarmInTheSameMinute() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDate = Date(timeIntervalSince1970: 1_725_778_800)
        let firstDose = makeDose(id: "dose-a", scheduledDate: firstDate)
        let secondDose = makeDose(id: "dose-b", scheduledDate: firstDate.addingTimeInterval(30))
        let nextMinuteDose = makeDose(id: "dose-c", scheduledDate: firstDate.addingTimeInterval(60))

        let groups = AlarmSchedulingRules.groupedByMinute(
            [
                ScheduledDoseAlarm(dose: nextMinuteDose, scheduledDate: nextMinuteDose.scheduledDate, repeatIndex: 0),
                ScheduledDoseAlarm(dose: secondDose, scheduledDate: secondDose.scheduledDate, repeatIndex: 1),
                ScheduledDoseAlarm(dose: firstDose, scheduledDate: firstDose.scheduledDate, repeatIndex: 0)
            ],
            calendar: calendar
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].scheduledDate, firstDate)
        XCTAssertEqual(groups[0].alarms.map(\.dose.id), ["dose-a", "dose-b"])
        XCTAssertEqual(groups[1].alarms.map(\.dose.id), ["dose-c"])
    }

    func testAddingPhaseStartingTodayClosesOpenPhaseAtToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let medication = makeMedication(ownerUserRecordName: nil)
        let today = calendar.date(byAdding: .day, value: 2, to: medication.startDate)!

        var updated = MedicationPhaseEditingUseCase.addingPhaseStartingToday(
            to: medication,
            title: "Nová fáze",
            now: today,
            calendar: calendar
        )
        updated.phases[1].doses[0].amount = 2

        let todaysDoses = ScheduleEngine.doses(on: today, medication: updated, calendar: calendar)
        let previousDay = calendar.date(byAdding: .day, value: -1, to: today)!
        let previousDoses = ScheduleEngine.doses(on: previousDay, medication: updated, calendar: calendar)

        XCTAssertEqual(updated.phases.map(\.durationDays), [2, nil])
        XCTAssertEqual(previousDoses.first?.phaseTitle, "Základní dávkování")
        XCTAssertEqual(todaysDoses.first?.phaseTitle, "Nová fáze")
    }

    func testNewMedicationPhasesUseSequentialDefaultTitles() {
        let medication = MedicationFactory.newMedication()

        let updated = MedicationPhaseEditingUseCase.addingPhaseStartingToday(
            to: medication,
            now: medication.startDate
        )

        XCTAssertEqual(updated.phases.map(\.title), ["Fáze 1", "Fáze 2"])
    }

    func testAddingPhaseStartingTodayCanReplacePhaseStartedToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let medication = makeMedication(ownerUserRecordName: nil)

        var updated = MedicationPhaseEditingUseCase.addingPhaseStartingToday(
            to: medication,
            title: "Nová fáze",
            now: medication.startDate,
            calendar: calendar
        )
        updated.phases[1].doses[0].amount = 2

        let todaysDoses = ScheduleEngine.doses(on: medication.startDate, medication: updated, calendar: calendar)

        XCTAssertEqual(updated.phases.map(\.durationDays), [0, nil])
        XCTAssertEqual(todaysDoses.first?.phaseTitle, "Nová fáze")
    }

    private func makeDose(
        id: String? = nil,
        baseEventId: String? = nil,
        workspaceId: String = "personal",
        scheduledDate: Date
    ) -> GeneratedDose {
        let medicationId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let timeId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let eventId = baseEventId ?? ScheduleEngine.eventId(medicationId: medicationId, timeId: timeId, scheduledDate: scheduledDate)

        return GeneratedDose(
            id: id ?? eventId,
            baseEventId: eventId,
            workspaceId: workspaceId,
            isShared: workspaceId != "personal",
            workspaceName: workspaceId,
            medicationId: medicationId,
            medicationName: "Vitamin",
            medicationNote: "",
            medicationColorHex: "#2F80ED",
            timeId: timeId,
            timeLabel: "Ráno",
            scheduledDate: scheduledDate,
            scheduledTime: TimeOfDay(hour: 7, minute: 0),
            amount: "1",
            phaseTitle: "Základní dávkování"
        )
    }

    private func makeMedication(ownerUserRecordName: String?) -> Medication {
        let time = DoseTime(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            label: "Ráno",
            time: TimeOfDay(hour: 7, minute: 0)
        )
        return Medication(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Vitamin",
            note: "",
            colorHex: "#2F80ED",
            startDate: Date(timeIntervalSince1970: 1_725_753_600),
            doseTimes: [time],
            phases: [
                PlanPhase(
                    title: "Základní dávkování",
                    durationDays: nil,
                    doses: [DoseEntry(timeId: time.id, amount: 1)]
                )
            ],
            ownerUserRecordName: ownerUserRecordName
        )
    }

    private func makeConfirmation(medicationId: UUID, timeId: UUID) -> DoseConfirmation {
        DoseConfirmation(
            eventId: "\(medicationId.uuidString)-\(timeId.uuidString)-20240908",
            medicationId: medicationId,
            timeId: timeId,
            scheduledDate: Date(timeIntervalSince1970: 1_725_776_400),
            amount: "1",
            status: .confirmed,
            memberId: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            memberName: "",
            timestamp: Date(timeIntervalSince1970: 1_725_777_000),
            note: ""
        )
    }
}
