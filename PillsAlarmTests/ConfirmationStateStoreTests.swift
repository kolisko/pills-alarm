import XCTest
@testable import PillsAlarm

final class ConfirmationStateStoreTests: XCTestCase {
    func testFindsConfirmationForGeneratedDose() {
        let store = ConfirmationStateStore()
        let dose = makeDose()
        let confirmation = makeConfirmation(for: dose)

        store.upsert(confirmation, workspaceId: "personal", source: WorkspaceSource(id: "personal", name: "Vlastní", isShared: false))

        XCTAssertEqual(store.confirmation(for: dose), confirmation)
        XCTAssertEqual(store.workspaceId(for: confirmation.eventId), "personal")
        XCTAssertEqual(store.confirmations(for: dose.medicationId, in: "personal"), [confirmation])
        XCTAssertTrue(store.confirmations(for: dose.medicationId, in: "shared").isEmpty)
    }

    func testMoveConfirmationsTransfersMedicationStateToDestinationWorkspace() {
        let store = ConfirmationStateStore()
        let dose = makeDose()
        let original = makeConfirmation(for: dose)
        let personal = WorkspaceSource(id: "personal", name: "Vlastní", isShared: false)
        let shared = WorkspaceSource(id: "shared", name: "Rodina", isShared: true)

        store.upsert(original, workspaceId: personal.id, source: personal)
        let result = store.moveConfirmations(
            forMedicationId: dose.medicationId,
            from: personal.id,
            to: shared.id,
            destinationSource: shared
        ) { confirmation in
            var updated = confirmation
            updated.eventId = "shared-\(confirmation.eventId)"
            return updated
        }

        XCTAssertEqual(result.originalEventIds, [original.eventId])
        XCTAssertEqual(result.updatedConfirmations.map(\.eventId), ["shared-\(original.eventId)"])
        XCTAssertTrue(store.confirmations(for: dose.medicationId, in: personal.id).isEmpty)
        XCTAssertEqual(store.confirmations(for: dose.medicationId, in: shared.id), result.updatedConfirmations)
        XCTAssertEqual(store.confirmationItems.map(\.source), [shared])
    }

    func testRemoveMedicationConfirmationsClearsIndexesAndHistoryProjection() {
        let store = ConfirmationStateStore()
        let dose = makeDose()
        let confirmation = makeConfirmation(for: dose)

        store.upsert(confirmation, workspaceId: "personal", source: WorkspaceSource(id: "personal", name: "Vlastní", isShared: false))
        store.removeConfirmations(forMedicationId: dose.medicationId)

        XCTAssertNil(store.confirmation(for: dose))
        XCTAssertNil(store.workspaceId(for: confirmation.eventId))
        XCTAssertTrue(store.confirmationItems.isEmpty)
    }

    private func makeDose() -> GeneratedDose {
        let medicationId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let timeId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let date = Date(timeIntervalSince1970: 1_725_776_400)
        let eventId = ScheduleEngine.eventId(medicationId: medicationId, timeId: timeId, scheduledDate: date)

        return GeneratedDose(
            id: eventId,
            baseEventId: eventId,
            workspaceId: "personal",
            isShared: false,
            workspaceName: "Vlastní",
            medicationId: medicationId,
            medicationName: "Vitamin",
            medicationNote: "",
            medicationColorHex: "#2F80ED",
            timeId: timeId,
            timeLabel: "Ráno",
            scheduledDate: date,
            scheduledTime: TimeOfDay(hour: 7, minute: 0),
            amount: "1",
            phaseTitle: "Základní dávkování"
        )
    }

    private func makeConfirmation(for dose: GeneratedDose) -> DoseConfirmation {
        DoseConfirmation(
            eventId: dose.baseEventId,
            medicationId: dose.medicationId,
            timeId: dose.timeId,
            scheduledDate: dose.scheduledDate,
            amount: dose.amount,
            status: .confirmed,
            memberId: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            memberName: "",
            timestamp: Date(timeIntervalSince1970: 1_725_777_000),
            note: ""
        )
    }
}
