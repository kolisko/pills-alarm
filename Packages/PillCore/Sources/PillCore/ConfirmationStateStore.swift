import Foundation

public struct ConfirmationStateEntry: Hashable, Sendable {
    public var confirmation: DoseConfirmation
    public var workspaceId: String
    public var source: WorkspaceSource

    public init(confirmation: DoseConfirmation, workspaceId: String, source: WorkspaceSource) {
        self.confirmation = confirmation
        self.workspaceId = workspaceId
        self.source = source
    }
}

public final class ConfirmationStateStore {
    private var confirmationsByEventId: [String: DoseConfirmation] = [:]
    private var workspaceIdsByEventId: [String: String] = [:]
    private var sourcesByEventId: [String: WorkspaceSource] = [:]

    public init() {}

    public var confirmations: [String: DoseConfirmation] {
        confirmationsByEventId
    }

    public var confirmationItems: [ConfirmationListItem] {
        confirmationsByEventId.values
            .compactMap { confirmation -> ConfirmationListItem? in
                guard let source = sourcesByEventId[confirmation.eventId] else { return nil }
                return ConfirmationListItem(confirmation: confirmation, source: source)
            }
            .sorted { $0.confirmation.timestamp > $1.confirmation.timestamp }
    }

    public var allConfirmations: [DoseConfirmation] {
        Array(confirmationsByEventId.values)
    }

    public func workspaceId(for eventId: String) -> String? {
        workspaceIdsByEventId[eventId]
    }

    public func confirmation(for dose: GeneratedDose) -> DoseConfirmation? {
        confirmationsByEventId[dose.id]
            ?? confirmationsByEventId[dose.baseEventId]
            ?? confirmationsByEventId.values.first { Self.matches($0, dose: dose) }
    }

    public func confirmations(for medicationId: UUID, in workspaceId: String) -> [DoseConfirmation] {
        confirmationsByEventId.values.filter {
            $0.medicationId == medicationId && workspaceIdsByEventId[$0.eventId] == workspaceId
        }
    }

    public func containsMemberId(_ memberId: UUID) -> Bool {
        confirmationsByEventId.values.contains { $0.memberId == memberId }
    }

    public func reset() {
        confirmationsByEventId = [:]
        workspaceIdsByEventId = [:]
        sourcesByEventId = [:]
    }

    public func replace(with entries: [ConfirmationStateEntry]) {
        reset()
        for entry in entries {
            upsert(entry.confirmation, workspaceId: entry.workspaceId, source: entry.source)
        }
    }

    public func upsert(_ confirmation: DoseConfirmation, workspaceId: String, source: WorkspaceSource) {
        confirmationsByEventId[confirmation.eventId] = confirmation
        workspaceIdsByEventId[confirmation.eventId] = workspaceId
        sourcesByEventId[confirmation.eventId] = source
    }

    public func remove(eventIds: [String]) {
        for eventId in eventIds {
            confirmationsByEventId.removeValue(forKey: eventId)
            workspaceIdsByEventId.removeValue(forKey: eventId)
            sourcesByEventId.removeValue(forKey: eventId)
        }
    }

    public func removeConfirmations(forMedicationId medicationId: UUID) {
        let eventIds = confirmationsByEventId.values
            .filter { $0.medicationId == medicationId }
            .map(\.eventId)
        remove(eventIds: eventIds)
    }

    public func moveConfirmations(
        forMedicationId medicationId: UUID,
        from sourceWorkspaceId: String,
        to destinationWorkspaceId: String,
        destinationSource: WorkspaceSource,
        transform: (DoseConfirmation) -> DoseConfirmation
    ) -> (updatedConfirmations: [DoseConfirmation], originalEventIds: [String]) {
        let sourceConfirmations = confirmations(for: medicationId, in: sourceWorkspaceId)
        let originalEventIds = sourceConfirmations.map(\.eventId)
        let updatedConfirmations = sourceConfirmations.map(transform)

        remove(eventIds: originalEventIds)
        for confirmation in updatedConfirmations {
            upsert(confirmation, workspaceId: destinationWorkspaceId, source: destinationSource)
        }

        return (updatedConfirmations, originalEventIds)
    }

    public static func matches(_ confirmation: DoseConfirmation, dose: GeneratedDose) -> Bool {
        confirmation.medicationId == dose.medicationId
            && confirmation.timeId == dose.timeId
            && Calendar.current.isDate(confirmation.scheduledDate, inSameDayAs: dose.scheduledDate)
    }
}
