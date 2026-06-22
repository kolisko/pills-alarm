import Foundation

public struct MedicationStateEntry: Hashable, Sendable {
    public var medication: Medication
    public var workspaceId: String
    public var source: WorkspaceSource

    public init(medication: Medication, workspaceId: String, source: WorkspaceSource) {
        self.medication = medication
        self.workspaceId = workspaceId
        self.source = source
    }
}

public final class MedicationDomainStore {
    private var medicationsById: [UUID: Medication] = [:]
    private var medicationWorkspaceIdsById: [UUID: String] = [:]
    private var medicationSourcesById: [UUID: WorkspaceSource] = [:]
    private let confirmationState = ConfirmationStateStore()

    public init() {}

    public var medicationItems: [MedicationListItem] {
        medicationsById.values
            .compactMap { medication -> MedicationListItem? in
                guard let source = medicationSourcesById[medication.id] else { return nil }
                return MedicationListItem(medication: medication, source: source)
            }
            .sorted(by: Self.sortMedicationItems)
    }

    public var medications: [Medication] {
        medicationItems.map(\.medication)
    }

    public var confirmations: [String: DoseConfirmation] {
        confirmationState.confirmations
    }

    public var confirmationItems: [ConfirmationListItem] {
        confirmationState.confirmationItems
    }

    public var allConfirmations: [DoseConfirmation] {
        confirmationState.allConfirmations
    }

    public func workspaceId(forMedicationId medicationId: UUID) -> String? {
        medicationWorkspaceIdsById[medicationId]
    }

    public func workspaceId(forConfirmationEventId eventId: String) -> String? {
        confirmationState.workspaceId(for: eventId)
    }

    public func confirmation(for dose: GeneratedDose) -> DoseConfirmation? {
        confirmationState.confirmation(for: dose)
    }

    public func confirmations(forMedicationId medicationId: UUID, in workspaceId: String) -> [DoseConfirmation] {
        confirmationState.confirmations(for: medicationId, in: workspaceId)
    }

    public func reset() {
        medicationsById = [:]
        medicationWorkspaceIdsById = [:]
        medicationSourcesById = [:]
        confirmationState.reset()
    }

    public func replace(medications: [MedicationStateEntry], confirmations: [ConfirmationStateEntry]) {
        reset()
        for entry in medications {
            upsertMedication(entry.medication, workspaceId: entry.workspaceId, source: entry.source)
        }
        for entry in confirmations {
            upsertConfirmation(entry.confirmation, workspaceId: entry.workspaceId, source: entry.source)
        }
    }

    public func upsertMedication(_ medication: Medication, workspaceId: String, source: WorkspaceSource) {
        medicationsById[medication.id] = medication
        medicationWorkspaceIdsById[medication.id] = workspaceId
        medicationSourcesById[medication.id] = source
    }

    public func removeMedication(id: UUID) {
        medicationsById.removeValue(forKey: id)
        medicationWorkspaceIdsById.removeValue(forKey: id)
        medicationSourcesById.removeValue(forKey: id)
    }

    public func upsertConfirmation(_ confirmation: DoseConfirmation, workspaceId: String, source: WorkspaceSource) {
        confirmationState.upsert(confirmation, workspaceId: workspaceId, source: source)
    }

    public func removeConfirmations(eventIds: [String]) {
        confirmationState.remove(eventIds: eventIds)
    }

    public func removeConfirmations(forMedicationId medicationId: UUID) {
        confirmationState.removeConfirmations(forMedicationId: medicationId)
    }

    public func applySharingChange(
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
