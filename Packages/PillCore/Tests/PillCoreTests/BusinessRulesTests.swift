import XCTest
@testable import PillCore

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
        XCTAssertEqual(medication.phases.first?.title, "Základní dávkování")
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
