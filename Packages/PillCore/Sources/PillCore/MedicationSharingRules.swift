import Foundation

public enum MedicationSharingRules {
    public static func medicationForSharingChange(
        _ medication: Medication,
        currentUserRecordName: String?,
        shouldShare: Bool,
        destinationWorkspaceId: String
    ) -> Medication {
        var updated = medication
        updated.ownerUserRecordName = updated.ownerUserRecordName ?? currentUserRecordName
        updated.sharedGroupId = shouldShare ? destinationWorkspaceId : nil
        return updated
    }

    public static func confirmationForSharingChange(_ confirmation: DoseConfirmation) -> DoseConfirmation {
        var updated = confirmation
        updated.eventId = baseEventId(from: confirmation.eventId)
        return updated
    }

    public static func baseEventId(from eventId: String) -> String {
        guard let separator = eventId.range(of: "|", options: .backwards) else {
            return eventId
        }

        return String(eventId[separator.upperBound...])
    }
}
