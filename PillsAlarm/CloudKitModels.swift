import CloudKit
import Foundation
import PillCore

struct CloudSharingController: Identifiable {
    var id: CKRecord.ID { share.recordID }
    let share: CKShare
    let groupRecord: CKRecord
    let database: CKDatabase
    let title: String
}

struct CloudSharePreparation {
    var groupRecord: CKRecord
    var share: CKShare
}

struct CloudSnapshot {
    var group: CKRecord
    var database: CKDatabase
    var databaseScope: CKDatabase.Scope
    var name: String
    var members: [CareMember]
    var medications: [Medication]
    var confirmations: [DoseConfirmation]

    var isEmpty: Bool {
        members.isEmpty && medications.isEmpty && confirmations.isEmpty
    }
}

struct WorkspaceContext {
    var id: String
    var reference: StoredGroupReference
    var source: WorkspaceSource
    var groupRecord: CKRecord
    var database: CKDatabase
    var databaseScope: CKDatabase.Scope
    var name: String
    var members: [CareMember]
    var medications: [Medication]
    var confirmations: [DoseConfirmation]

    var isShared: Bool {
        databaseScope == .shared
    }

    init(snapshot: CloudSnapshot) {
        let reference = StoredGroupReference(
            recordName: snapshot.group.recordID.recordName,
            zoneName: snapshot.group.recordID.zoneID.zoneName,
            ownerName: snapshot.group.recordID.zoneID.ownerName,
            databaseScope: snapshot.databaseScope.rawValue
        )
        self.reference = reference
        id = reference.id
        source = WorkspaceSource(
            id: reference.id,
            name: snapshot.name,
            isShared: snapshot.databaseScope == .shared
        )
        groupRecord = snapshot.group
        database = snapshot.database
        databaseScope = snapshot.databaseScope
        name = snapshot.name
        members = snapshot.members
        medications = snapshot.medications
        confirmations = snapshot.confirmations
    }
}

struct WorkspaceCandidate: Identifiable, Equatable {
    var reference: StoredGroupReference
    var name: String
    var databaseScope: Int
    var medicationCount: Int
    var memberCount: Int
    var confirmationCount: Int
    var isActive: Bool

    var id: String { reference.id }

    var typeLabel: String {
        databaseScope == CKDatabase.Scope.shared.rawValue ? "Sdílené" : "Vlastní"
    }

    var canDeleteFromCloud: Bool {
        databaseScope == CKDatabase.Scope.private.rawValue
    }

    init(snapshot: CloudSnapshot, isActive: Bool) {
        reference = StoredGroupReference(
            recordName: snapshot.group.recordID.recordName,
            zoneName: snapshot.group.recordID.zoneID.zoneName,
            ownerName: snapshot.group.recordID.zoneID.ownerName,
            databaseScope: snapshot.databaseScope.rawValue
        )
        name = snapshot.name
        databaseScope = snapshot.databaseScope.rawValue
        medicationCount = snapshot.medications.count
        memberCount = snapshot.members.count
        confirmationCount = snapshot.confirmations.count
        self.isActive = isActive
    }
}

struct StoredGroupReference: Codable, Equatable, Hashable {
    var recordName: String
    var zoneName: String
    var ownerName: String
    var databaseScope: Int

    var id: String {
        "\(databaseScope)|\(ownerName)|\(zoneName)|\(recordName)"
    }
}

enum CloudKitShareError: LocalizedError {
    case invalidExistingShare
    case missingRootRecord
    case unexpectedParticipantStatus(String)
    case acceptedShareUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidExistingShare:
            return "iCloud vrátil neplatný záznam sdílení. Zkus pozvánku otevřít znovu."
        case .missingRootRecord:
            return "iCloud pozvánka neobsahuje kořenový záznam sdílení. Požádej odesílatele o novou pozvánku."
        case .unexpectedParticipantStatus(let status):
            return "iCloud pozvánka má neočekávaný stav účastníka: \(status)."
        case .acceptedShareUnavailable(let reference):
            return "iCloud sdílení bylo přijato, ale sdílený záznam nejde načíst: \(reference)."
        }
    }
}
