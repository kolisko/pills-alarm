import CloudKit
import CryptoKit
import Foundation

struct WorkspaceSource: Identifiable, Hashable {
    var id: String
    var name: String
    var isShared: Bool
}

struct MedicationListItem: Identifiable, Hashable {
    var medication: Medication
    var source: WorkspaceSource

    var id: String {
        "\(source.id)|\(medication.id.uuidString)"
    }
}

struct ConfirmationListItem: Identifiable, Hashable {
    var confirmation: DoseConfirmation
    var source: WorkspaceSource

    var id: String {
        "\(source.id)|\(confirmation.eventId)"
    }
}

struct SharedWorkspaceProfile: Identifiable, Hashable {
    var id: String
    var name: String
    var currentMemberName: String
    var otherMembers: [CareMember]
}

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
    @Published private(set) var medicationItems: [MedicationListItem] = []
    @Published private(set) var confirmations: [String: DoseConfirmation] = [:]
    @Published private(set) var confirmationItems: [ConfirmationListItem] = []
    @Published private(set) var sharedWorkspaceProfiles: [SharedWorkspaceProfile] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var syncErrorMessage: String?
    @Published private(set) var workspaceCandidates: [WorkspaceCandidate] = []
    @Published private(set) var currentUserRecordName: String?

    private let cloud: CloudKitRepository
    private let defaults: UserDefaults
    private var groupRecord: CKRecord?
    private var groupDatabase: CKDatabase?
    private var groupDatabaseScope: CKDatabase.Scope?
    private var workspaceContexts: [String: WorkspaceContext] = [:]
    private var medicationWorkspaceIds: [UUID: String] = [:]
    private var confirmationWorkspaceIds: [String: String] = [:]
    private var personalWorkspaceId: String?
    private var ownedGroupWorkspaceId: String?
    private var loadGeneration = 0
    private var syncOperationCount = 0

    init(cloud: CloudKitRepository? = nil, defaults: UserDefaults = .standard) {
        self.cloud = cloud ?? CloudKitRepository()
        self.defaults = defaults
    }

    var hasGroup: Bool {
        ownedGroupContext != nil
    }

    var hasCloudWorkspace: Bool {
        personalContext != nil
    }

    var activeMember: CareMember? {
        currentOwnedGroupMember
    }

    var currentMemberName: String {
        currentOwnedGroupMember?.displayName ?? ""
    }

    var sharingGroupId: String? {
        ownedGroupWorkspaceId
    }

    var sharingGroupName: String {
        careGroupName
    }

    var canSharePlans: Bool {
        ownedGroupContext != nil
    }

    var ownPlanItems: [MedicationListItem] {
        medicationItems.filter { canManageSharing($0) }
    }

    var sharedOwnPlanItems: [MedicationListItem] {
        medicationItems.filter { $0.source.id == ownedGroupWorkspaceId && canManageSharing($0) }
    }

    var privateOwnPlanItems: [MedicationListItem] {
        medicationItems.filter { $0.source.id == personalWorkspaceId && canManageSharing($0) }
    }

    var canRecordDose: Bool {
        !hasGroup || !currentMemberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func canRecordDose(_ dose: GeneratedDose) -> Bool {
        guard let context = workspaceContexts[dose.workspaceId], context.isShared || !context.members.isEmpty else {
            return true
        }

        return !currentMemberName(in: context).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func canEditMedication(_ item: MedicationListItem) -> Bool {
        canManageSharing(item)
    }

    func canManageSharing(_ item: MedicationListItem) -> Bool {
        guard let currentUserRecordName else {
            return false
        }

        if item.medication.ownerUserRecordName == nil {
            return item.source.id == personalWorkspaceId || item.source.id == ownedGroupWorkspaceId
        }

        return item.medication.ownerUserRecordName == currentUserRecordName
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

            currentUserRecordName = try await cloud.currentUserRecordName()
            guard generation == loadGeneration else { return }

            try await cloud.ensurePrivateZone()
            guard generation == loadGeneration else { return }

            let resolvedSnapshots = try await loadWorkspaceSnapshots()

            guard generation == loadGeneration else { return }

            try await cloud.repairShareHierarchy(for: resolvedSnapshots)
            guard generation == loadGeneration else { return }

            apply(snapshots: resolvedSnapshots)

            for context in workspaceContexts.values {
                try? await cloud.installWorkspaceSubscription(groupRecord: context.groupRecord, database: context.database)
            }

            guard generation == loadGeneration else { return }

            loadState = .ready
            syncErrorMessage = nil
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
        } catch {
            fail(error)
        }
    }

    func reportSyncError(_ error: Error) {
        recordSyncError(error)
    }

    func createGroup(name: String, firstMemberName: String) async {
        beginSync()
        defer { endSync() }

        loadGeneration += 1
        let cleanGroupName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMemberName = firstMemberName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGroupName.isEmpty, !cleanMemberName.isEmpty else { return }

        do {
            let userRecordName = try await ensureCurrentUserRecordName()
            if let context = ownedGroupContext {
                let member = currentUserMemberForSaving(displayName: cleanMemberName, userRecordName: userRecordName)
                let savedGroup = try await cloud.renameGroup(groupRecord: context.groupRecord, database: context.database, name: cleanGroupName)
                try await cloud.saveMember(member, groupRecord: savedGroup, database: context.database)
                self.groupRecord = savedGroup
                groupDatabaseScope = .private
                careGroupName = cleanGroupName
                members = [member]
                activeMemberId = member.id
                loadState = .ready
                await reload()
                return
            }

            let firstMember = currentUserMemberForSaving(displayName: cleanMemberName, userRecordName: userRecordName)
            let snapshot = try await cloud.createGroup(name: cleanGroupName, firstMember: firstMember)
            groupRecord = snapshot.group
            groupDatabase = snapshot.database
            groupDatabaseScope = snapshot.databaseScope
            ownedGroupWorkspaceId = Self.storedGroupReference(from: snapshot).id
            saveStoredGroupReference(from: snapshot)
            careGroupName = snapshot.name
            members = snapshot.members
            activeMemberId = snapshot.members.first?.id
            try? await cloud.installWorkspaceSubscription(groupRecord: snapshot.group, database: snapshot.database)
            loadState = .ready
            await reload()
        } catch {
            fail(error)
        }
    }

    func setGroupName(_ name: String) async {
        guard let context = ownedGroupContext else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        beginSync()
        defer { endSync() }

        do {
            let saved = try await cloud.renameGroup(groupRecord: context.groupRecord, database: context.database, name: cleanName)
            self.groupRecord = saved
            careGroupName = cleanName
        } catch {
            fail(error)
        }
    }

    func saveGroupSettings(name: String, myName: String) async {
        guard let context = ownedGroupContext else { return }
        let cleanGroupName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMemberName = myName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGroupName.isEmpty, !cleanMemberName.isEmpty else { return }

        beginSync()
        defer { endSync() }

        do {
            let userRecordName = try await ensureCurrentUserRecordName()
            let savedGroup = try await cloud.renameGroup(groupRecord: context.groupRecord, database: context.database, name: cleanGroupName)
            let member = currentUserMemberForSaving(displayName: cleanMemberName, userRecordName: userRecordName)
            try await cloud.saveMember(member, groupRecord: savedGroup, database: context.database)

            self.groupRecord = savedGroup
            careGroupName = cleanGroupName
            upsertMemberLocally(member)
            activeMemberId = member.id

            if let ownedGroupWorkspaceId,
               var updatedContext = workspaceContexts[ownedGroupWorkspaceId] {
                updatedContext.groupRecord = savedGroup
                updatedContext.name = cleanGroupName
                updatedContext.source = WorkspaceSource(id: updatedContext.id, name: cleanGroupName, isShared: true)
                workspaceContexts[ownedGroupWorkspaceId] = updatedContext
            }

            loadState = .ready
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
            Task { await reload() }
        } catch {
            recordSyncError(error)
        }
    }

    func saveSharedWorkspaceProfile(workspaceId: String, myName: String) async {
        guard var context = workspaceContexts[workspaceId], context.isShared else { return }
        let cleanMemberName = myName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMemberName.isEmpty else { return }

        beginSync()
        defer { endSync() }

        do {
            let userRecordName = try await ensureCurrentUserRecordName()
            let currentMember = currentUserMember(in: context)
            let member = CareMember(
                id: currentMember?.id ?? Self.memberId(forUserRecordName: userRecordName),
                displayName: cleanMemberName,
                colorHex: currentMember?.colorHex ?? Self.memberColors[context.members.count % Self.memberColors.count],
                userRecordName: userRecordName
            )

            try await cloud.saveMember(member, groupRecord: context.groupRecord, database: context.database)

            if let index = context.members.firstIndex(where: { $0.id == member.id }) {
                context.members[index] = member
            } else {
                context.members.append(member)
            }
            workspaceContexts[workspaceId] = context
            refreshSharedWorkspaceProfiles()
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
            Task { await reload() }
        } catch {
            recordSyncError(error)
        }
    }

    func doses(on date: Date) -> [GeneratedDose] {
        medicationItems.flatMap { item in
            ScheduleEngine.doses(
                on: date,
                medication: item.medication,
                workspaceId: item.source.id,
                isShared: item.source.isShared,
                workspaceName: item.source.name
            )
        }
        .sorted {
            if $0.scheduledDate == $1.scheduledDate {
                return $0.medicationName < $1.medicationName
            }
            return $0.scheduledDate < $1.scheduledDate
        }
    }

    func confirmation(for dose: GeneratedDose) -> DoseConfirmation? {
        confirmations[dose.id] ?? confirmations[dose.baseEventId]
    }

    private func confirmationEventIds(for dose: GeneratedDose, including confirmation: DoseConfirmation? = nil) -> [String] {
        var eventIds: [String] = []
        for eventId in [dose.id, dose.baseEventId, confirmation?.eventId].compactMap({ $0 }) {
            if !eventIds.contains(eventId) {
                eventIds.append(eventId)
            }
        }
        return eventIds
    }

    func displayName(for confirmation: DoseConfirmation) -> String? {
        let workspaceId = confirmationWorkspaceIds[confirmation.eventId] ?? personalWorkspaceId
        let member = workspaceId.flatMap { workspaceContexts[$0]?.members.first { $0.id == confirmation.memberId } }
            ?? members.first { $0.id == confirmation.memberId }
        let name = member?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    func confirm(_ dose: GeneratedDose, status: DoseStatus, note: String = "") async throws {
        guard let context = context(for: dose) else {
            let error = StoreError.missingCloudWorkspace
            recordSyncError(error)
            throw error
        }

        let memberId = try await currentConfirmationMemberId(in: context)

        let confirmation = DoseConfirmation(
            eventId: dose.id,
            medicationId: dose.medicationId,
            timeId: dose.timeId,
            scheduledDate: dose.scheduledDate,
            amount: dose.amount,
            status: status,
            memberId: memberId,
            memberName: "",
            timestamp: Date(),
            note: note
        )

        beginSync()
        defer { endSync() }

        do {
            for eventId in confirmationEventIds(for: dose, including: confirmation) {
                if try await cloud.fetchConfirmation(eventId: eventId, groupRecord: context.groupRecord, database: context.database) != nil {
                    await reload(showSyncIndicator: false)
                    return
                }
            }
            try await cloud.saveConfirmation(confirmation, groupRecord: context.groupRecord, database: context.database)
            confirmations[confirmation.eventId] = confirmation
            upsertConfirmationItemLocally(confirmation, source: context.source)
            confirmationWorkspaceIds[confirmation.eventId] = context.id
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
        } catch {
            recordSyncError(error)
            throw error
        }
    }

    func undoConfirmation(for dose: GeneratedDose) async throws {
        guard let context = context(for: dose) else {
            let error = StoreError.missingCloudWorkspace
            recordSyncError(error)
            throw error
        }

        beginSync()
        defer { endSync() }

        do {
            let existingConfirmation = confirmation(for: dose)
            let eventIds = confirmationEventIds(for: dose, including: existingConfirmation)

            var deletedAnyConfirmation = false
            for eventId in eventIds {
                if try await cloud.fetchConfirmation(eventId: eventId, groupRecord: context.groupRecord, database: context.database) != nil {
                    try await cloud.deleteConfirmation(eventId: eventId, groupRecord: context.groupRecord, database: context.database)
                    deletedAnyConfirmation = true
                }
            }

            if !deletedAnyConfirmation, let existingConfirmation {
                try await cloud.deleteConfirmation(eventId: existingConfirmation.eventId, groupRecord: context.groupRecord, database: context.database)
            }

            for eventId in eventIds {
                confirmations.removeValue(forKey: eventId)
                confirmationWorkspaceIds.removeValue(forKey: eventId)
            }
            confirmationItems.removeAll { eventIds.contains($0.confirmation.eventId) }
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
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
                        DoseEntry(timeId: morning.id, amount: 0),
                        DoseEntry(timeId: noon.id, amount: 0),
                        DoseEntry(timeId: evening.id, amount: 0)
                    ]
                )
            ]
        )
    }

    func upsertMedication(_ medication: Medication) async throws {
        guard let context = targetContext(for: medication) else {
            let error = StoreError.missingCloudWorkspace
            recordSyncError(error)
            throw error
        }
        var medicationToSave = medication
        medicationToSave.ownerUserRecordName = medicationToSave.ownerUserRecordName ?? currentUserRecordName

        beginSync()
        defer { endSync() }

        do {
            try await cloud.saveMedication(medicationToSave, groupRecord: context.groupRecord, database: context.database)
            upsertMedicationLocally(medicationToSave, source: source(for: context, medication: medicationToSave))
            loadState = .ready
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
        } catch {
            recordSyncError(error)
            throw error
        }
    }

    func deleteMedication(_ medication: Medication) {
        guard let workspaceId = medicationWorkspaceIds[medication.id],
              let context = workspaceContexts[workspaceId],
              !context.isShared else {
            return
        }

        Task {
            beginSync()
            defer { endSync() }

            do {
                try await deleteConfirmations(for: medication.id, in: context)
                try await cloud.deleteMedication(medication, groupRecord: context.groupRecord, database: context.database)
                await reload()
            } catch {
                recordSyncError(error)
            }
        }
    }

    func deleteMedication(_ item: MedicationListItem) {
        guard let context = workspaceContexts[item.source.id], !context.isShared else {
            return
        }

        Task {
            beginSync()
            defer { endSync() }

            do {
                try await deleteConfirmations(for: item.medication.id, in: context)
                try await cloud.deleteMedication(item.medication, groupRecord: context.groupRecord, database: context.database)
                await reload()
            } catch {
                recordSyncError(error)
            }
        }
    }

    func setMedication(_ item: MedicationListItem, updatedMedication: Medication? = nil, sharedWithOwnedGroup shouldShare: Bool) async throws {
        guard canManageSharing(item) else {
            let error = StoreError.notPlanOwner
            recordSyncError(error)
            throw error
        }

        guard let sourceContext = workspaceContexts[item.source.id],
              let personalContext else {
            let error = StoreError.missingCloudWorkspace
            recordSyncError(error)
            throw error
        }

        let destinationContext: WorkspaceContext
        if shouldShare {
            guard let ownedGroupContext else {
                let error = StoreError.missingGroup
                recordSyncError(error)
                throw error
            }
            destinationContext = ownedGroupContext
        } else {
            destinationContext = personalContext
        }

        guard sourceContext.id != destinationContext.id else { return }

        beginSync()
        defer { endSync() }

        do {
            let sourceConfirmations = confirmationsForMedication(item.medication.id, in: sourceContext)
            let updatedConfirmations = sourceConfirmations
                .map { confirmationForSharingChange($0, to: destinationContext) }
            var medicationForSharingChange = updatedMedication ?? item.medication
            medicationForSharingChange.ownerUserRecordName = medicationForSharingChange.ownerUserRecordName ?? currentUserRecordName
            medicationForSharingChange.sharedGroupId = shouldShare ? destinationContext.id : nil

            try await cloud.saveMedication(medicationForSharingChange, groupRecord: destinationContext.groupRecord, database: destinationContext.database)
            for confirmation in updatedConfirmations {
                try await cloud.saveConfirmation(confirmation, groupRecord: destinationContext.groupRecord, database: destinationContext.database)
            }
            try await deleteConfirmations(for: item.medication.id, in: sourceContext)
            if !isSameCloudRecordLocation(sourceContext, destinationContext) {
                try await cloud.deleteMedication(item.medication, groupRecord: sourceContext.groupRecord, database: sourceContext.database)
            }

            applySharingChangeLocally(
                medicationForSharingChange,
                updatedConfirmations: updatedConfirmations,
                originalConfirmationEventIds: sourceConfirmations.map(\.eventId),
                from: sourceContext,
                to: destinationContext
            )
            loadState = .ready
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
        } catch {
            recordSyncError(error)
            throw error
        }
    }

    func addMember(named name: String) {
        guard let context = ownedGroupContext else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        let member = CareMember(displayName: cleanName, colorHex: Self.memberColors[members.count % Self.memberColors.count])
        Task {
            beginSync()
            defer { endSync() }

            do {
                try await cloud.saveMember(member, groupRecord: context.groupRecord, database: context.database)
                await reload()
            } catch {
                recordSyncError(error)
            }
        }
    }

    func setCurrentMemberName(_ name: String) async {
        guard let context = ownedGroupContext else { return }

        beginSync()
        defer { endSync() }

        do {
            let userRecordName = try await ensureCurrentUserRecordName()
            let member = currentUserMemberForSaving(displayName: name, userRecordName: userRecordName)
            try await cloud.saveMember(member, groupRecord: context.groupRecord, database: context.database)
            upsertMemberLocally(member)
            activeMemberId = member.id
            Task { await reload() }
        } catch {
            recordSyncError(error)
        }
    }

    func updateMember(_ member: CareMember) {
        guard let context = ownedGroupContext else { return }

        Task {
            beginSync()
            defer { endSync() }

            do {
                try await cloud.saveMember(member, groupRecord: context.groupRecord, database: context.database)
                await reload()
            } catch {
                recordSyncError(error)
            }
        }
    }

    func deleteMember(_ member: CareMember) {
        guard let context = ownedGroupContext else { return }

        Task {
            beginSync()
            defer { endSync() }

            do {
                try await cloud.deleteMember(member, groupRecord: context.groupRecord, database: context.database)
                await reload()
            } catch {
                recordSyncError(error)
            }
        }
    }

    func prepareSharingController() async -> CloudSharingController? {
        guard let context = ownedGroupContext else {
            recordSyncError(StoreError.missingCloudWorkspace)
            return nil
        }

        beginSync()
        defer { endSync() }

        do {
            let prepared = try await cloud.prepareShare(
                groupRecord: context.groupRecord,
                database: context.database,
                title: careGroupName
            )
            self.groupRecord = prepared.groupRecord
            return CloudSharingController(
                share: prepared.share,
                groupRecord: prepared.groupRecord,
                database: context.database,
                title: careGroupName
            )
        } catch {
            recordSyncError(error)
            return nil
        }
    }

    static func acceptShare(_ metadata: CKShare.Metadata) async throws {
        let reference: StoredGroupReference
        switch metadata.participantStatus {
        case .pending:
            reference = try await CloudKitRepository().acceptShare(metadata)
        case .accepted:
            reference = try sharedGroupReference(from: metadata)
        case .unknown:
            throw CloudKitShareError.unexpectedParticipantStatus("unknown")
        case .removed:
            throw CloudKitShareError.unexpectedParticipantStatus("removed")
        @unknown default:
            throw CloudKitShareError.unexpectedParticipantStatus("unsupported")
        }
        saveAcceptedSharedGroupReference(reference, defaults: .standard)
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

    func removeSharedWorkspace(workspaceId: String) async {
        beginSync()
        defer { endSync() }

        var hidden = hiddenSharedWorkspaceIds
        hidden.insert(workspaceId)
        saveHiddenSharedWorkspaceIds(hidden)
        await reload()
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
        workspaceContexts = [:]
        medicationWorkspaceIds = [:]
        confirmationWorkspaceIds = [:]
        personalWorkspaceId = nil
        ownedGroupWorkspaceId = nil
        careGroupName = ""
        members = []
        activeMemberId = nil
        medications = []
        medicationItems = []
        confirmations = [:]
        confirmationItems = []
        sharedWorkspaceProfiles = []
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

    private func loadWorkspaceSnapshots() async throws -> [CloudSnapshot] {
        workspaceCandidates = []

        let personalSnapshot = try await cloud.ensurePersonalWorkspace()
        let allSnapshots = try await cloud.fetchAllGroupSnapshots()
        let privateGroupSnapshots = allSnapshots.filter {
            $0.databaseScope == .private && !cloud.isCanonicalPersonalWorkspace($0) && !$0.members.isEmpty
        }
        let hiddenSharedIds = hiddenSharedWorkspaceIds
        var snapshots = [personalSnapshot]
        var seenIds = Set([Self.storedGroupReference(from: personalSnapshot).id])

        for reference in loadAcceptedSharedGroupReferences() {
            guard reference.databaseScope == CKDatabase.Scope.shared.rawValue,
                  !hiddenSharedIds.contains(reference.id),
                  !seenIds.contains(reference.id) else { continue }

            guard let snapshot = try await cloud.fetchGroupSnapshot(reference: reference) else {
                throw CloudKitShareError.acceptedShareUnavailable(reference.id)
            }

            snapshots.append(snapshot)
            seenIds.insert(reference.id)
        }

        for snapshot in privateGroupSnapshots {
            let id = Self.storedGroupReference(from: snapshot).id
            guard !seenIds.contains(id) else { continue }
            snapshots.append(snapshot)
            seenIds.insert(id)
        }

        return snapshots
    }

    private func fail(_ error: Error) {
        let message = Self.userMessage(for: error)
        syncErrorMessage = message
        loadState = .failed(message)
    }

    private func upsertMedicationLocally(_ medication: Medication, source: WorkspaceSource? = nil) {
        let resolvedSource = source
            ?? medicationWorkspaceIds[medication.id].flatMap { workspaceContexts[$0]?.source }
            ?? personalContext?.source

        if let resolvedSource {
            let item = MedicationListItem(medication: medication, source: resolvedSource)
            if let index = medicationItems.firstIndex(where: { $0.id == item.id }) {
                medicationItems[index] = item
            } else {
                medicationItems.append(item)
            }
            medicationWorkspaceIds[medication.id] = resolvedSource.id
        } else {
            if let index = medications.firstIndex(where: { $0.id == medication.id }) {
                medications[index] = medication
            } else {
                medications.append(medication)
            }
        }

        sortMedicationViews()
    }

    private func upsertConfirmationItemLocally(_ confirmation: DoseConfirmation, source: WorkspaceSource) {
        let item = ConfirmationListItem(confirmation: confirmation, source: source)
        if let index = confirmationItems.firstIndex(where: { $0.id == item.id }) {
            confirmationItems[index] = item
        } else {
            confirmationItems.append(item)
        }
        confirmationItems.sort { $0.confirmation.timestamp > $1.confirmation.timestamp }
    }

    private func upsertMemberLocally(_ member: CareMember) {
        if let index = members.firstIndex(where: { $0.id == member.id }) {
            members[index] = member
        } else {
            members.append(member)
        }

        sortMembers()

        if let ownedGroupWorkspaceId,
           var context = workspaceContexts[ownedGroupWorkspaceId] {
            if let index = context.members.firstIndex(where: { $0.id == member.id }) {
                context.members[index] = member
            } else {
                context.members.append(member)
            }
            workspaceContexts[ownedGroupWorkspaceId] = context
        }
    }

    private func relinkPersonalConfirmations(to member: CareMember, userRecordName: String, groupRecord: CKRecord, database: CKDatabase) async throws {
        let stablePersonalMemberId = Self.memberId(forUserRecordName: userRecordName)
        let knownMemberIds = Set(members.map(\.id))
        let canClaimOrphanedPrivateConfirmations = groupDatabaseScope == .private
        var changedConfirmations: [DoseConfirmation] = []

        for confirmation in confirmations.values {
            if let personalWorkspaceId,
               let confirmationWorkspaceId = confirmationWorkspaceIds[confirmation.eventId],
               confirmationWorkspaceId != personalWorkspaceId {
                continue
            }

            let isAlreadyLinked = confirmation.memberId == member.id
            let isLegacyPersonal = confirmation.memberId == Self.legacyPersonalConfirmationMemberId
            let isStablePersonal = confirmation.memberId == stablePersonalMemberId
            let isOrphaned = !knownMemberIds.contains(confirmation.memberId)

            guard !isAlreadyLinked,
                  isLegacyPersonal || isStablePersonal || (canClaimOrphanedPrivateConfirmations && isOrphaned) else {
                continue
            }

            var updated = confirmation
            updated.memberId = member.id
            updated.memberName = ""
            changedConfirmations.append(updated)
        }

        for confirmation in changedConfirmations {
            try await cloud.saveConfirmation(confirmation, groupRecord: groupRecord, database: database)
            confirmations[confirmation.eventId] = confirmation
            if let source = personalContext?.source {
                upsertConfirmationItemLocally(confirmation, source: source)
            }
        }
    }

    private func apply(snapshot: CloudSnapshot) {
        apply(snapshots: [snapshot])
    }

    private func applySharingChangeLocally(
        _ medication: Medication,
        updatedConfirmations: [DoseConfirmation],
        originalConfirmationEventIds: [String],
        from sourceContext: WorkspaceContext,
        to destinationContext: WorkspaceContext
    ) {
        workspaceContexts[sourceContext.id]?.medications.removeAll { $0.id == medication.id }
        workspaceContexts[destinationContext.id]?.medications.removeAll { $0.id == medication.id }
        workspaceContexts[destinationContext.id]?.medications.append(medication)

        workspaceContexts[sourceContext.id]?.confirmations.removeAll { $0.medicationId == medication.id }
        workspaceContexts[destinationContext.id]?.confirmations.removeAll { $0.medicationId == medication.id }
        workspaceContexts[destinationContext.id]?.confirmations.append(contentsOf: updatedConfirmations)

        medicationItems.removeAll { $0.medication.id == medication.id }
        let destinationSource = source(for: destinationContext, medication: medication)
        medicationItems.append(MedicationListItem(medication: medication, source: destinationSource))
        medicationWorkspaceIds[medication.id] = destinationContext.id

        for eventId in originalConfirmationEventIds {
            confirmations.removeValue(forKey: eventId)
            confirmationWorkspaceIds.removeValue(forKey: eventId)
        }
        confirmationItems.removeAll { $0.confirmation.medicationId == medication.id }

        for confirmation in updatedConfirmations {
            confirmations[confirmation.eventId] = confirmation
            confirmationWorkspaceIds[confirmation.eventId] = destinationContext.id
            confirmationItems.append(ConfirmationListItem(confirmation: confirmation, source: destinationSource))
        }

        sortMedicationViews()
        confirmationItems.sort { $0.confirmation.timestamp > $1.confirmation.timestamp }
        refreshSharedWorkspaceProfiles()
    }

    private func apply(snapshots: [CloudSnapshot]) {
        let contexts = snapshots.map { WorkspaceContext(snapshot: $0) }
        workspaceContexts = Dictionary(uniqueKeysWithValues: contexts.map { ($0.id, $0) })

        guard let personal = contexts.first(where: { cloud.isCanonicalPersonalReference($0.reference) }) ?? contexts.first(where: { !$0.isShared }) ?? contexts.first else {
            clearLoadedData()
            return
        }

        let ownedGroup = contexts.first {
            !$0.isShared && $0.id != personal.id && !$0.members.isEmpty
        }

        personalWorkspaceId = personal.id
        ownedGroupWorkspaceId = ownedGroup?.id
        groupRecord = ownedGroup?.groupRecord
        groupDatabase = ownedGroup?.database
        groupDatabaseScope = ownedGroup?.databaseScope
        saveStoredGroupReference(from: CloudSnapshot(
            group: personal.groupRecord,
            database: personal.database,
            databaseScope: personal.databaseScope,
            name: personal.name,
            members: personal.members,
            medications: personal.medications,
            confirmations: personal.confirmations
        ))

        careGroupName = ownedGroup?.name ?? ""
        members = ownedGroup?.members ?? []
        sortMembers()
        activeMemberId = currentOwnedGroupMember?.id

        medicationWorkspaceIds = [:]
        confirmationWorkspaceIds = [:]
        medicationItems = []
        confirmationItems = []
        confirmations = [:]

        for context in contexts {
            for medication in context.medications {
                let source = source(for: context, medication: medication)
                medicationItems.append(MedicationListItem(medication: medication, source: source))
                medicationWorkspaceIds[medication.id] = context.id
            }
        }

        let validConfirmationKeys = Set(medicationItems.flatMap { item -> [String] in
            let contextId = item.source.id
            return item.medication.doseTimes.flatMap { doseTime in
                let base = "\(item.medication.id.uuidString)-\(doseTime.id.uuidString)"
                return contextId == personalWorkspaceId ? [base, "\(contextId)|\(base)"] : ["\(contextId)|\(base)"]
            }
        })

        for context in contexts {
            for confirmation in context.confirmations {
                guard validConfirmationKeys.contains(Self.confirmationSlotKey(confirmation.eventId)) else {
                    continue
                }
                let source = source(for: context, medicationId: confirmation.medicationId)
                let item = ConfirmationListItem(confirmation: confirmation, source: source)
                confirmationItems.append(item)
                confirmations[confirmation.eventId] = confirmation
                confirmationWorkspaceIds[confirmation.eventId] = context.id
            }
        }

        sortMedicationViews()
        confirmationItems.sort { $0.confirmation.timestamp > $1.confirmation.timestamp }
        sharedWorkspaceProfiles = contexts
            .filter { $0.isShared }
            .map { context in
                SharedWorkspaceProfile(
                    id: context.id,
                    name: context.name,
                    currentMemberName: currentMemberName(in: context),
                    otherMembers: otherMembers(in: context)
                )
            }

    }

    private func refreshSharedWorkspaceProfiles() {
        sharedWorkspaceProfiles = workspaceContexts.values
            .filter(\.isShared)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { context in
                SharedWorkspaceProfile(
                    id: context.id,
                    name: context.name,
                    currentMemberName: currentMemberName(in: context),
                    otherMembers: otherMembers(in: context)
                )
            }
    }

    private func sortMembers() {
        members.sort { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func sortMedicationViews() {
        medicationItems.sort { lhs, rhs in
            if lhs.source.isShared != rhs.source.isShared {
                return !lhs.source.isShared
            }
            return lhs.medication.name.localizedCaseInsensitiveCompare(rhs.medication.name) == .orderedAscending
        }
        medications = medicationItems.map(\.medication)
    }

    private func targetContext(for medication: Medication) -> WorkspaceContext? {
        if let sharedGroupId = medication.sharedGroupId {
            return workspaceContexts[sharedGroupId]
        }

        return personalContext
    }

    private func confirmationsForMedication(_ medicationId: UUID, in context: WorkspaceContext) -> [DoseConfirmation] {
        context.confirmations.filter { $0.medicationId == medicationId }
    }

    private func deleteConfirmations(for medicationId: UUID, in context: WorkspaceContext) async throws {
        for confirmation in confirmationsForMedication(medicationId, in: context) {
            try await cloud.deleteConfirmation(eventId: confirmation.eventId, groupRecord: context.groupRecord, database: context.database)
        }
    }

    private func confirmationForSharingChange(_ confirmation: DoseConfirmation, to destination: WorkspaceContext) -> DoseConfirmation {
        var updated = confirmation
        let baseEventId = Self.baseEventId(from: confirmation.eventId)
        updated.eventId = destination.id == personalWorkspaceId ? baseEventId : "\(destination.id)|\(baseEventId)"
        return updated
    }

    private func isSameCloudRecordLocation(_ lhs: WorkspaceContext, _ rhs: WorkspaceContext) -> Bool {
        lhs.databaseScope == rhs.databaseScope
            && lhs.groupRecord.recordID.zoneID == rhs.groupRecord.recordID.zoneID
    }

    private static func baseEventId(from eventId: String) -> String {
        guard let separator = eventId.range(of: "|", options: .backwards) else {
            return eventId
        }

        return String(eventId[separator.upperBound...])
    }

    private func source(for context: WorkspaceContext, medication: Medication) -> WorkspaceSource {
        WorkspaceSource(
            id: context.id,
            name: context.name,
            isShared: context.isShared || context.id == ownedGroupWorkspaceId || medication.sharedGroupId != nil
        )
    }

    private func source(for context: WorkspaceContext, medicationId: UUID) -> WorkspaceSource {
        let medication = context.medications.first { $0.id == medicationId }
        return WorkspaceSource(
            id: context.id,
            name: context.name,
            isShared: context.isShared || context.id == ownedGroupWorkspaceId || medication?.sharedGroupId != nil
        )
    }

    private static func confirmationSlotKey(_ eventId: String) -> String {
        if let separator = eventId.range(of: "|", options: .backwards) {
            let workspaceId = String(eventId[..<separator.lowerBound])
            let baseEventId = String(eventId[separator.upperBound...])
            let baseParts = baseEventId.split(separator: "-").map(String.init)
            guard baseParts.count >= 11 else { return eventId }
            let medicationId = baseParts.prefix(5).joined(separator: "-")
            let timeId = baseParts.dropFirst(5).prefix(5).joined(separator: "-")
            return "\(workspaceId)|\(medicationId)-\(timeId)"
        }

        let baseParts = eventId.split(separator: "-").map(String.init)
        guard baseParts.count >= 11 else { return eventId }
        let medicationId = baseParts.prefix(5).joined(separator: "-")
        let timeId = baseParts.dropFirst(5).prefix(5).joined(separator: "-")
        return "\(medicationId)-\(timeId)"
    }

    private var currentOwnedGroupMember: CareMember? {
        guard let ownedGroupContext else { return nil }
        return currentUserMember(in: ownedGroupContext)
    }

    private var personalContext: WorkspaceContext? {
        personalWorkspaceId.flatMap { workspaceContexts[$0] }
            ?? workspaceContexts.values.first(where: { !$0.isShared })
    }

    private var ownedGroupContext: WorkspaceContext? {
        ownedGroupWorkspaceId.flatMap { workspaceContexts[$0] }
            ?? workspaceContexts.values.first { !$0.isShared && $0.id != personalWorkspaceId && !$0.members.isEmpty }
    }

    private func context(for dose: GeneratedDose) -> WorkspaceContext? {
        if !dose.workspaceId.isEmpty, let context = workspaceContexts[dose.workspaceId] {
            return context
        }

        if let workspaceId = medicationWorkspaceIds[dose.medicationId],
           let context = workspaceContexts[workspaceId] {
            return context
        }

        return personalContext
    }

    private func currentUserMember(in context: WorkspaceContext) -> CareMember? {
        if let currentUserRecordName,
           let member = context.members.first(where: { $0.userRecordName == currentUserRecordName }) {
            return member
        }

        if context.id == personalWorkspaceId,
           let activeMemberId,
           let member = context.members.first(where: { $0.id == activeMemberId }) {
            return member
        }

        return nil
    }

    private func currentMemberName(in context: WorkspaceContext) -> String {
        currentUserMember(in: context)?.displayName ?? ""
    }

    private func otherMembers(in context: WorkspaceContext) -> [CareMember] {
        let currentId = currentUserMember(in: context)?.id
        return context.members.filter { $0.id != currentId }
    }

    private func ensureCurrentUserRecordName() async throws -> String {
        if let currentUserRecordName {
            return currentUserRecordName
        }

        let userRecordName = try await cloud.currentUserRecordName()
        currentUserRecordName = userRecordName
        return userRecordName
    }

    private func currentConfirmationMemberId(in context: WorkspaceContext? = nil) async throws -> UUID {
        if let context,
           !context.members.isEmpty,
           let member = currentUserMember(in: context) {
            return member.id
        }

        if let context, context.isShared {
            throw StoreError.missingSharedMemberName
        }

        if context == nil, hasGroup, let member = currentOwnedGroupMember {
            return member.id
        }

        let userRecordName = try await ensureCurrentUserRecordName()
        return Self.memberId(forUserRecordName: userRecordName)
    }

    private func currentUserMemberForSaving(displayName: String, userRecordName: String) -> CareMember {
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let memberId = currentOwnedGroupMember?.id ?? currentMemberIdForNewGroup(userRecordName: userRecordName)
        let colorHex = currentOwnedGroupMember?.colorHex ?? Self.memberColors[members.count % Self.memberColors.count]
        return CareMember(id: memberId, displayName: cleanName, colorHex: colorHex, userRecordName: userRecordName)
    }

    private func currentMemberIdForNewGroup(userRecordName: String) -> UUID {
        if members.isEmpty,
           confirmations.values.contains(where: { $0.memberId == Self.legacyPersonalConfirmationMemberId }) {
            return Self.legacyPersonalConfirmationMemberId
        }

        return Self.memberId(forUserRecordName: userRecordName)
    }

    private static func memberId(forUserRecordName userRecordName: String) -> UUID {
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
        Self.saveStoredGroupReference(reference, defaults: defaults)
    }

    private static func saveStoredGroupReference(_ reference: StoredGroupReference, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(reference) {
            defaults.set(data, forKey: storedGroupReferenceKey)
        }
    }

    private static func saveAcceptedSharedGroupReference(_ reference: StoredGroupReference, defaults: UserDefaults) {
        var references = loadAcceptedSharedGroupReferences(defaults: defaults)
        references.removeAll { $0.id == reference.id }
        references.append(reference)
        if let data = try? JSONEncoder().encode(references) {
            defaults.set(data, forKey: acceptedSharedGroupReferencesKey)
        }
    }

    private static func sharedGroupReference(from metadata: CKShare.Metadata) throws -> StoredGroupReference {
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

    private func loadAcceptedSharedGroupReferences() -> [StoredGroupReference] {
        Self.loadAcceptedSharedGroupReferences(defaults: defaults)
    }

    private static func loadAcceptedSharedGroupReferences(defaults: UserDefaults) -> [StoredGroupReference] {
        guard let data = defaults.data(forKey: acceptedSharedGroupReferencesKey) else {
            return []
        }

        return (try? JSONDecoder().decode([StoredGroupReference].self, from: data)) ?? []
    }

    private var hiddenSharedWorkspaceIds: Set<String> {
        guard let ids = defaults.array(forKey: Self.hiddenSharedWorkspaceIdsKey) as? [String] else {
            return []
        }

        return Set(ids)
    }

    private func saveHiddenSharedWorkspaceIds(_ ids: Set<String>) {
        defaults.set(Array(ids).sorted(), forKey: Self.hiddenSharedWorkspaceIdsKey)
    }

    private static let memberColors = ["#2F80ED", "#27AE60", "#EB5757", "#9B51E0", "#F2994A", "#00A3A3"]
    static let storedGroupReferenceKey = "PillCareStoredGroupReference"
    private static let acceptedSharedGroupReferencesKey = "PillCareAcceptedSharedGroupReferences"
    private static let hiddenSharedWorkspaceIdsKey = "PillCareHiddenSharedWorkspaceIds"
    private static let legacyPersonalConfirmationMemberId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

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

private struct WorkspaceContext {
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

private enum StoreError: LocalizedError {
    case missingCloudWorkspace
    case missingGroup
    case missingSharedMemberName
    case notPlanOwner

    var errorDescription: String? {
        switch self {
        case .missingCloudWorkspace:
            return "iCloud úložiště ještě není připravené. Chvíli počkej a zkus uložit znovu."
        case .missingGroup:
            return "Nejdřív vytvoř skupinu, potom můžeš plán sdílet."
        case .missingSharedMemberName:
            return "Nejdřív ve Skupině vyplň svoje jméno pro sdílenou skupinu."
        case .notPlanOwner:
            return "Sdílení a úpravy tohohle plánu může měnit jen vlastník plánu."
        }
    }
}

private enum CloudKitShareError: LocalizedError {
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

    private func member(from record: CKRecord) -> CareMember? {
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
