import Foundation

public enum DoseActionSettings {
    public static let actionLeadTimeMinutesKey = "doseAction.actionLeadTimeMinutes.v1"
    public static let defaultActionLeadTimeMinutes = 15
    public static let minimumActionLeadTimeMinutes = 0
    public static let maximumActionLeadTimeMinutes = 240

    public static func normalizedActionLeadTimeMinutes(_ value: Int) -> Int {
        min(max(value, minimumActionLeadTimeMinutes), maximumActionLeadTimeMinutes)
    }
}

public struct DosePresentationState: Equatable, Sendable {
    public var confirmation: DoseConfirmation?
    public var showsMemberWarning: Bool
    public var showsActions: Bool
    public var isLockedFutureDose: Bool
    public var isResolved: Bool
    public var isSubdued: Bool
    public var isOverdueToday: Bool

    public init(
        confirmation: DoseConfirmation?,
        showsMemberWarning: Bool,
        showsActions: Bool,
        isLockedFutureDose: Bool,
        isResolved: Bool,
        isSubdued: Bool,
        isOverdueToday: Bool
    ) {
        self.confirmation = confirmation
        self.showsMemberWarning = showsMemberWarning
        self.showsActions = showsActions
        self.isLockedFutureDose = isLockedFutureDose
        self.isResolved = isResolved
        self.isSubdued = isSubdued
        self.isOverdueToday = isOverdueToday
    }
}

public enum DoseBusinessRules {
    public static func confirmationEventIds(for dose: GeneratedDose, including confirmation: DoseConfirmation? = nil) -> [String] {
        var eventIds: [String] = []
        let legacyWorkspaceEventId = dose.workspaceId.isEmpty ? nil : "\(dose.workspaceId)|\(dose.baseEventId)"
        for eventId in [dose.id, dose.baseEventId, legacyWorkspaceEventId, confirmation?.eventId].compactMap({ $0 }) {
            if !eventIds.contains(eventId) {
                eventIds.append(eventId)
            }
        }
        return eventIds
    }

    public static func makeConfirmation(
        for dose: GeneratedDose,
        status: DoseStatus,
        memberId: UUID,
        timestamp: Date = Date(),
        note: String = ""
    ) -> DoseConfirmation {
        DoseConfirmation(
            eventId: dose.baseEventId,
            medicationId: dose.medicationId,
            timeId: dose.timeId,
            scheduledDate: dose.scheduledDate,
            amount: dose.amount,
            status: status,
            memberId: memberId,
            memberName: "",
            timestamp: timestamp,
            note: note
        )
    }

    public static func presentationState(
        for dose: GeneratedDose,
        confirmation: DoseConfirmation?,
        canRecordDose: Bool,
        now: Date,
        actionLeadTimeMinutes: Int,
        calendar: Calendar = .current
    ) -> DosePresentationState {
        let canUseActions = canUseActions(
            for: dose,
            now: now,
            actionLeadTimeMinutes: actionLeadTimeMinutes
        )
        let isResolved = confirmation != nil
        let showsMemberWarning = confirmation == nil && !canRecordDose
        let showsActions = confirmation == nil && canRecordDose && canUseActions
        let isLockedFutureDose = confirmation == nil && !canUseActions
        let isOverdueToday = confirmation == nil
            && calendar.isDateInToday(dose.scheduledDate)
            && dose.scheduledDate < now

        return DosePresentationState(
            confirmation: confirmation,
            showsMemberWarning: showsMemberWarning,
            showsActions: showsActions,
            isLockedFutureDose: isLockedFutureDose,
            isResolved: isResolved,
            isSubdued: isResolved || isLockedFutureDose,
            isOverdueToday: isOverdueToday
        )
    }

    public static func canUseActions(for dose: GeneratedDose, now: Date, actionLeadTimeMinutes: Int) -> Bool {
        let leadTime = DoseActionSettings.normalizedActionLeadTimeMinutes(actionLeadTimeMinutes)
        let activeFrom = dose.scheduledDate.addingTimeInterval(-Double(leadTime) * 60)
        return now >= activeFrom
    }
}
