import CloudKit
import Foundation

@MainActor
final class MedicationStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case requiresICloudAccount(String)
        case missingGroup
        case failed(String)
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var careGroupName = ""
    @Published private(set) var members: [CareMember] = []
    @Published var activeMemberId: UUID?
    @Published private(set) var medications: [Medication] = []
    @Published private(set) var confirmations: [String: DoseConfirmation] = [:]
    @Published private(set) var isSyncing = false
    @Published private(set) var syncErrorMessage: String?
    @Published private(set) var workspaceCandidates: [WorkspaceCandidate] = []

    private let cloud: CloudKitRepository
    private let defaults: UserDefaults
    private var groupRecord: CKRecord?
    private var groupDatabase: CKDatabase?
    private var groupDatabaseScope: CKDatabase.Scope?
    private var loadGeneration = 0
    private var syncOperationCount = 0

    init(cloud: CloudKitRepository = CloudKitRepository(), defaults: UserDefaults = .standard) {
        self.cloud = cloud
        self.defaults = defaults
    }

    var hasGroup: Bool {
        !members.isEmpty
    }

    var hasCloudWorkspace: Bool {
        groupRecord != nil
    }

    var activeMember: CareMember? {
        guard let activeMemberId else { return nil }
        return members.first(where: { $0.id == activeMemberId })
    }

    func start() async {
        await reload()
        await NotificationScheduler.shared.requestAuthorizationIfNeeded()
        NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
    }

    func reload(showSyncIndicator: Bool = true) async {
        if showSyncIndicator {
            beginSync()
        }
        defer {
            if showSyncIndicator {
                endSync()
            }
        }

        loadGeneration += 1
        let generation = loadGeneration
        let needsInitialLoadingState = loadState == .idle && groupRecord == nil && medications.isEmpty && members.isEmpty
        if needsInitialLoadingState {
            loadState = .loading
        }

        do {
            let accountStatus = try await cloud.accountStatus()
            guard generation == loadGeneration else { return }

            guard accountStatus == .available else {
                clearLoadedData()
                loadState = .requiresICloudAccount(Self.iCloudAccountMessage(for: accountStatus))
                return
            }

            try await cloud.ensurePrivateZone()
            guard generation == loadGeneration else { return }

            let resolvedSnapshot = try await loadGroupSnapshot()

            guard generation == loadGeneration else { return }

            groupRecord = resolvedSnapshot.group
            groupDatabase = resolvedSnapshot.database
            groupDatabaseScope = resolvedSnapshot.databaseScope
            saveStoredGroupReference(from: resolvedSnapshot)
            apply(snapshot: resolvedSnapshot)

            try? await cloud.installWorkspaceSubscription(groupRecord: resolvedSnapshot.group, database: resolvedSnapshot.database)

            guard generation == loadGeneration else { return }

            loadState = .ready
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
        } catch {
            fail(error)
        }
    }

    func createGroup(name: String, firstMemberName: String) async {
        beginSync()
        defer { endSync() }

        loadGeneration += 1
        let cleanGroupName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMemberName = firstMemberName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGroupName.isEmpty, !cleanMemberName.isEmpty else { return }

        do {
            if let groupRecord, let groupDatabase {
                let member = CareMember(displayName: cleanMemberName, colorHex: Self.memberColors[members.count % Self.memberColors.count])
                let savedGroup = try await cloud.renameGroup(groupRecord: groupRecord, database: groupDatabase, name: cleanGroupName)
                try await cloud.saveMember(member, groupRecord: savedGroup, database: groupDatabase)
                self.groupRecord = savedGroup
                groupDatabaseScope = .private
                careGroupName = cleanGroupName
                members = [member]
                activeMemberId = member.id
                loadState = .ready
                await reload()
                return
            }

            let snapshot = try await cloud.createGroup(name: cleanGroupName, firstMemberName: cleanMemberName)
            groupRecord = snapshot.group
            groupDatabase = snapshot.database
            groupDatabaseScope = snapshot.databaseScope
            saveStoredGroupReference(from: snapshot)
            careGroupName = snapshot.name
            members = snapshot.members
            activeMemberId = snapshot.members.first?.id
            medications = []
            confirmations = [:]
            try? await cloud.installWorkspaceSubscription(groupRecord: snapshot.group, database: snapshot.database)
            loadState = .ready
            await reload()
        } catch {
            fail(error)
        }
    }

    func setGroupName(_ name: String) async {
        guard let groupRecord, let groupDatabase else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        beginSync()
        defer { endSync() }

        do {
            let saved = try await cloud.renameGroup(groupRecord: groupRecord, database: groupDatabase, name: cleanName)
            self.groupRecord = saved
            careGroupName = cleanName
        } catch {
            fail(error)
        }
    }

    func doses(on date: Date) -> [GeneratedDose] {
        ScheduleEngine.doses(on: date, medications: medications)
    }

    func confirmation(for dose: GeneratedDose) -> DoseConfirmation? {
        confirmations[dose.id]
    }

    func confirm(_ dose: GeneratedDose, status: DoseStatus, note: String = "") async throws {
        let member = activeMember

        let confirmation = DoseConfirmation(
            eventId: dose.id,
            medicationId: dose.medicationId,
            timeId: dose.timeId,
            scheduledDate: dose.scheduledDate,
            amount: dose.amount,
            status: status,
            memberId: member?.id ?? Self.personalConfirmationMemberId,
            memberName: member?.displayName ?? "",
            timestamp: Date(),
            note: note
        )

        guard let groupRecord, let groupDatabase else {
            let error = StoreError.missingCloudWorkspace
            recordSyncError(error)
            throw error
        }

        beginSync()
        defer { endSync() }

        do {
            try await cloud.saveConfirmation(confirmation, groupRecord: groupRecord, database: groupDatabase)
            confirmations[confirmation.eventId] = confirmation
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
            Task { await reload() }
        } catch {
            recordSyncError(error)
            throw error
        }
    }

    func undoConfirmation(for dose: GeneratedDose) async throws {
        guard let groupRecord, let groupDatabase else {
            let error = StoreError.missingCloudWorkspace
            recordSyncError(error)
            throw error
        }

        beginSync()
        defer { endSync() }

        do {
            try await cloud.deleteConfirmation(eventId: dose.id, groupRecord: groupRecord, database: groupDatabase)
            confirmations.removeValue(forKey: dose.id)
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
            Task { await reload() }
        } catch {
            recordSyncError(error)
            throw error
        }
    }

    func addMedication() -> Medication {
        let morning = DoseTime(label: "Ráno", time: TimeOfDay(hour: 7, minute: 0))
        let noon = DoseTime(label: "Poledne", time: TimeOfDay(hour: 12, minute: 0))
        let evening = DoseTime(label: "Večer", time: TimeOfDay(hour: 19, minute: 0))
        return Medication(
            name: "Nový lék",
            note: "",
            colorHex: "#2F80ED",
            startDate: Calendar.current.startOfDay(for: Date()),
            doseTimes: [morning, noon, evening],
            phases: [
                PlanPhase(
                    title: "Základní dávkování",
                    durationDays: nil,
                    doses: [
                        DoseEntry(timeId: morning.id, amount: "0"),
                        DoseEntry(timeId: noon.id, amount: "0"),
                        DoseEntry(timeId: evening.id, amount: "0")
                    ]
                )
            ]
        )
    }

    func upsertMedication(_ medication: Medication) async throws {
        guard let groupRecord, let groupDatabase else {
            let error = StoreError.missingCloudWorkspace
            recordSyncError(error)
            throw error
        }

        beginSync()
        defer { endSync() }

        do {
            try await cloud.saveMedication(medication, groupRecord: groupRecord, database: groupDatabase)
            upsertMedicationLocally(medication)
            loadState = .ready
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)

            Task { await reload() }
        } catch {
            recordSyncError(error)
            throw error
        }
    }

    func deleteMedication(_ medication: Medication) {
        guard let groupRecord, let groupDatabase else { return }

        Task {
            beginSync()
            defer { endSync() }

            do {
                try await cloud.deleteMedication(medication, groupRecord: groupRecord, database: groupDatabase)
                await reload()
            } catch {
                recordSyncError(error)
            }
        }
    }

    func addMember(named name: String) {
        guard let groupRecord, let groupDatabase else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        let member = CareMember(displayName: cleanName, colorHex: Self.memberColors[members.count % Self.memberColors.count])
        Task {
            beginSync()
            defer { endSync() }

            do {
                try await cloud.saveMember(member, groupRecord: groupRecord, database: groupDatabase)
                await reload()
            } catch {
                recordSyncError(error)
            }
        }
    }

    func updateMember(_ member: CareMember) {
        guard let groupRecord, let groupDatabase else { return }

        Task {
            beginSync()
            defer { endSync() }

            do {
                try await cloud.saveMember(member, groupRecord: groupRecord, database: groupDatabase)
                await reload()
            } catch {
                recordSyncError(error)
            }
        }
    }

    func deleteMember(_ member: CareMember) {
        guard let groupRecord, let groupDatabase else { return }

        Task {
            beginSync()
            defer { endSync() }

            do {
                try await cloud.deleteMember(member, groupRecord: groupRecord, database: groupDatabase)
                await reload()
            } catch {
                recordSyncError(error)
            }
        }
    }

    func makeSharingController() -> CloudSharingController? {
        guard let groupRecord, let groupDatabase else { return nil }
        return CloudSharingController(cloud: cloud, groupRecord: groupRecord, database: groupDatabase, title: careGroupName)
    }

    static func acceptShare(_ metadata: CKShare.Metadata) async throws {
        try await CloudKitRepository().acceptShare(metadata)
    }

    func dismissSyncError() {
        syncErrorMessage = nil
    }

    func selectWorkspace(_ candidate: WorkspaceCandidate) async {
        beginSync()
        defer { endSync() }

        do {
            guard let snapshot = try await cloud.fetchGroupSnapshot(reference: candidate.reference) else {
                workspaceCandidates.removeAll { $0.id == candidate.id }
                if workspaceCandidates.isEmpty {
                    await reload()
                }
                return
            }

            groupRecord = snapshot.group
            groupDatabase = snapshot.database
            groupDatabaseScope = snapshot.databaseScope
            saveStoredGroupReference(from: snapshot)
            apply(snapshot: snapshot)
            workspaceCandidates = []
            try? await cloud.installWorkspaceSubscription(groupRecord: snapshot.group, database: snapshot.database)
            loadState = .ready
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
        } catch {
            recordSyncError(error)
        }
    }

    func deleteWorkspaceCandidate(_ candidate: WorkspaceCandidate) async {
        guard !candidate.isActive else { return }

        beginSync()
        defer { endSync() }

        do {
            if candidate.canDeleteFromCloud {
                try await cloud.deleteWorkspace(reference: candidate.reference)
            }

            workspaceCandidates.removeAll { $0.id == candidate.id }

            if workspaceCandidates.count == 1, groupRecord == nil {
                await selectWorkspace(workspaceCandidates[0])
            }
        } catch {
            recordSyncError(error)
        }
    }

    private func beginSync() {
        syncOperationCount += 1
        syncErrorMessage = nil
        isSyncing = true
    }

    private func endSync() {
        syncOperationCount = max(0, syncOperationCount - 1)
        isSyncing = syncOperationCount > 0
    }

    private func recordSyncError(_ error: Error) {
        syncErrorMessage = Self.userMessage(for: error)
    }

    private func clearLoadedData() {
        groupRecord = nil
        groupDatabase = nil
        groupDatabaseScope = nil
        careGroupName = ""
        members = []
        activeMemberId = nil
        medications = []
        confirmations = [:]
    }

    private func loadGroupSnapshot() async throws -> CloudSnapshot {
        workspaceCandidates = []

        if let reference = loadStoredGroupReference(),
           reference.databaseScope == CKDatabase.Scope.shared.rawValue,
           let sharedSnapshot = try await cloud.fetchGroupSnapshot(reference: reference) {
            return sharedSnapshot
        }

        return try await cloud.ensurePersonalWorkspace()
    }

    private func fail(_ error: Error) {
        let message = Self.userMessage(for: error)
        syncErrorMessage = message
        loadState = .failed(message)
    }

    private func upsertMedicationLocally(_ medication: Medication) {
        if let index = medications.firstIndex(where: { $0.id == medication.id }) {
            medications[index] = medication
        } else {
            medications.append(medication)
        }

        medications.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func apply(snapshot: CloudSnapshot) {
        careGroupName = snapshot.name
        members = snapshot.members.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        medications = snapshot.medications.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        confirmations = Dictionary(uniqueKeysWithValues: snapshot.confirmations.map { ($0.eventId, $0) })

        if let activeMemberId, members.contains(where: { $0.id == activeMemberId }) {
            self.activeMemberId = activeMemberId
        } else {
            activeMemberId = members.first?.id
        }
    }

    private static func userMessage(for error: Error) -> String {
        let code = cloudErrorCode(in: error)

        if code == CKError.notAuthenticated.rawValue {
            return "Pill Care potřebuje přihlášený iCloud účet. V Simulátoru nebo iPhonu otevři Nastavení a přihlas se k Apple účtu/iCloudu, potom to zkus znovu."
        }

        if code == CKError.networkUnavailable.rawValue || code == CKError.networkFailure.rawValue {
            return "iCloud je teď bez připojení. Zkontroluj internet a zkus to znovu."
        }

        if code == CKError.quotaExceeded.rawValue {
            return "iCloud účet nemá dost volného místa pro uložení skupiny."
        }

        if code == CKError.serviceUnavailable.rawValue || code == CKError.requestRateLimited.rawValue {
            return "iCloud je dočasně nedostupný. Chvíli počkej a zkus to znovu."
        }

        return error.localizedDescription
    }

    private static func iCloudAccountMessage(for status: CKAccountStatus) -> String {
        switch status {
        case .available:
            return ""
        case .noAccount:
            return "Pill Care ukládá skupinu a potvrzení do iCloudu. Přihlas se v Nastavení k Apple účtu a zapni iCloud, potom se vrať do aplikace."
        case .restricted:
            return "iCloud je na tomhle zařízení omezený. Zkontroluj omezení Apple účtu, Screen Time nebo firemní profil a potom to zkus znovu."
        case .couldNotDetermine:
            return "Nepodařilo se ověřit stav iCloudu. Zkontroluj připojení k internetu a přihlášení k Apple účtu, potom to zkus znovu."
        case .temporarilyUnavailable:
            return "iCloud je dočasně nedostupný. Chvíli počkej a potom to zkus znovu."
        @unknown default:
            return "Pill Care potřebuje dostupný iCloud účet. Zkontroluj přihlášení k Apple účtu a potom to zkus znovu."
        }
    }

    private static func cloudErrorCode(in error: Error) -> Int? {
        let nsError = error as NSError
        if nsError.domain == CKError.errorDomain {
            return nsError.code
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == CKError.errorDomain {
            return underlying.code
        }

        return nil
    }

    private func saveStoredGroupReference(from snapshot: CloudSnapshot) {
        let reference = Self.storedGroupReference(from: snapshot)

        if let data = try? JSONEncoder().encode(reference) {
            defaults.set(data, forKey: Self.storedGroupReferenceKey)
        }
    }

    private static func storedGroupReference(from snapshot: CloudSnapshot) -> StoredGroupReference {
        StoredGroupReference(
            recordName: snapshot.group.recordID.recordName,
            zoneName: snapshot.group.recordID.zoneID.zoneName,
            ownerName: snapshot.group.recordID.zoneID.ownerName,
            databaseScope: snapshot.databaseScope.rawValue
        )
    }

    private func loadStoredGroupReference() -> StoredGroupReference? {
        guard let data = defaults.data(forKey: Self.storedGroupReferenceKey) else {
            return nil
        }

        return try? JSONDecoder().decode(StoredGroupReference.self, from: data)
    }

    private static let memberColors = ["#2F80ED", "#27AE60", "#EB5757", "#9B51E0", "#F2994A", "#00A3A3"]
    static let storedGroupReferenceKey = "PillCareStoredGroupReference"
    private static let personalConfirmationMemberId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

struct CloudSharingController: Identifiable {
    var id: CKRecord.ID { groupRecord.recordID }
    let cloud: CloudKitRepository
    let groupRecord: CKRecord
    let database: CKDatabase
    let title: String
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

private enum StoreError: LocalizedError {
    case missingCloudWorkspace

    var errorDescription: String? {
        switch self {
        case .missingCloudWorkspace:
            return "iCloud úložiště ještě není připravené. Chvíli počkej a zkus uložit znovu."
        }
    }
}

@MainActor
final class CloudKitRepository {
    static let containerIdentifier = "iCloud.com.kolisko.pillcare"
    static let defaultZoneName = "PillCareZone"
    static let defaultPersonalWorkspaceRecordName = "personal-default-v1"

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

    func ensurePrivateZone() async throws {
        if try await privateZoneExists() {
            return
        }

        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await modify(recordsToSave: [zone], recordIDsToDelete: [], in: privateDatabase)
    }

    func createGroup(name: String, firstMemberName: String) async throws -> CloudSnapshot {
        try await ensurePrivateZone()

        let group = CKRecord(recordType: RecordType.group, recordID: CKRecord.ID(recordName: "group-\(UUID().uuidString)", zoneID: zoneID))
        group[Field.name] = name as CKRecordValue

        let firstMember = CareMember(displayName: firstMemberName, colorHex: "#2F80ED")
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
        record[Field.payload] = try JSONEncoder.cloud.encode(confirmation) as NSData
        _ = try await modify(recordsToSave: [record], recordIDsToDelete: [], in: database)
    }

    func deleteConfirmation(eventId: String, groupRecord: CKRecord, database: CKDatabase) async throws {
        let recordID = CKRecord.ID(recordName: confirmationRecordName(eventId: eventId), zoneID: groupRecord.recordID.zoneID)
        _ = try await modify(recordsToSave: [], recordIDsToDelete: [recordID], in: database)
    }

    func installWorkspaceSubscription(groupRecord: CKRecord, database: CKDatabase) async throws {
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

    func prepareShare(groupRecord: CKRecord, database: CKDatabase, title: String) async throws -> CKShare {
        let share = CKShare(rootRecord: groupRecord)
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        share.publicPermission = .none
        _ = try await modify(recordsToSave: [groupRecord, share], recordIDsToDelete: [], in: database)
        return share
    }

    func acceptShare(_ metadata: CKShare.Metadata) async throws {
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
        let linkedRecords = records.filter { record in
            guard record.recordID != group.recordID,
                  let reference = record[Field.group] as? CKRecord.Reference else {
                return false
            }

            return reference.recordID.recordName == group.recordID.recordName
                && reference.recordID.zoneID.zoneName == group.recordID.zoneID.zoneName
                && reference.recordID.zoneID.ownerName == group.recordID.zoneID.ownerName
        }

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
        return records.filter { record in
            guard record.recordID != group.recordID,
                  let reference = record[Field.group] as? CKRecord.Reference else {
                return false
            }

            return reference.recordID.recordName == group.recordID.recordName
                && reference.recordID.zoneID.zoneName == group.recordID.zoneID.zoneName
                && reference.recordID.zoneID.ownerName == group.recordID.zoneID.ownerName
        }
    }

    private func fetchLinkedRecords(recordType: String, group: CKRecord, database: CKDatabase) async throws -> [CKRecord] {
        let records = try await fetchRecordsInZone(zoneID: group.recordID.zoneID, database: database)
            .filter { $0.recordType == recordType }
        return records.filter { record in
            guard let reference = record[Field.group] as? CKRecord.Reference else {
                return false
            }

            return reference.recordID.recordName == group.recordID.recordName
                && reference.recordID.zoneID.zoneName == group.recordID.zoneID.zoneName
                && reference.recordID.zoneID.ownerName == group.recordID.zoneID.ownerName
        }
    }

    private func fetchRecordsInZone(zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> [CKRecord] {
        try await withCheckedThrowingContinuation { continuation in
            var records: [CKRecord] = []
            var zoneError: Error?
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: nil,
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
            operation.recordZoneFetchResultBlock = { _, result in
                if case .failure(let error) = result {
                    zoneError = error
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    if let zoneError {
                        continuation.resume(throwing: zoneError)
                    } else {
                        continuation.resume(returning: records)
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

    private func isCanonicalPersonalReference(_ reference: StoredGroupReference) -> Bool {
        reference.databaseScope == CKDatabase.Scope.private.rawValue
            && reference.recordName == personalWorkspaceRecordName
            && reference.zoneName == zoneID.zoneName
    }

    private func memberRecord(_ member: CareMember, groupRecord: CKRecord) -> CKRecord {
        let record = CKRecord(recordType: RecordType.member, recordID: CKRecord.ID(recordName: recordName(prefix: "member", id: member.id), zoneID: groupRecord.recordID.zoneID))
        record[Field.uuid] = member.id.uuidString as CKRecordValue
        record[Field.displayName] = member.displayName as CKRecordValue
        record[Field.colorHex] = member.colorHex as CKRecordValue
        record[Field.group] = CKRecord.Reference(recordID: groupRecord.recordID, action: .deleteSelf)
        return record
    }

    private func member(from record: CKRecord) -> CareMember? {
        guard
            let uuidString = record[Field.uuid] as? String,
            let id = UUID(uuidString: uuidString),
            let displayName = record[Field.displayName] as? String,
            let colorHex = record[Field.colorHex] as? String
        else {
            return nil
        }
        return CareMember(id: id, displayName: displayName, colorHex: colorHex)
    }

    private func decodePayload<T: Decodable>(_ record: CKRecord, as type: T.Type) -> T? {
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

private enum RecordType {
    static let group = "CareGroup"
    static let member = "CareMember"
    static let medication = "Medication"
    static let confirmation = "DoseConfirmation"
}

private enum Field {
    static let name = "name"
    static let uuid = "uuid"
    static let displayName = "displayName"
    static let colorHex = "colorHex"
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
