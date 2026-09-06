import Foundation

public struct ConfirmDoseCommand: Equatable, Sendable {
    public var confirmation: DoseConfirmation
    public var eventIdsToCheck: [String]

    public init(confirmation: DoseConfirmation, eventIdsToCheck: [String]) {
        self.confirmation = confirmation
        self.eventIdsToCheck = eventIdsToCheck
    }
}

public struct ConfirmDoseResult: Equatable, Sendable {
    public let confirmation: DoseConfirmation
    public let requestedStatus: DoseStatus

    public var hasStatusConflict: Bool { confirmation.status != requestedStatus }

    public init(confirmation: DoseConfirmation, requestedStatus: DoseStatus) {
        self.confirmation = confirmation
        self.requestedStatus = requestedStatus
    }
}

public enum ConfirmDoseUseCase {
    @MainActor
    public static func execute(
        command: ConfirmDoseCommand,
        fetchConfirmation: (String) async throws -> DoseConfirmation?,
        createIfAbsent: (DoseConfirmation) async throws -> DoseConfirmation
    ) async throws -> ConfirmDoseResult {
        // Keep recognizing legacy event IDs, but protect the canonical write on the server too.
        for eventId in command.eventIdsToCheck {
            if let existing = try await fetchConfirmation(eventId) {
                return ConfirmDoseResult(confirmation: existing, requestedStatus: command.confirmation.status)
            }
        }
        let saved = try await createIfAbsent(command.confirmation)
        return ConfirmDoseResult(confirmation: saved, requestedStatus: command.confirmation.status)
    }

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

public enum MedicationPhaseEditingUseCase {
    public static func addingPhaseStartingToday(
        to medication: Medication,
        title: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Medication {
        var updated = medication
        if let openPhaseIndex = updated.phases.indices.last(where: { updated.phases[$0].durationDays == nil }),
           let duration = durationFromPhaseStartToToday(
            phaseIndex: openPhaseIndex,
            medication: updated,
            now: now,
            calendar: calendar
           ) {
            updated.phases[openPhaseIndex].durationDays = max(0, duration)
        }

        updated.phases.append(
            PlanPhase(
                title: title ?? "Fáze \(updated.phases.count + 1)",
                durationDays: nil,
                doses: updated.doseTimes.map { DoseEntry(timeId: $0.id, amount: 0) }
            )
        )
        return updated
    }

    private static func durationFromPhaseStartToToday(
        phaseIndex: Array<PlanPhase>.Index,
        medication: Medication,
        now: Date,
        calendar: Calendar
    ) -> Int? {
        let planStart = calendar.startOfDay(for: medication.startDate)
        let today = calendar.startOfDay(for: now)
        guard let todayOffset = calendar.dateComponents([.day], from: planStart, to: today).day,
              todayOffset >= 0
        else {
            return nil
        }

        let phaseStartOffset = medication.phases[..<phaseIndex].reduce(0) { total, phase in
            total + (phase.durationDays ?? 0)
        }

        return todayOffset - phaseStartOffset
    }
}
