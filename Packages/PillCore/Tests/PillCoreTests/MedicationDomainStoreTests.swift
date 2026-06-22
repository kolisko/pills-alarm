import XCTest
@testable import PillCore

final class MedicationDomainStoreTests: XCTestCase {
    func testPublishesMedicationAndConfirmationProjectionsFromOneDomainState() {
        let store = MedicationDomainStore()
        let source = WorkspaceSource(id: "personal", name: "Vlastní", isShared: false)
        let medication = makeMedication(name: "Vitamin")
        let confirmation = makeConfirmation(medicationId: medication.id, timeId: medication.doseTimes[0].id)

        store.replace(
            medications: [MedicationStateEntry(medication: medication, workspaceId: source.id, source: source)],
            confirmations: [ConfirmationStateEntry(confirmation: confirmation, workspaceId: source.id, source: source)]
        )

        XCTAssertEqual(store.medications, [medication])
        XCTAssertEqual(store.medicationItems, [MedicationListItem(medication: medication, source: source)])
        XCTAssertEqual(store.confirmations[confirmation.eventId], confirmation)
        XCTAssertEqual(store.confirmationItems, [ConfirmationListItem(confirmation: confirmation, source: source)])
        XCTAssertEqual(store.workspaceId(forMedicationId: medication.id), source.id)
        XCTAssertEqual(store.workspaceId(forConfirmationEventId: confirmation.eventId), source.id)
    }

    func testSharingChangeMovesMedicationAndKeepsConfirmationStateWithDestinationSource() {
        let store = MedicationDomainStore()
        let personal = WorkspaceSource(id: "personal", name: "Vlastní", isShared: false)
        let shared = WorkspaceSource(id: "shared", name: "Rodina", isShared: true)
        var medication = makeMedication(name: "Vitamin")
        let originalConfirmation = makeConfirmation(medicationId: medication.id, timeId: medication.doseTimes[0].id)

        store.replace(
            medications: [MedicationStateEntry(medication: medication, workspaceId: personal.id, source: personal)],
            confirmations: [ConfirmationStateEntry(confirmation: originalConfirmation, workspaceId: personal.id, source: personal)]
        )

        medication.sharedGroupId = shared.id
        var movedConfirmation = originalConfirmation
        movedConfirmation.eventId = "moved-\(originalConfirmation.eventId)"

        store.applySharingChange(
            medication: medication,
            updatedConfirmations: [movedConfirmation],
            originalConfirmationEventIds: [originalConfirmation.eventId],
            destinationWorkspaceId: shared.id,
            destinationSource: shared
        )

        XCTAssertEqual(store.workspaceId(forMedicationId: medication.id), shared.id)
        XCTAssertEqual(store.medicationItems, [MedicationListItem(medication: medication, source: shared)])
        XCTAssertNil(store.confirmations[originalConfirmation.eventId])
        XCTAssertEqual(store.confirmations[movedConfirmation.eventId], movedConfirmation)
        XCTAssertEqual(store.confirmationItems, [ConfirmationListItem(confirmation: movedConfirmation, source: shared)])
    }

    private func makeMedication(name: String) -> Medication {
        let time = DoseTime(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            label: "Ráno",
            time: TimeOfDay(hour: 7, minute: 0)
        )
        return Medication(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: name,
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
            ]
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
