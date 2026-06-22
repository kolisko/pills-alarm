import Foundation

public enum MedicationAccessRules {
    public static func canManageMedication(
        _ item: MedicationListItem,
        currentUserRecordName: String?,
        personalWorkspaceId: String?,
        ownedGroupWorkspaceId: String?
    ) -> Bool {
        guard let currentUserRecordName else {
            return false
        }

        if item.medication.ownerUserRecordName == nil {
            return item.source.id == personalWorkspaceId || item.source.id == ownedGroupWorkspaceId
        }

        return item.medication.ownerUserRecordName == currentUserRecordName
    }

    public static func canRecordDose(hasGroup: Bool, currentMemberName: String) -> Bool {
        !hasGroup || !currentMemberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func canRecordDose(
        contextIsShared: Bool,
        contextHasMembers: Bool,
        currentMemberName: String
    ) -> Bool {
        guard contextIsShared || contextHasMembers else {
            return true
        }

        return !currentMemberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
