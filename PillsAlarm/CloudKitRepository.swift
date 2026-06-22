import CloudKit
import Foundation
import PillCore

@MainActor
final class CloudKitRepository {
    nonisolated static let containerIdentifier = "iCloud.com.kolisko.pillcare"
    nonisolated static let defaultZoneName = "PillCareZone"
    nonisolated static let defaultPersonalWorkspaceRecordName = "personal-default-v1"

    private let container: CKContainer
    private let zoneID: CKRecordZone.ID
    private let personalWorkspaceRecordName: String

    init(
        containerIdentifier: String = CloudKitRepository.containerIdentifier,
        zoneName: String = CloudKitRepository.defaultZoneName,
        personalWorkspaceRecordName: String = CloudKitRepository.defaultPersonalWorkspaceRecordName
    ) {
        container = CKContainer(identifier: containerIdentifier)
        zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        self.personalWorkspaceRecordName = personalWorkspaceRecordName
    }

    private var privateDatabase: CKDatabase {
        container.privateCloudDatabase
    }

    private var sharedDatabase: CKDatabase {
        container.sharedCloudDatabase
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    func currentUserRecordName() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            container.fetchUserRecordID { recordID, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let recordID {
                    continuation.resume(returning: recordID.recordName)
                } else {
                    continuation.resume(throwing: CKError(.unknownItem))
                }
            }
        }
    }

    func ensurePrivateZone() async throws {
        if try await privateZoneExists() {
            return
        }

        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await modify(recordsToSave: [zone], recordIDsToDelete: [], in: privateDatabase)
    }

    func createGroup(name: String, firstMember: CareMember) async throws -> CloudSnapshot {
        try await ensurePrivateZone()

        let group = CKRecord(recordType: RecordType.group, recordID: CKRecord.ID(recordName: "group-\(UUID().uuidString)", zoneID: zoneID))
        group[Field.name] = name as CKRecordValue

        let member = memberRecord(firstMember, groupRecord: group)

        let saved = try await modify(recordsToSave: [group, member], recordIDsToDelete: [], in: privateDatabase)
        let savedGroup = saved.first(where: { $0.recordType == RecordType.group }) ?? group

        return CloudSnapshot(
            group: savedGroup,
            database: privateDatabase,
            databaseScope: .private,
            name: name,
            members: [firstMember],
            medications: [],
            confirmations: []
        )
    }

    func ensurePersonalWorkspace() async throws -> CloudSnapshot {
        try await ensurePrivateZone()

        let recordID = CKRecord.ID(recordName: personalWorkspaceRecordName, zoneID: zoneID)
        do {
            let group = try await fetchRecord(recordID: recordID, database: privateDatabase)
            return try await snapshot(for: group, database: privateDatabase, databaseScope: .private)
        } catch {
            if !Self.isRecordMissing(error) && !Self.isZoneNotFound(error) {
                throw error
            }
        }

        let group = CKRecord(recordType: RecordType.group, recordID: recordID)

        let saved = try await modify(recordsToSave: [group], recordIDsToDelete: [], in: privateDatabase)
        let savedGroup = saved.first(where: { $0.recordType == RecordType.group }) ?? group

        return CloudSnapshot(
            group: savedGroup,
            database: privateDatabase,
            databaseScope: .private,
            name: "",
            members: [],
            medications: [],
            confirmations: []
        )
    }

    func createLegacyPersonalWorkspace(name: String) async throws -> CloudSnapshot {
        try await ensurePrivateZone()

        let group = CKRecord(recordType: RecordType.group, recordID: CKRecord.ID(recordName: "care-\(UUID().uuidString)", zoneID: zoneID))
        group[Field.name] = name as CKRecordValue

        let saved = try await modify(recordsToSave: [group], recordIDsToDelete: [], in: privateDatabase)
        let savedGroup = saved.first(where: { $0.recordType == RecordType.group }) ?? group

        return CloudSnapshot(
            group: savedGroup,
            database: privateDatabase,
            databaseScope: .private,
            name: name,
            members: [],
            medications: [],
            confirmations: []
        )
    }

    func fetchAllGroupSnapshotsWithRetry() async throws -> [CloudSnapshot] {
        let snapshots = try await fetchAllGroupSnapshots()
        if !snapshots.isEmpty {
            return snapshots
        }

        try await Task.sleep(for: .seconds(1))
        return try await fetchAllGroupSnapshots()
    }

    func fetchAllGroupSnapshots() async throws -> [CloudSnapshot] {
        var snapshots = try await fetchGroupSnapshots(in: privateDatabase, databaseScope: .private, zones: [zoneID])
        let sharedZones = try await fetchAllZones(in: sharedDatabase).map(\.zoneID)
        snapshots += try await fetchGroupSnapshots(in: sharedDatabase, databaseScope: .shared, zones: sharedZones)
        return snapshots.sorted { lhs, rhs in
            let lhsScore = workspaceScore(lhs)
            let rhsScore = workspaceScore(rhs)
            if lhsScore == rhsScore {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhsScore > rhsScore
        }
    }

    func fetchPrivateGroupSnapshotsEnsuringPersonalWorkspace() async throws -> PrivateZoneSnapshotResult {
        try await ensurePrivateZone()

        var zoneResult = try await fetchRecordsInZoneWithToken(zoneID: zoneID, database: privateDatabase, previousServerChangeToken: nil)
        let personalRecordExists = zoneResult.changedRecords.contains {
            $0.recordType == RecordType.group && $0.recordID.recordName == personalWorkspaceRecordName
        }

        if !personalRecordExists {
            let recordID = CKRecord.ID(recordName: personalWorkspaceRecordName, zoneID: zoneID)
            let group = CKRecord(recordType: RecordType.group, recordID: recordID)
            _ = try await modify(recordsToSave: [group], recordIDsToDelete: [], in: privateDatabase)
            zoneResult = try await fetchRecordsInZoneWithToken(zoneID: zoneID, database: privateDatabase, previousServerChangeToken: nil)
        }

        let snapshots = snapshots(from: zoneResult.changedRecords, database: privateDatabase, databaseScope: .private)
        return PrivateZoneSnapshotResult(
            snapshots: snapshots,
            serverChangeToken: zoneResult.serverChangeToken
        )
    }

    func fetchGroupSnapshot(reference: StoredGroupReference) async throws -> CloudSnapshot? {
        let scope = CKDatabase.Scope(rawValue: reference.databaseScope) ?? .private
        let zoneID = CKRecordZone.ID(zoneName: reference.zoneName, ownerName: reference.ownerName)
        let recordID = CKRecord.ID(recordName: reference.recordName, zoneID: zoneID)
        let database = database(for: scope)

        do {
            let group = try await fetchRecord(recordID: recordID, database: database)
            return try await snapshot(for: group, database: database, databaseScope: scope)
        } catch {
            if Self.isRecordMissing(error) || Self.isZoneNotFound(error) {
                return nil
            }

            throw error
        }
    }

    func fetchGroupSnapshotWithToken(reference: StoredGroupReference) async throws -> ZoneSnapshotResult? {
        let scope = CKDatabase.Scope(rawValue: reference.databaseScope) ?? .private
        let zoneID = CKRecordZone.ID(zoneName: reference.zoneName, ownerName: reference.ownerName)
        let database = database(for: scope)

        do {
            let zoneResult = try await fetchRecordsInZoneWithToken(zoneID: zoneID, database: database, previousServerChangeToken: nil)
            let group = zoneResult.changedRecords.first {
                $0.recordType == RecordType.group && $0.recordID.recordName == reference.recordName
            }

            return ZoneSnapshotResult(
                snapshot: group.map { snapshot(for: $0, records: zoneResult.changedRecords, database: database, databaseScope: scope) },
                serverChangeToken: zoneResult.serverChangeToken
            )
        } catch {
            if Self.isRecordMissing(error) || Self.isZoneNotFound(error) {
                return nil
            }

            throw error
        }
    }

    func fetchZoneChanges(reference: StoredGroupReference, previousServerChangeToken: CKServerChangeToken) async throws -> ZoneChanges {
        let scope = CKDatabase.Scope(rawValue: reference.databaseScope) ?? .private
        let zoneID = CKRecordZone.ID(zoneName: reference.zoneName, ownerName: reference.ownerName)
        return try await fetchRecordsInZoneWithToken(
            zoneID: zoneID,
            database: database(for: scope),
            previousServerChangeToken: previousServerChangeToken
        )
    }

    func deleteWorkspace(reference: StoredGroupReference) async throws {
        let scope = CKDatabase.Scope(rawValue: reference.databaseScope) ?? .private
        guard scope == .private else { return }

        let zoneID = CKRecordZone.ID(zoneName: reference.zoneName, ownerName: reference.ownerName)
        let recordID = CKRecord.ID(recordName: reference.recordName, zoneID: zoneID)
        _ = try await modify(recordsToSave: [], recordIDsToDelete: [recordID], in: database(for: scope))
    }

    func isCanonicalPersonalWorkspace(_ snapshot: CloudSnapshot) -> Bool {
        isCanonicalPersonalReference(
            StoredGroupReference(
                recordName: snapshot.group.recordID.recordName,
                zoneName: snapshot.group.recordID.zoneID.zoneName,
                ownerName: snapshot.group.recordID.zoneID.ownerName,
                databaseScope: snapshot.databaseScope.rawValue
            )
        )
    }

    func renameGroup(groupRecord: CKRecord, database: CKDatabase, name: String) async throws -> CKRecord {
        let group = groupRecord
        group[Field.name] = name as CKRecordValue
        return try await modify(recordsToSave: [group], recordIDsToDelete: [], in: database)[0]
    }

    func saveMember(_ member: CareMember, groupRecord: CKRecord, database: CKDatabase) async throws {
        _ = try await modify(recordsToSave: [memberRecord(member, groupRecord: groupRecord)], recordIDsToDelete: [], in: database)
    }

    func deleteMember(_ member: CareMember, groupRecord: CKRecord, database: CKDatabase) async throws {
        let recordID = CKRecord.ID(recordName: recordName(prefix: "member", id: member.id), zoneID: groupRecord.recordID.zoneID)
        _ = try await modify(recordsToSave: [], recordIDsToDelete: [recordID], in: database)
    }

    func saveMedication(_ medication: Medication, groupRecord: CKRecord, database: CKDatabase) async throws {
        let record = CKRecord(recordType: RecordType.medication, recordID: CKRecord.ID(recordName: recordName(prefix: "medication", id: medication.id), zoneID: groupRecord.recordID.zoneID))
        record[Field.uuid] = medication.id.uuidString as CKRecordValue
        record[Field.group] = CKRecord.Reference(recordID: groupRecord.recordID, action: .deleteSelf)
        record.setParent(groupRecord)
        record[Field.payload] = try JSONEncoder.cloud.encode(medication) as NSData
        _ = try await modify(recordsToSave: [record], recordIDsToDelete: [], in: database)
    }

    func deleteMedication(_ medication: Medication, groupRecord: CKRecord, database: CKDatabase) async throws {
        let recordID = CKRecord.ID(recordName: recordName(prefix: "medication", id: medication.id), zoneID: groupRecord.recordID.zoneID)
        _ = try await modify(recordsToSave: [], recordIDsToDelete: [recordID], in: database)
    }

    func saveConfirmation(_ confirmation: DoseConfirmation, groupRecord: CKRecord, database: CKDatabase) async throws {
        let record = CKRecord(recordType: RecordType.confirmation, recordID: CKRecord.ID(recordName: confirmationRecordName(eventId: confirmation.eventId), zoneID: groupRecord.recordID.zoneID))
        record[Field.eventId] = confirmation.eventId as CKRecordValue
        record[Field.medicationId] = confirmation.medicationId.uuidString as CKRecordValue
        record[Field.group] = CKRecord.Reference(recordID: groupRecord.recordID, action: .deleteSelf)
        record.setParent(groupRecord)
        record[Field.payload] = try JSONEncoder.cloud.encode(confirmation) as NSData
        _ = try await modify(recordsToSave: [record], recordIDsToDelete: [], in: database)
    }

    func fetchConfirmation(eventId: String, groupRecord: CKRecord, database: CKDatabase) async throws -> DoseConfirmation? {
        let recordID = CKRecord.ID(recordName: confirmationRecordName(eventId: eventId), zoneID: groupRecord.recordID.zoneID)
        do {
            let record = try await fetchRecord(recordID: recordID, database: database)
            return decodePayload(record, as: DoseConfirmation.self)
        } catch {
            if Self.isRecordMissing(error) {
                return nil
            }

            throw error
        }
    }

    func deleteConfirmation(eventId: String, groupRecord: CKRecord, database: CKDatabase) async throws {
        let recordID = CKRecord.ID(recordName: confirmationRecordName(eventId: eventId), zoneID: groupRecord.recordID.zoneID)
        _ = try await modify(recordsToSave: [], recordIDsToDelete: [recordID], in: database)
    }

    func installWorkspaceSubscription(groupRecord: CKRecord, database: CKDatabase, databaseScope: CKDatabase.Scope) async throws {
        if databaseScope == .shared {
            let subscription = CKDatabaseSubscription(subscriptionID: "shared-database-changes")
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            _ = try await save(subscription: subscription, in: database)
            return
        }

        guard databaseScope == .private else { return }

        let zoneID = groupRecord.recordID.zoneID
        let subscriptionID = [
            "workspace-zone",
            Self.subscriptionIdentifierComponent(zoneID.ownerName),
            Self.subscriptionIdentifierComponent(zoneID.zoneName)
        ].joined(separator: "-")
        let subscription = CKRecordZoneSubscription(
            zoneID: zoneID,
            subscriptionID: subscriptionID
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await save(subscription: subscription, in: database)
    }

    func repairShareHierarchy(for snapshots: [CloudSnapshot]) async throws {
        for snapshot in snapshots where snapshot.databaseScope == .private && snapshot.group.share != nil {
            let linkedRecords = try await fetchLinkedRecords(group: snapshot.group, database: snapshot.database)
            let recordsToRepair = linkedRecords.filter { $0.parent?.recordID != snapshot.group.recordID }
            for record in recordsToRepair {
                record.setParent(snapshot.group)
            }

            if !recordsToRepair.isEmpty {
                _ = try await modify(recordsToSave: recordsToRepair, recordIDsToDelete: [], in: snapshot.database)
            }
        }
    }

    func prepareShare(groupRecord: CKRecord, database: CKDatabase, title: String) async throws -> CloudSharePreparation {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkedRecords = try await fetchLinkedRecords(group: groupRecord, database: database)
        for record in linkedRecords where record.parent?.recordID != groupRecord.recordID {
            record.setParent(groupRecord)
        }

        if let existingShareReference = groupRecord.share {
            let existingShareRecord = try await fetchRecord(recordID: existingShareReference.recordID, database: database)
            guard let existingShare = existingShareRecord as? CKShare else {
                throw CloudKitShareError.invalidExistingShare
            }
            if !cleanTitle.isEmpty {
                existingShare[CKShare.SystemFieldKey.title] = cleanTitle as CKRecordValue
            }
            existingShare.publicPermission = .none
            let saved = try await modify(recordsToSave: [existingShare] + linkedRecords, recordIDsToDelete: [], in: database)
            let savedShare = saved.compactMap { $0 as? CKShare }.first ?? existingShare
            return CloudSharePreparation(groupRecord: groupRecord, share: savedShare)
        }

        let share = CKShare(rootRecord: groupRecord)
        if !cleanTitle.isEmpty {
            share[CKShare.SystemFieldKey.title] = cleanTitle as CKRecordValue
        }
        share.publicPermission = .none
        let saved = try await modify(recordsToSave: [groupRecord, share] + linkedRecords, recordIDsToDelete: [], in: database)
        let savedGroup = saved.first(where: { $0.recordType == RecordType.group }) ?? groupRecord
        let savedShare = saved.compactMap { $0 as? CKShare }.first ?? share
        return CloudSharePreparation(groupRecord: savedGroup, share: savedShare)
    }

    func acceptShare(_ metadata: CKShare.Metadata) async throws -> StoredGroupReference {
        _ = try await withCheckedThrowingContinuation { continuation in
            let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])
            operation.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            configure(operation)
            container.add(operation)
        }

        guard let rootID = metadata.hierarchicalRootRecordID else {
            throw CloudKitShareError.missingRootRecord
        }
        return StoredGroupReference(
            recordName: rootID.recordName,
            zoneName: rootID.zoneID.zoneName,
            ownerName: rootID.zoneID.ownerName,
            databaseScope: CKDatabase.Scope.shared.rawValue
        )
    }

    private func fetchGroupSnapshots(in database: CKDatabase, databaseScope: CKDatabase.Scope, zones: [CKRecordZone.ID]) async throws -> [CloudSnapshot] {
        var snapshots: [CloudSnapshot] = []

        for zoneID in zones {
            let records: [CKRecord]
            do {
                records = try await fetchRecordsInZone(zoneID: zoneID, database: database)
            } catch {
                if Self.isZoneNotFound(error) || Self.isRecordTypeMissing(error) {
                    continue
                }
                throw error
            }

            let groups = records.filter { $0.recordType == RecordType.group }
            for group in groups {
                snapshots.append(snapshot(for: group, records: records, database: database, databaseScope: databaseScope))
            }
        }

        return snapshots
    }

    private func snapshots(from records: [CKRecord], database: CKDatabase, databaseScope: CKDatabase.Scope) -> [CloudSnapshot] {
        records
            .filter { $0.recordType == RecordType.group }
            .map { snapshot(for: $0, records: records, database: database, databaseScope: databaseScope) }
    }

    private func snapshot(for group: CKRecord, database: CKDatabase, databaseScope: CKDatabase.Scope) async throws -> CloudSnapshot {
        let members = try await fetchLinkedRecords(recordType: RecordType.member, group: group, database: database)
        let medications = try await fetchLinkedRecords(recordType: RecordType.medication, group: group, database: database)
        let confirmations = try await fetchLinkedRecords(recordType: RecordType.confirmation, group: group, database: database)

        return CloudSnapshot(
            group: group,
            database: database,
            databaseScope: databaseScope,
            name: group[Field.name] as? String ?? "",
            members: members.compactMap(member(from:)),
            medications: medications.compactMap { decodePayload($0, as: Medication.self) },
            confirmations: confirmations.compactMap { decodePayload($0, as: DoseConfirmation.self) }
        )
    }

    private func snapshot(for group: CKRecord, records: [CKRecord], database: CKDatabase, databaseScope: CKDatabase.Scope) -> CloudSnapshot {
        let linkedRecords = records.filter { isLinked(record: $0, to: group) }

        return CloudSnapshot(
            group: group,
            database: database,
            databaseScope: databaseScope,
            name: group[Field.name] as? String ?? "",
            members: linkedRecords.filter { $0.recordType == RecordType.member }.compactMap(member(from:)),
            medications: linkedRecords.filter { $0.recordType == RecordType.medication }.compactMap { decodePayload($0, as: Medication.self) },
            confirmations: linkedRecords.filter { $0.recordType == RecordType.confirmation }.compactMap { decodePayload($0, as: DoseConfirmation.self) }
        )
    }

    private func workspaceScore(_ snapshot: CloudSnapshot) -> Int {
        var score = 0
        if isCanonicalPersonalWorkspace(snapshot) {
            score += 10_000
        }
        score += snapshot.medications.count * 1_000
        score += snapshot.confirmations.count * 100
        score += snapshot.members.count * 10
        if snapshot.databaseScope == .private {
            score += 1
        }
        return score
    }

    private static func subscriptionIdentifierComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "_"
        }.joined()
    }

    private func fetchLinkedRecords(group: CKRecord, database: CKDatabase) async throws -> [CKRecord] {
        let records = try await fetchRecordsInZone(zoneID: group.recordID.zoneID, database: database)
        return records.filter { isLinked(record: $0, to: group) }
    }

    private func fetchLinkedRecords(recordType: String, group: CKRecord, database: CKDatabase) async throws -> [CKRecord] {
        let records = try await fetchRecordsInZone(zoneID: group.recordID.zoneID, database: database)
            .filter { $0.recordType == recordType }
        return records.filter { isLinked(record: $0, to: group) }
    }

    func isRecord(_ record: CKRecord, linkedTo group: CKRecord) -> Bool {
        isLinked(record: record, to: group)
    }

    private func isLinked(record: CKRecord, to group: CKRecord) -> Bool {
        guard record.recordID != group.recordID else { return false }

        if let parentID = record.parent?.recordID,
           Self.isSameLogicalRecord(parentID, as: group.recordID) {
            return true
        }

        guard let reference = record[Field.group] as? CKRecord.Reference else {
            return false
        }

        return Self.isSameLogicalRecord(reference.recordID, as: group.recordID)
    }

    private static func isSameLogicalRecord(_ lhs: CKRecord.ID, as rhs: CKRecord.ID) -> Bool {
        lhs.recordName == rhs.recordName
            && lhs.zoneID.zoneName == rhs.zoneID.zoneName
    }

    private func fetchRecordsInZone(zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> [CKRecord] {
        try await fetchRecordsInZoneWithToken(zoneID: zoneID, database: database, previousServerChangeToken: nil).changedRecords
    }

    private func fetchRecordsInZoneWithToken(
        zoneID: CKRecordZone.ID,
        database: CKDatabase,
        previousServerChangeToken: CKServerChangeToken?
    ) async throws -> ZoneChanges {
        try await withCheckedThrowingContinuation { continuation in
            var records: [CKRecord] = []
            var deletedRecordIDs: [CKRecord.ID] = []
            var serverChangeToken: CKServerChangeToken?
            var zoneError: Error?
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: previousServerChangeToken,
                resultsLimit: nil,
                desiredKeys: nil
            )
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: configuration]
            )
            operation.fetchAllChanges = true
            operation.recordWasChangedBlock = { _, result in
                switch result {
                case .success(let record):
                    records.append(record)
                case .failure(let error):
                    zoneError = error
                }
            }
            operation.recordWithIDWasDeletedBlock = { recordID, _ in
                deletedRecordIDs.append(recordID)
            }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let fetchResult):
                    serverChangeToken = fetchResult.serverChangeToken
                case .failure(let error):
                    zoneError = error
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    if let zoneError {
                        continuation.resume(throwing: zoneError)
                    } else {
                        continuation.resume(returning: ZoneChanges(
                            changedRecords: records,
                            deletedRecordIDs: deletedRecordIDs,
                            serverChangeToken: serverChangeToken
                        ))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            configure(operation)
            database.add(operation)
        }
    }

    private func fetchRecord(recordID: CKRecord.ID, database: CKDatabase) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchRecordsOperation(recordIDs: [recordID])
            operation.perRecordResultBlock = { _, result in
                switch result {
                case .success(let record):
                    continuation.resume(returning: record)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            operation.fetchRecordsResultBlock = { result in
                if case .failure(let error) = result {
                    continuation.resume(throwing: error)
                }
            }
            configure(operation)
            database.add(operation)
        }
    }

    private func fetchAllZones(in database: CKDatabase) async throws -> [CKRecordZone] {
        try await withCheckedThrowingContinuation { continuation in
            var zones: [CKRecordZone] = []
            let operation = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
            operation.perRecordZoneResultBlock = { _, result in
                if case .success(let zone) = result {
                    zones.append(zone)
                }
            }
            operation.fetchRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: zones)
                case .failure(let error):
                    if Self.isZoneNotFound(error) {
                        continuation.resume(returning: [])
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
            configure(operation)
            database.add(operation)
        }
    }

    private func privateZoneExists() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            var exists = false
            var missingZone = false
            var zoneError: Error?
            let operation = CKFetchRecordZonesOperation(recordZoneIDs: [zoneID])
            operation.perRecordZoneResultBlock = { _, result in
                switch result {
                case .success:
                    exists = true
                case .failure(let error):
                    if Self.isZoneNotFound(error) {
                        missingZone = true
                    } else {
                        zoneError = error
                    }
                }
            }
            operation.fetchRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    if let zoneError {
                        continuation.resume(throwing: zoneError)
                    } else {
                        continuation.resume(returning: exists && !missingZone)
                    }
                case .failure(let error):
                    if Self.isZoneNotFound(error) {
                        continuation.resume(returning: false)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
            configure(operation)
            privateDatabase.add(operation)
        }
    }

    private static func isZoneNotFound(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == CKError.errorDomain, nsError.code == CKError.zoneNotFound.rawValue {
            return true
        }

        if let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: NSError] {
            return partialErrors.values.contains { $0.domain == CKError.errorDomain && $0.code == CKError.zoneNotFound.rawValue }
        }

        if let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [CKRecordZone.ID: NSError] {
            return partialErrors.values.contains { $0.domain == CKError.errorDomain && $0.code == CKError.zoneNotFound.rawValue }
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isZoneNotFound(underlying)
        }

        return false
    }

    private static func isRecordMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == CKError.errorDomain, nsError.code == CKError.unknownItem.rawValue {
            return true
        }

        if let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: NSError] {
            return partialErrors.values.contains { $0.domain == CKError.errorDomain && $0.code == CKError.unknownItem.rawValue }
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isRecordMissing(underlying)
        }

        return false
    }

    private static func isRecordTypeMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == CKError.errorDomain,
           nsError.code == CKError.unknownItem.rawValue,
           nsError.localizedDescription.localizedCaseInsensitiveContains("record type") {
            return true
        }

        if nsError.localizedDescription.localizedCaseInsensitiveContains("did not find record type") {
            return true
        }

        if let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: NSError] {
            return partialErrors.values.contains(where: isRecordTypeMissing)
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isRecordTypeMissing(underlying)
        }

        return false
    }

    func isChangeTokenExpired(_ error: Error) -> Bool {
        Self.isChangeTokenExpired(error)
    }

    private static func isChangeTokenExpired(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == CKError.errorDomain, nsError.code == CKError.changeTokenExpired.rawValue {
            return true
        }

        if let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: NSError] {
            return partialErrors.values.contains(where: isChangeTokenExpired)
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isChangeTokenExpired(underlying)
        }

        return false
    }

    private func modify(recordsToSave: [CKRecord], recordIDsToDelete: [CKRecord.ID], in database: CKDatabase) async throws -> [CKRecord] {
        try await withCheckedThrowingContinuation { continuation in
            var saved: [CKRecord] = []
            let operation = CKModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete)
            operation.savePolicy = .changedKeys
            operation.isAtomic = true
            operation.perRecordSaveBlock = { _, result in
                if case .success(let record) = result {
                    saved.append(record)
                }
            }
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: saved)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            configure(operation)
            database.add(operation)
        }
    }

    private func modify(recordsToSave: [CKRecordZone], recordIDsToDelete: [CKRecordZone.ID], in database: CKDatabase) async throws -> [CKRecordZone] {
        try await withCheckedThrowingContinuation { continuation in
            var saved: [CKRecordZone] = []
            let operation = CKModifyRecordZonesOperation(recordZonesToSave: recordsToSave, recordZoneIDsToDelete: recordIDsToDelete)
            operation.perRecordZoneSaveBlock = { _, result in
                if case .success(let zone) = result {
                    saved.append(zone)
                }
            }
            operation.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: saved)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            configure(operation)
            database.add(operation)
        }
    }

    private func save(subscription: CKSubscription, in database: CKDatabase) async throws -> CKSubscription {
        try await withCheckedThrowingContinuation { continuation in
            var savedSubscription: CKSubscription?
            let operation = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: [])
            operation.perSubscriptionSaveBlock = { _, result in
                if case .success(let subscription) = result {
                    savedSubscription = subscription
                }
            }
            operation.modifySubscriptionsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: savedSubscription ?? subscription)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            configure(operation)
            database.add(operation)
        }
    }

    private func configure(_ operation: CKOperation) {
        let configuration = CKOperation.Configuration()
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 35
        operation.configuration = configuration
    }

    private func database(for scope: CKDatabase.Scope) -> CKDatabase {
        switch scope {
        case .private:
            return privateDatabase
        case .shared:
            return sharedDatabase
        case .public:
            return container.publicCloudDatabase
        @unknown default:
            return privateDatabase
        }
    }

    func isCanonicalPersonalReference(_ reference: StoredGroupReference) -> Bool {
        reference.databaseScope == CKDatabase.Scope.private.rawValue
            && reference.recordName == personalWorkspaceRecordName
            && reference.zoneName == zoneID.zoneName
    }

    private func memberRecord(_ member: CareMember, groupRecord: CKRecord) -> CKRecord {
        let record = CKRecord(recordType: RecordType.member, recordID: CKRecord.ID(recordName: recordName(prefix: "member", id: member.id), zoneID: groupRecord.recordID.zoneID))
        record[Field.uuid] = member.id.uuidString as CKRecordValue
        record[Field.displayName] = member.displayName as CKRecordValue
        record[Field.colorHex] = member.colorHex as CKRecordValue
        if let userRecordName = member.userRecordName {
            record[Field.userRecordName] = userRecordName as CKRecordValue
        }
        record[Field.group] = CKRecord.Reference(recordID: groupRecord.recordID, action: .deleteSelf)
        record.setParent(groupRecord)
        return record
    }

    func member(from record: CKRecord) -> CareMember? {
        guard
            let uuidString = record[Field.uuid] as? String,
            let id = UUID(uuidString: uuidString),
            let displayName = record[Field.displayName] as? String,
            let colorHex = record[Field.colorHex] as? String
        else {
            return nil
        }
        return CareMember(
            id: id,
            displayName: displayName,
            colorHex: colorHex,
            userRecordName: record[Field.userRecordName] as? String
        )
    }

    func decodePayload<T: Decodable>(_ record: CKRecord, as type: T.Type) -> T? {
        guard let data = record[Field.payload] as? Data else { return nil }
        return try? JSONDecoder.cloud.decode(type, from: data)
    }

    private func recordName(prefix: String, id: UUID) -> String {
        "\(prefix)-\(id.uuidString)"
    }

    private func confirmationRecordName(eventId: String) -> String {
        "confirmation-\(eventId)"
    }
}

enum RecordType {
    static let group = "CareGroup"
    static let member = "CareMember"
    static let medication = "Medication"
    static let confirmation = "DoseConfirmation"
}

enum Field {
    static let name = "name"
    static let uuid = "uuid"
    static let displayName = "displayName"
    static let colorHex = "colorHex"
    static let userRecordName = "userRecordName"
    static let group = "group"
    static let payload = "payload"
    static let eventId = "eventId"
    static let medicationId = "medicationId"
}

private extension JSONEncoder {
    static var cloud: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var cloud: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
