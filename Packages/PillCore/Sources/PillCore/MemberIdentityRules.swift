import CryptoKit
import Foundation

public enum MemberIdentityRules {
    public static let legacyPersonalConfirmationMemberId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let memberColors = ["#2F80ED", "#27AE60", "#EB5757", "#9B51E0", "#F2994A", "#00A3A3"]

    public static func memberId(forUserRecordName userRecordName: String) -> UUID {
        let digest = SHA256.hash(data: Data(userRecordName.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public static func color(forMemberCount memberCount: Int) -> String {
        memberColors[memberCount % memberColors.count]
    }

    public static func memberIdForNewGroup(
        userRecordName: String,
        membersAreEmpty: Bool,
        hasLegacyPersonalConfirmations: Bool
    ) -> UUID {
        if membersAreEmpty && hasLegacyPersonalConfirmations {
            return legacyPersonalConfirmationMemberId
        }

        return memberId(forUserRecordName: userRecordName)
    }

    public static func currentUserMemberForSaving(
        displayName: String,
        userRecordName: String,
        currentMember: CareMember?,
        memberCount: Int,
        membersAreEmpty: Bool,
        hasLegacyPersonalConfirmations: Bool
    ) -> CareMember {
        CareMember(
            id: currentMember?.id ?? memberIdForNewGroup(
                userRecordName: userRecordName,
                membersAreEmpty: membersAreEmpty,
                hasLegacyPersonalConfirmations: hasLegacyPersonalConfirmations
            ),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            colorHex: currentMember?.colorHex ?? color(forMemberCount: memberCount),
            userRecordName: userRecordName
        )
    }
}
