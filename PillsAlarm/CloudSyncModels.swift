import CloudKit
import Foundation

enum WorkspaceSyncMode {
    case incremental
    case fullRecovery
}

struct WorkspaceSyncResult {
    var snapshots: [CloudSnapshot]
    var hasDataChanges: Bool
    var didFullRecovery: Bool
    var subscriptionSnapshots: [CloudSnapshot]
}

struct ZoneChanges {
    var changedRecords: [CKRecord]
    var deletedRecordIDs: [CKRecord.ID]
    var serverChangeToken: CKServerChangeToken?
}

struct ZoneSnapshotResult {
    var snapshot: CloudSnapshot?
    var serverChangeToken: CKServerChangeToken?
}

struct PrivateZoneSnapshotResult {
    var snapshots: [CloudSnapshot]
    var serverChangeToken: CKServerChangeToken?
}

final class ZoneChangeTokenStore {
    private let defaults: UserDefaults
    private let defaultsKey = "PillCareZoneChangeTokens.v1"
    private var tokenDataByZoneKey: [String: Data]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        tokenDataByZoneKey = defaults.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    func token(for reference: StoredGroupReference) -> CKServerChangeToken? {
        guard let data = tokenDataByZoneKey[zoneKey(for: reference)] else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    func set(_ token: CKServerChangeToken, for reference: StoredGroupReference) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
            return
        }

        tokenDataByZoneKey[zoneKey(for: reference)] = data
        save()
    }

    func removeToken(for reference: StoredGroupReference) {
        tokenDataByZoneKey.removeValue(forKey: zoneKey(for: reference))
        save()
    }

    private func zoneKey(for reference: StoredGroupReference) -> String {
        "\(reference.databaseScope)|\(reference.ownerName)|\(reference.zoneName)"
    }

    private func save() {
        defaults.set(tokenDataByZoneKey, forKey: defaultsKey)
    }
}
