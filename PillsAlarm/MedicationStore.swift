import CloudKit
import Foundation
import PillCore

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
    @Published private(set) var medicalTimelinePublicIdentifier: String?

    private let cloud: CloudKitRepository
    private let defaults: UserDefaults
    private let domainState = MedicationDomainStore()
    private lazy var zoneChangeTokens = ZoneChangeTokenStore(defaults: defaults)
    private var groupRecord: CKRecord?
    private var groupDatabaseScope: CKDatabase.Scope?
    private var workspaceContexts: [String: WorkspaceContext] = [:]
    private var personalWorkspaceId: String?
    private var ownedGroupWorkspaceId: String?
    private var loadGeneration = 0
    private var syncOperationCount = 0
    private var hasLoadedCloudState = false

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
        MedicationAccessRules.canRecordDose(hasGroup: hasGroup, currentMemberName: currentMemberName)
    }

    func canRecordDose(_ dose: GeneratedDose) -> Bool {
        guard let context = workspaceContexts[dose.workspaceId], context.isShared || !context.members.isEmpty else {
            return true
        }

        return MedicationAccessRules.canRecordDose(
            contextIsShared: context.isShared,
            contextHasMembers: !context.members.isEmpty,
            currentMemberName: currentMemberName(in: context)
        )
    }

    func canEditMedication(_ item: MedicationListItem) -> Bool {
        canManageSharing(item)
    }

    func canManageSharing(_ item: MedicationListItem) -> Bool {
        MedicationAccessRules.canManageMedication(
            item,
            currentUserRecordName: currentUserRecordName,
            personalWorkspaceId: personalWorkspaceId,
            ownedGroupWorkspaceId: ownedGroupWorkspaceId
        )
    }

    func start() async {
        await reload()
        await NotificationScheduler.shared.requestAuthorizationIfNeeded()
        NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
    }

    func reload(showSyncIndicator: Bool = true, forceFullRecovery: Bool = false) async {
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

            let requestedMode: WorkspaceSyncMode
            if !hasLoadedCloudState {
                requestedMode = .fullRecovery(repairShareHierarchy: true)
            } else if forceFullRecovery {
                requestedMode = .fullRecovery(repairShareHierarchy: false)
            } else {
                requestedMode = .incremental
            }
            let syncResult = try await loadWorkspaceSnapshots(mode: requestedMode)
            let resolvedSnapshots = syncResult.snapshots

            guard generation == loadGeneration else { return }

            if syncResult.shouldRepairShareHierarchy {
                try await cloud.repairShareHierarchy(for: resolvedSnapshots)
                guard generation == loadGeneration else { return }
            }

            if syncResult.hasDataChanges {
                apply(snapshots: resolvedSnapshots)
                hasLoadedCloudState = true
            }
            for (reference, token) in syncResult.zoneTokensToCommit {
                zoneChangeTokens.set(token, for: reference)
            }

            var subscriptionError: Error?
            for snapshot in syncResult.subscriptionSnapshots {
                do {
                    try await cloud.installWorkspaceSubscription(
                        groupRecord: snapshot.group,
                        database: snapshot.database,
                        databaseScope: snapshot.databaseScope
                    )
                } catch {
                    subscriptionError = error
                }
            }

            guard generation == loadGeneration else { return }

            loadState = .ready
            if let subscriptionError {
                recordSyncError(subscriptionError)
            } else {
                syncErrorMessage = nil
            }
            if syncResult.hasDataChanges {
                NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
            }
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
            groupDatabaseScope = snapshot.databaseScope
            ownedGroupWorkspaceId = Self.storedGroupReference(from: snapshot).id
            saveStoredGroupReference(from: snapshot)
            careGroupName = snapshot.name
            members = snapshot.members
            activeMemberId = snapshot.members.first?.id
            do {
                try await cloud.installWorkspaceSubscription(
                    groupRecord: snapshot.group,
                    database: snapshot.database,
                    databaseScope: snapshot.databaseScope
                )
            } catch {
                recordSyncError(error)
            }
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
            let member = MemberIdentityRules.currentUserMemberForSaving(
                displayName: cleanMemberName,
                userRecordName: userRecordName,
                currentMember: currentUserMember(in: context),
                memberCount: context.members.count,
                membersAreEmpty: context.members.isEmpty,
                hasLegacyPersonalConfirmations: false
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
        domainState.confirmation(for: dose)
    }

    func displayName(for confirmation: DoseConfirmation) -> String? {
        let workspaceId = domainState.workspaceId(forConfirmationEventId: confirmation.eventId) ?? personalWorkspaceId
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

        let command = ConfirmDoseUseCase.makeCommand(
            dose: dose,
            status: status,
            memberId: memberId,
            timestamp: Date(),
            note: note
        )

        beginSync()
        defer { endSync() }

        do {
            for eventId in command.eventIdsToCheck {
                if try await cloud.fetchConfirmation(eventId: eventId, groupRecord: context.groupRecord, database: context.database) != nil {
                    await reload(showSyncIndicator: false)
                    return
                }
            }
            try await cloud.saveConfirmation(command.confirmation, groupRecord: context.groupRecord, database: context.database)
            upsertConfirmationLocally(command.confirmation, in: context)
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
            let eventIds = UndoDoseConfirmationUseCase.eventIdsToDelete(for: dose, existingConfirmation: existingConfirmation)

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

            removeConfirmationsLocally(eventIds: eventIds)
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
        } catch {
            recordSyncError(error)
            throw error
        }
    }

    func addMedication() -> Medication {
        MedicationFactory.newMedication()
    }

    func upsertMedication(_ medication: Medication) async throws {
        guard let context = targetContext(for: medication) else {
            let error = StoreError.missingCloudWorkspace
            recordSyncError(error)
            throw error
        }
        let medicationToSave = UpsertMedicationUseCase.medicationForSaving(medication, currentUserRecordName: currentUserRecordName)
        let exportItems = medicationItemsByReplacing(medicationToSave, in: context)

        beginSync()
        defer { endSync() }

        do {
            try await cloud.saveMedication(medicationToSave, groupRecord: context.groupRecord, database: context.database)
            try await syncMedicalTimelineExport(items: exportItems)
            upsertMedicationLocally(medicationToSave, source: source(for: context, medication: medicationToSave))
            loadState = .ready
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: self)
        } catch {
            recordSyncError(error)
            throw error
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
                try await syncMedicalTimelineExport(items: medicationItems.filter { $0.medication.id != item.medication.id })
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
            let change = ShareMedicationUseCase.makeChange(
                item: item,
                updatedMedication: updatedMedication,
                shouldShare: shouldShare,
                destinationWorkspaceId: destinationContext.id,
                currentUserRecordName: currentUserRecordName,
                sourceConfirmations: sourceConfirmations
            )

            try await cloud.saveMedication(change.medication, groupRecord: destinationContext.groupRecord, database: destinationContext.database)
            for confirmation in change.updatedConfirmations {
                try await cloud.saveConfirmation(confirmation, groupRecord: destinationContext.groupRecord, database: destinationContext.database)
            }
            if isSameCloudRecordLocation(sourceContext, destinationContext) {
                for confirmation in sourceConfirmations where !change.updatedConfirmationEventIds.contains(confirmation.eventId) {
                    try await cloud.deleteConfirmation(eventId: confirmation.eventId, groupRecord: sourceContext.groupRecord, database: sourceContext.database)
                }
            } else {
                try await deleteConfirmations(for: item.medication.id, in: sourceContext)
            }
            if !isSameCloudRecordLocation(sourceContext, destinationContext) {
                try await cloud.deleteMedication(item.medication, groupRecord: sourceContext.groupRecord, database: sourceContext.database)
            }
            try await syncMedicalTimelineExport(items: medicationItemsByReplacing(change.medication, in: destinationContext))

            applySharingChangeLocally(
                change.medication,
                updatedConfirmations: change.updatedConfirmations,
                originalConfirmationEventIds: change.originalConfirmationEventIds,
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

    private func syncMedicalTimelineExport(items: [MedicationListItem]) async throws {
        let publishedMedications = items
            .filter { $0.medication.isPublishedToMedicalTimeline && isOwnedMedicalTimelineSource($0.source.id) }
            .map(\.medication)

        guard !publishedMedications.isEmpty || medicalTimelinePublicIdentifier != nil else { return }
        guard let context = personalContext else { throw StoreError.missingCloudWorkspace }

        let identifierResult = try await cloud.ensureMedicalTimelineExportIdentifier(
            groupRecord: context.groupRecord,
            database: context.database
        )
        updatePersonalContextGroupRecord(identifierResult.groupRecord)
        medicalTimelinePublicIdentifier = identifierResult.identifier
        try await cloud.saveMedicalTimelineExport(identifier: identifierResult.identifier, medications: publishedMedications)
    }

    func addMember(named name: String) {
        guard let context = ownedGroupContext else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        let member = CareMember(displayName: cleanName, colorHex: MemberIdentityRules.color(forMemberCount: members.count))
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
            groupDatabaseScope = snapshot.databaseScope
            saveStoredGroupReference(from: snapshot)
            apply(snapshot: snapshot)
            workspaceCandidates = []
            do {
                try await cloud.installWorkspaceSubscription(
                    groupRecord: snapshot.group,
                    database: snapshot.database,
                    databaseScope: snapshot.databaseScope
                )
            } catch {
                recordSyncError(error)
            }
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
        groupDatabaseScope = nil
        workspaceContexts = [:]
        personalWorkspaceId = nil
        ownedGroupWorkspaceId = nil
        medicalTimelinePublicIdentifier = nil
        hasLoadedCloudState = false
        careGroupName = ""
        members = []
        activeMemberId = nil
        domainState.reset()
        publishDomainState()
        sharedWorkspaceProfiles = []
    }

    private func loadWorkspaceSnapshots(mode: WorkspaceSyncMode) async throws -> WorkspaceSyncResult {
        workspaceCandidates = []

        switch mode {
        case .fullRecovery(let repairShareHierarchy):
            return try await loadFullWorkspaceSnapshots(repairShareHierarchy: repairShareHierarchy)
        case .incremental:
            return try await loadIncrementalWorkspaceSnapshots()
        }
    }

    private func loadFullWorkspaceSnapshots(repairShareHierarchy: Bool) async throws -> WorkspaceSyncResult {
        let privateZoneResult = try await cloud.fetchPrivateGroupSnapshotsEnsuringPersonalWorkspace()
        var zoneTokensToCommit: [StoredGroupReference: CKServerChangeToken] = [:]
        for snapshot in privateZoneResult.snapshots {
            if let serverChangeToken = privateZoneResult.serverChangeToken {
                zoneTokensToCommit[Self.storedGroupReference(from: snapshot)] = serverChangeToken
            }
        }

        guard let personalSnapshot = privateZoneResult.snapshots.first(where: { cloud.isCanonicalPersonalWorkspace($0) }) else {
            throw StoreError.missingCloudWorkspace
        }

        let privateGroupSnapshots = privateZoneResult.snapshots.filter {
            $0.databaseScope == .private && !cloud.isCanonicalPersonalWorkspace($0) && !$0.members.isEmpty
        }

        let hiddenSharedIds = hiddenSharedWorkspaceIds
        var snapshots = [personalSnapshot]
        var seenIds = Set([Self.storedGroupReference(from: personalSnapshot).id])

        for reference in loadAcceptedSharedGroupReferences() {
            guard reference.databaseScope == CKDatabase.Scope.shared.rawValue,
                  !hiddenSharedIds.contains(reference.id),
                  !seenIds.contains(reference.id) else { continue }

            guard let result = try await cloud.fetchGroupSnapshotWithToken(reference: reference),
                  let snapshot = result.snapshot else {
                throw CloudKitShareError.acceptedShareUnavailable(reference.id)
            }

            if let serverChangeToken = result.serverChangeToken {
                zoneTokensToCommit[reference] = serverChangeToken
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

        return WorkspaceSyncResult(
            snapshots: snapshots,
            hasDataChanges: true,
            didFullRecovery: true,
            shouldRepairShareHierarchy: repairShareHierarchy,
            subscriptionSnapshots: snapshots,
            zoneTokensToCommit: zoneTokensToCommit
        )
    }

    private func loadIncrementalWorkspaceSnapshots() async throws -> WorkspaceSyncResult {
        let hiddenSharedIds = hiddenSharedWorkspaceIds
        var contexts = workspaceContexts
        var seenIds = Set<String>()
        var subscriptionSnapshots: [CloudSnapshot] = []
        var hasDataChanges = false
        var didFullRecovery = false
        var zoneTokensToCommit: [StoredGroupReference: CKServerChangeToken] = [:]

        var references = contexts.values.map(\.reference)
        let acceptedReferences = loadAcceptedSharedGroupReferences().filter {
            $0.databaseScope == CKDatabase.Scope.shared.rawValue && !hiddenSharedIds.contains($0.id)
        }
        for reference in acceptedReferences where !references.contains(reference) {
            references.append(reference)
        }

        for reference in references {
            guard !hiddenSharedIds.contains(reference.id) else {
                if contexts.removeValue(forKey: reference.id) != nil {
                    hasDataChanges = true
                }
                zoneChangeTokens.removeToken(for: reference)
                continue
            }

            seenIds.insert(reference.id)

            guard var context = contexts[reference.id] else {
                guard let result = try await cloud.fetchGroupSnapshotWithToken(reference: reference),
                      let snapshot = result.snapshot else {
                    throw CloudKitShareError.acceptedShareUnavailable(reference.id)
                }
                if let serverChangeToken = result.serverChangeToken {
                    zoneTokensToCommit[reference] = serverChangeToken
                }
                let newContext = WorkspaceContext(snapshot: snapshot)
                contexts[reference.id] = newContext
                subscriptionSnapshots.append(snapshot)
                hasDataChanges = true
                didFullRecovery = true
                continue
            }

            guard let token = zoneChangeTokens.token(for: reference) else {
                guard let result = try await cloud.fetchGroupSnapshotWithToken(reference: reference),
                      let snapshot = result.snapshot else {
                    contexts.removeValue(forKey: reference.id)
                    hasDataChanges = true
                    continue
                }
                if let serverChangeToken = result.serverChangeToken {
                    zoneTokensToCommit[reference] = serverChangeToken
                }
                contexts[reference.id] = WorkspaceContext(snapshot: snapshot)
                subscriptionSnapshots.append(snapshot)
                hasDataChanges = true
                didFullRecovery = true
                continue
            }

            do {
                let changes = try await cloud.fetchZoneChanges(reference: reference, previousServerChangeToken: token)

                if let serverChangeToken = changes.serverChangeToken {
                    zoneTokensToCommit[reference] = serverChangeToken
                }

                guard !changes.changedRecords.isEmpty || !changes.deletedRecordIDs.isEmpty else {
                    continue
                }

                if apply(changes: changes, to: &context) {
                    contexts[reference.id] = context
                } else {
                    contexts.removeValue(forKey: reference.id)
                    zoneChangeTokens.removeToken(for: reference)
                }
                hasDataChanges = true
            } catch {
                guard cloud.isChangeTokenExpired(error) else { throw error }

                zoneChangeTokens.removeToken(for: reference)
                guard let result = try await cloud.fetchGroupSnapshotWithToken(reference: reference),
                      let snapshot = result.snapshot else {
                    contexts.removeValue(forKey: reference.id)
                    hasDataChanges = true
                    didFullRecovery = true
                    continue
                }
                if let serverChangeToken = result.serverChangeToken {
                    zoneTokensToCommit[reference] = serverChangeToken
                }
                contexts[reference.id] = WorkspaceContext(snapshot: snapshot)
                subscriptionSnapshots.append(snapshot)
                hasDataChanges = true
                didFullRecovery = true
            }
        }

        let staleContexts = contexts.values.filter { !seenIds.contains($0.id) }
        for staleContext in staleContexts {
            contexts.removeValue(forKey: staleContext.id)
            zoneChangeTokens.removeToken(for: staleContext.reference)
            hasDataChanges = true
        }

        let snapshots = contexts.values.map { context in
            CloudSnapshot(
                group: context.groupRecord,
                database: context.database,
                databaseScope: context.databaseScope,
                name: context.name,
                members: context.members,
                medications: context.medications,
                confirmations: context.confirmations
            )
        }

        return WorkspaceSyncResult(
            snapshots: snapshots,
            hasDataChanges: hasDataChanges,
            didFullRecovery: didFullRecovery,
            shouldRepairShareHierarchy: didFullRecovery,
            subscriptionSnapshots: subscriptionSnapshots,
            zoneTokensToCommit: zoneTokensToCommit
        )
    }

    private func apply(changes: ZoneChanges, to context: inout WorkspaceContext) -> Bool {
        for recordID in changes.deletedRecordIDs {
            if recordID.recordName == context.groupRecord.recordID.recordName {
                return false
            }

            if let memberId = Self.uuid(fromRecordName: recordID.recordName, prefix: "member") {
                context.members.removeAll { $0.id == memberId }
            } else if let medicationId = Self.uuid(fromRecordName: recordID.recordName, prefix: "medication") {
                context.medications.removeAll { $0.id == medicationId }
                context.confirmations.removeAll { $0.medicationId == medicationId }
            } else if let eventId = Self.confirmationEventId(fromRecordName: recordID.recordName) {
                context.confirmations.removeAll { $0.eventId == eventId }
            }
        }

        for record in changes.changedRecords {
            switch record.recordType {
            case RecordType.group where record.recordID.recordName == context.groupRecord.recordID.recordName:
                context.groupRecord = record
                context.name = record[Field.name] as? String ?? ""
                context.source = WorkspaceSource(id: context.id, name: context.name, isShared: context.isShared)
                if cloud.isCanonicalPersonalReference(context.reference) {
                    medicalTimelinePublicIdentifier = cloud.medicalTimelineExportIdentifier(from: record)
                }
            case RecordType.member where cloud.isRecord(record, linkedTo: context.groupRecord):
                guard let member = cloud.member(from: record) else { continue }
                if let index = context.members.firstIndex(where: { $0.id == member.id }) {
                    context.members[index] = member
                } else {
                    context.members.append(member)
                }
            case RecordType.medication where cloud.isRecord(record, linkedTo: context.groupRecord):
                guard let medication = cloud.decodePayload(record, as: Medication.self) else { continue }
                if let index = context.medications.firstIndex(where: { $0.id == medication.id }) {
                    context.medications[index] = medication
                } else {
                    context.medications.append(medication)
                }
            case RecordType.confirmation where cloud.isRecord(record, linkedTo: context.groupRecord):
                guard let confirmation = cloud.decodePayload(record, as: DoseConfirmation.self) else { continue }
                if let index = context.confirmations.firstIndex(where: { $0.eventId == confirmation.eventId }) {
                    context.confirmations[index] = confirmation
                } else {
                    context.confirmations.append(confirmation)
                }
            default:
                continue
            }
        }

        context.members.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return true
    }

    private func fail(_ error: Error) {
        let message = Self.userMessage(for: error)
        syncErrorMessage = message
        loadState = .failed(message)
    }

    private func upsertMedicationLocally(_ medication: Medication, source: WorkspaceSource? = nil) {
        let resolvedSource = source
            ?? domainState.workspaceId(forMedicationId: medication.id).flatMap { workspaceContexts[$0]?.source }
            ?? personalContext?.source

        if let resolvedSource,
           let workspaceId = source?.id ?? domainState.workspaceId(forMedicationId: medication.id) ?? personalContext?.id {
            if workspaceContexts[workspaceId] != nil {
                workspaceContexts[workspaceId]?.medications.removeAll { $0.id == medication.id }
                workspaceContexts[workspaceId]?.medications.append(medication)
            }
            domainState.upsertMedication(medication, workspaceId: workspaceId, source: resolvedSource)
        }

        publishDomainState()
    }

    private func publishDomainState() {
        medications = domainState.medications
        medicationItems = domainState.medicationItems
        confirmations = domainState.confirmations
        confirmationItems = domainState.confirmationItems
    }

    private func upsertConfirmationLocally(_ confirmation: DoseConfirmation, in context: WorkspaceContext) {
        domainState.upsertConfirmation(confirmation, workspaceId: context.id, source: source(for: context, medicationId: confirmation.medicationId))
        workspaceContexts[context.id]?.confirmations.removeAll { $0.eventId == confirmation.eventId }
        workspaceContexts[context.id]?.confirmations.append(confirmation)
        publishDomainState()
    }

    private func removeConfirmationsLocally(eventIds: [String]) {
        domainState.removeConfirmations(eventIds: eventIds)
        for contextId in workspaceContexts.keys {
            workspaceContexts[contextId]?.confirmations.removeAll { eventIds.contains($0.eventId) }
        }
        publishDomainState()
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
        let stablePersonalMemberId = MemberIdentityRules.memberId(forUserRecordName: userRecordName)
        let knownMemberIds = Set(members.map(\.id))
        let canClaimOrphanedPrivateConfirmations = groupDatabaseScope == .private
        var changedConfirmations: [DoseConfirmation] = []

        for confirmation in domainState.allConfirmations {
            if let personalWorkspaceId,
               let confirmationWorkspaceId = domainState.workspaceId(forConfirmationEventId: confirmation.eventId),
               confirmationWorkspaceId != personalWorkspaceId {
                continue
            }

            let isAlreadyLinked = confirmation.memberId == member.id
            let isLegacyPersonal = confirmation.memberId == MemberIdentityRules.legacyPersonalConfirmationMemberId
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
            if let personalContext {
                upsertConfirmationLocally(confirmation, in: personalContext)
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

        let destinationSource = source(for: destinationContext, medication: medication)
        domainState.applySharingChange(
            medication: medication,
            updatedConfirmations: updatedConfirmations,
            originalConfirmationEventIds: originalConfirmationEventIds,
            destinationWorkspaceId: destinationContext.id,
            destinationSource: destinationSource
        )
        publishDomainState()
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
        medicalTimelinePublicIdentifier = cloud.medicalTimelineExportIdentifier(from: personal.groupRecord)
        groupRecord = ownedGroup?.groupRecord
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

        domainState.reset()
        publishDomainState()

        var medicationEntries: [MedicationStateEntry] = []

        for context in contexts {
            for medication in context.medications {
                let source = source(for: context, medication: medication)
                medicationEntries.append(MedicationStateEntry(medication: medication, workspaceId: context.id, source: source))
            }
        }

        let validConfirmationSlots = Set(medicationEntries.flatMap { entry in
            entry.medication.doseTimes.map { doseTime in
                Self.confirmationSlotKey(medicationId: entry.medication.id, timeId: doseTime.id)
            }
        })

        var confirmationEntries: [ConfirmationStateEntry] = []
        for context in contexts {
            for confirmation in context.confirmations {
                guard validConfirmationSlots.contains(Self.confirmationSlotKey(for: confirmation)) else {
                    continue
                }
                let source = source(for: context, medicationId: confirmation.medicationId)
                confirmationEntries.append(ConfirmationStateEntry(confirmation: confirmation, workspaceId: context.id, source: source))
            }
        }
        domainState.replace(medications: medicationEntries, confirmations: confirmationEntries)
        publishDomainState()

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

    private func targetContext(for medication: Medication) -> WorkspaceContext? {
        if let sharedGroupId = medication.sharedGroupId {
            return workspaceContexts[sharedGroupId]
        }

        return personalContext
    }

    private func medicationItemsByReplacing(_ medication: Medication, in context: WorkspaceContext) -> [MedicationListItem] {
        var items = medicationItems.filter { $0.medication.id != medication.id }
        items.append(MedicationListItem(medication: medication, source: source(for: context, medication: medication)))
        return items
    }

    private func isOwnedMedicalTimelineSource(_ sourceId: String) -> Bool {
        sourceId == personalWorkspaceId || sourceId == ownedGroupWorkspaceId
    }

    private func updatePersonalContextGroupRecord(_ groupRecord: CKRecord) {
        guard let personalWorkspaceId,
              var context = workspaceContexts[personalWorkspaceId] else { return }

        context.groupRecord = groupRecord
        workspaceContexts[personalWorkspaceId] = context
    }

    private func confirmationsForMedication(_ medicationId: UUID, in context: WorkspaceContext) -> [DoseConfirmation] {
        domainState.confirmations(forMedicationId: medicationId, in: context.id)
    }

    private func deleteConfirmations(for medicationId: UUID, in context: WorkspaceContext) async throws {
        for confirmation in confirmationsForMedication(medicationId, in: context) {
            try await cloud.deleteConfirmation(eventId: confirmation.eventId, groupRecord: context.groupRecord, database: context.database)
        }
    }

    private func isSameCloudRecordLocation(_ lhs: WorkspaceContext, _ rhs: WorkspaceContext) -> Bool {
        lhs.databaseScope == rhs.databaseScope
            && lhs.groupRecord.recordID.zoneID == rhs.groupRecord.recordID.zoneID
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

    private static func confirmationSlotKey(for confirmation: DoseConfirmation) -> String {
        confirmationSlotKey(medicationId: confirmation.medicationId, timeId: confirmation.timeId)
    }

    private static func confirmationSlotKey(medicationId: UUID, timeId: UUID) -> String {
        "\(medicationId.uuidString)-\(timeId.uuidString)"
    }

    private static func uuid(fromRecordName recordName: String, prefix: String) -> UUID? {
        let marker = "\(prefix)-"
        guard recordName.hasPrefix(marker) else { return nil }
        return UUID(uuidString: String(recordName.dropFirst(marker.count)))
    }

    private static func confirmationEventId(fromRecordName recordName: String) -> String? {
        let marker = "confirmation-"
        guard recordName.hasPrefix(marker) else { return nil }
        return String(recordName.dropFirst(marker.count))
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

        if let workspaceId = domainState.workspaceId(forMedicationId: dose.medicationId),
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
        return MemberIdentityRules.memberId(forUserRecordName: userRecordName)
    }

    private func currentUserMemberForSaving(displayName: String, userRecordName: String) -> CareMember {
        MemberIdentityRules.currentUserMemberForSaving(
            displayName: displayName,
            userRecordName: userRecordName,
            currentMember: currentOwnedGroupMember,
            memberCount: members.count,
            membersAreEmpty: members.isEmpty,
            hasLegacyPersonalConfirmations: confirmations.values.contains { $0.memberId == MemberIdentityRules.legacyPersonalConfirmationMemberId }
        )
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

    static let storedGroupReferenceKey = "PillCareStoredGroupReference"
    private static let acceptedSharedGroupReferencesKey = "PillCareAcceptedSharedGroupReferences"
    private static let hiddenSharedWorkspaceIdsKey = "PillCareHiddenSharedWorkspaceIds"
}
