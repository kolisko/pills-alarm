import Foundation

struct MedicationStateEntry: Hashable {
    var medication: Medication
    var workspaceId: String
    var source: WorkspaceSource
}

final class MedicationDomainStore {
    private var medicationsById: [UUID: Medication] = [:]
    private var medicationWorkspaceIdsById: [UUID: String] = [:]
    private var medicationSourcesById: [UUID: WorkspaceSource] = [:]
    private let confirmationState = ConfirmationStateStore()

    var medicationItems: [MedicationListItem] {
        medicationsById.values
            .compactMap { medication -> MedicationListItem? in
                guard let source = medicationSourcesById[medication.id] else { return nil }
                return MedicationListItem(medication: medication, source: source)
            }
            .sorted(by: Self.sortMedicationItems)
    }

    var medications: [Medication] {
        medicationItems.map(\.medication)
    }

    var confirmations: [String: DoseConfirmation] {
        confirmationState.confirmations
    }

    var confirmationItems: [ConfirmationListItem] {
        confirmationState.confirmationItems
    }

    var allConfirmations: [DoseConfirmation] {
        confirmationState.allConfirmations
    }

    func workspaceId(forMedicationId medicationId: UUID) -> String? {
        medicationWorkspaceIdsById[medicationId]
    }

    func workspaceId(forConfirmationEventId eventId: String) -> String? {
        confirmationState.workspaceId(for: eventId)
    }

    func confirmation(for dose: GeneratedDose) -> DoseConfirmation? {
        confirmationState.confirmation(for: dose)
    }

    func confirmations(forMedicationId medicationId: UUID, in workspaceId: String) -> [DoseConfirmation] {
        confirmationState.confirmations(for: medicationId, in: workspaceId)
    }

    func reset() {
        medicationsById = [:]
        medicationWorkspaceIdsById = [:]
        medicationSourcesById = [:]
        confirmationState.reset()
    }

    func replace(medications: [MedicationStateEntry], confirmations: [ConfirmationStateEntry]) {
        reset()
        for entry in medications {
            upsertMedication(entry.medication, workspaceId: entry.workspaceId, source: entry.source)
        }
        for entry in confirmations {
            upsertConfirmation(entry.confirmation, workspaceId: entry.workspaceId, source: entry.source)
        }
    }

    func upsertMedication(_ medication: Medication, workspaceId: String, source: WorkspaceSource) {
        medicationsById[medication.id] = medication
        medicationWorkspaceIdsById[medication.id] = workspaceId
        medicationSourcesById[medication.id] = source
    }

    func removeMedication(id: UUID) {
        medicationsById.removeValue(forKey: id)
        medicationWorkspaceIdsById.removeValue(forKey: id)
        medicationSourcesById.removeValue(forKey: id)
    }

    func upsertConfirmation(_ confirmation: DoseConfirmation, workspaceId: String, source: WorkspaceSource) {
        confirmationState.upsert(confirmation, workspaceId: workspaceId, source: source)
    }

    func removeConfirmations(eventIds: [String]) {
        confirmationState.remove(eventIds: eventIds)
    }

    func removeConfirmations(forMedicationId medicationId: UUID) {
        confirmationState.removeConfirmations(forMedicationId: medicationId)
    }

    func applySharingChange(
        medication: Medication,
        updatedConfirmations: [DoseConfirmation],
        originalConfirmationEventIds: [String],
        destinationWorkspaceId: String,
        destinationSource: WorkspaceSource
    ) {
        upsertMedication(medication, workspaceId: destinationWorkspaceId, source: destinationSource)
        confirmationState.remove(eventIds: originalConfirmationEventIds)
        for confirmation in updatedConfirmations {
            confirmationState.upsert(confirmation, workspaceId: destinationWorkspaceId, source: destinationSource)
        }
    }

    private static func sortMedicationItems(_ lhs: MedicationListItem, _ rhs: MedicationListItem) -> Bool {
        if lhs.source.isShared != rhs.source.isShared {
            return !lhs.source.isShared
        }
        return lhs.medication.name.localizedCaseInsensitiveCompare(rhs.medication.name) == .orderedAscending
    }
}
