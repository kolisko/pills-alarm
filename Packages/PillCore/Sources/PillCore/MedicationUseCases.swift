import Foundation

public struct ConfirmDoseCommand: Equatable, Sendable {
    public var confirmation: DoseConfirmation
    public var eventIdsToCheck: [String]

    public init(confirmation: DoseConfirmation, eventIdsToCheck: [String]) {
        self.confirmation = confirmation
        self.eventIdsToCheck = eventIdsToCheck
    }
}

public enum ConfirmDoseUseCase {
    public static func makeCommand(
        dose: GeneratedDose,
        status: DoseStatus,
        memberId: UUID,
        timestamp: Date = Date(),
        note: String = ""
    ) -> ConfirmDoseCommand {
        let confirmation = DoseBusinessRules.makeConfirmation(
            for: dose,
            status: status,
            memberId: memberId,
            timestamp: timestamp,
            note: note
        )
        return ConfirmDoseCommand(
            confirmation: confirmation,
            eventIdsToCheck: DoseBusinessRules.confirmationEventIds(for: dose, including: confirmation)
        )
    }
}

public enum UndoDoseConfirmationUseCase {
    public static func eventIdsToDelete(for dose: GeneratedDose, existingConfirmation: DoseConfirmation?) -> [String] {
        DoseBusinessRules.confirmationEventIds(for: dose, including: existingConfirmation)
    }
}

public struct MedicationSharingChange: Equatable, Sendable {
    public var medication: Medication
    public var updatedConfirmations: [DoseConfirmation]
    public var originalConfirmationEventIds: [String]
    public var updatedConfirmationEventIds: Set<String>

    public init(
        medication: Medication,
        updatedConfirmations: [DoseConfirmation],
        originalConfirmationEventIds: [String],
        updatedConfirmationEventIds: Set<String>
    ) {
        self.medication = medication
        self.updatedConfirmations = updatedConfirmations
        self.originalConfirmationEventIds = originalConfirmationEventIds
        self.updatedConfirmationEventIds = updatedConfirmationEventIds
    }
}

public enum ShareMedicationUseCase {
    public static func makeChange(
        item: MedicationListItem,
        updatedMedication: Medication?,
        shouldShare: Bool,
        destinationWorkspaceId: String,
        currentUserRecordName: String?,
        sourceConfirmations: [DoseConfirmation]
    ) -> MedicationSharingChange {
        let medication = MedicationSharingRules.medicationForSharingChange(
            updatedMedication ?? item.medication,
            currentUserRecordName: currentUserRecordName,
            shouldShare: shouldShare,
            destinationWorkspaceId: destinationWorkspaceId
        )
        let updatedConfirmations = sourceConfirmations.map(MedicationSharingRules.confirmationForSharingChange)
        return MedicationSharingChange(
            medication: medication,
            updatedConfirmations: updatedConfirmations,
            originalConfirmationEventIds: sourceConfirmations.map(\.eventId),
            updatedConfirmationEventIds: Set(updatedConfirmations.map(\.eventId))
        )
    }
}

public enum UpsertMedicationUseCase {
    public static func medicationForSaving(_ medication: Medication, currentUserRecordName: String?) -> Medication {
        var updated = medication
        updated.ownerUserRecordName = updated.ownerUserRecordName ?? currentUserRecordName
        return updated
    }
}
