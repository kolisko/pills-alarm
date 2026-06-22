import CloudKit
import Foundation
import SwiftUI
import PillCore

#if DEBUG && targetEnvironment(simulator)

@MainActor
final class CloudKitDiagnosticsModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lines: [String] = []
    @Published private(set) var lastReport: IntegrationReport?

    func run() async {
        guard !isRunning else { return }

        isRunning = true
        lines = []
        lastReport = nil

        let report = await CloudKitIntegrationRunner.run { [weak self] line in
            self?.lines.append(line)
        }
        CloudKitIntegrationRunner.write(report: report)
        lastReport = report
        isRunning = false
    }
}

@MainActor
enum CloudKitIntegrationRunner {
    static let launchArgument = "--run-cloudkit-integration"
    private static let planStoryArgument = "--run-cloudkit-plan-story"
    private static let planUpgradeCreateArgument = "--run-cloudkit-plan-upgrade-create"
    private static let planUpgradeVerifyArgument = "--run-cloudkit-plan-upgrade-verify"
    private static let dumpStateArgument = "--dump-cloudkit-state"

    static var isRequested: Bool {
        requestedMode != nil
    }

    static func runAndWriteReport() async {
        let report: IntegrationReport
        switch requestedMode {
        case .fullIntegration:
            report = await run { print($0) }
        case .planStory:
            report = await runPlanStory { print($0) }
        case .planUpgradeCreate:
            report = await runPlanUpgradeCreate { print($0) }
        case .planUpgradeVerify:
            report = await runPlanUpgradeVerify { print($0) }
        case .dumpState:
            report = await dumpState { print($0) }
        case nil:
            report = await run { print($0) }
        }
        write(report: report)
    }

    private static var requestedMode: Mode? {
        if CommandLine.arguments.contains(planStoryArgument) {
            return .planStory
        }
        if CommandLine.arguments.contains(planUpgradeCreateArgument) {
            return .planUpgradeCreate
        }
        if CommandLine.arguments.contains(planUpgradeVerifyArgument) {
            return .planUpgradeVerify
        }
        if CommandLine.arguments.contains(dumpStateArgument) {
            return .dumpState
        }
        if CommandLine.arguments.contains(launchArgument) {
            return .fullIntegration
        }
        return nil
    }

    private enum Mode {
        case fullIntegration
        case planStory
        case planUpgradeCreate
        case planUpgradeVerify
        case dumpState
    }

    static func dumpState(progress: @escaping (String) -> Void) async -> IntegrationReport {
        var checks: [IntegrationCheck] = []
        let startedAt = Date()
        let cloud = CloudKitRepository()

        func note(_ name: String, _ detail: String, status: String = "pass") {
            checks.append(IntegrationCheck(name: name, status: status, detail: detail))
            progress("\(status.uppercased()) \(name): \(detail)")
        }

        do {
            let accountStatus = try await cloud.accountStatus()
            note("icloud-account", "status=\(accountStatus.rawValue)")
            guard accountStatus == .available else {
                return IntegrationReport(runId: "dump-\(Int(startedAt.timeIntervalSince1970))", startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }

            try await cloud.ensurePrivateZone()
            let snapshots = try await cloud.fetchAllGroupSnapshots()
            note("workspace-count", "\(snapshots.count)")

            for snapshot in snapshots {
                let reference = StoredGroupReference(
                    recordName: snapshot.group.recordID.recordName,
                    zoneName: snapshot.group.recordID.zoneID.zoneName,
                    ownerName: snapshot.group.recordID.zoneID.ownerName,
                    databaseScope: snapshot.databaseScope.rawValue
                )
                let scope = snapshot.databaseScope == .shared ? "shared" : "private"
                let workspaceName = snapshot.name.isEmpty ? "(personal)" : snapshot.name
                let medicationSummary = snapshot.medications
                    .map { "\($0.name)[\($0.id.uuidString)] sharedGroupId=\($0.sharedGroupId ?? "nil") owner=\($0.ownerUserRecordName ?? "nil")" }
                    .joined(separator: " | ")
                note(
                    "workspace-\(reference.recordName)",
                    "scope=\(scope) id=\(reference.id) name=\(workspaceName) members=\(snapshot.members.count) medications=\(snapshot.medications.count) confirmations=\(snapshot.confirmations.count) meds=\(medicationSummary)"
                )
            }

            return IntegrationReport(runId: "dump-\(Int(startedAt.timeIntervalSince1970))", startedAt: startedAt, finishedAt: Date(), success: true, checks: checks)
        } catch {
            note("dump-error", error.localizedDescription, status: "fail")
            return IntegrationReport(runId: "dump-\(Int(startedAt.timeIntervalSince1970))", startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
        }
    }

    static func run(progress: @escaping (String) -> Void) async -> IntegrationReport {
        var checks: [IntegrationCheck] = []
        let startedAt = Date()
        let runId = String(Int(startedAt.timeIntervalSince1970))
        let cloud = CloudKitRepository(zoneName: "PillCareIntegration-\(runId)")

        func pass(_ name: String, _ detail: String) {
            checks.append(IntegrationCheck(name: name, status: "pass", detail: detail))
            progress("PASS \(name): \(detail)")
        }

        func fail(_ name: String, _ detail: String) {
            checks.append(IntegrationCheck(name: name, status: "fail", detail: detail))
            progress("FAIL \(name): \(detail)")
        }

        do {
            progress("START CloudKit real diagnostics run \(runId)")

            let accountStatus = try await waitForAvailableAccount(cloud: cloud)
            guard accountStatus == .available else {
                fail("icloud-account", "Expected available iCloud account, got \(accountStatus.rawValue).")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            pass("icloud-account", "iCloud account is available.")

            try await cloud.ensurePrivateZone()
            pass("private-zone", "PillCareZone exists or was created in the real private database.")

            let personalSnapshot = try await cloud.ensurePersonalWorkspace()
            let personalReference = StoredGroupReference(
                recordName: personalSnapshot.group.recordID.recordName,
                zoneName: personalSnapshot.group.recordID.zoneID.zoneName,
                ownerName: personalSnapshot.group.recordID.zoneID.ownerName,
                databaseScope: personalSnapshot.databaseScope.rawValue
            )
            guard let loadedPersonal = try await waitForSnapshot(cloud: cloud, reference: personalReference, where: { cloud.isCanonicalPersonalWorkspace($0) }) else {
                fail("personal-workspace", "Could not fetch personal CloudKit workspace without members.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            guard loadedPersonal.name.isEmpty else {
                fail("personal-workspace-name", "Expected personal workspace to have no user-facing name.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            guard loadedPersonal.members.isEmpty else {
                fail("personal-workspace", "Expected personal workspace to have no members, got \(loadedPersonal.members.count).")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            pass("personal-workspace", "Created and fetched CloudKit workspace without members.")

            let personalMedication = makeMedication(runId: "Personal-\(runId)")
            try await cloud.saveMedication(personalMedication, groupRecord: personalSnapshot.group, database: personalSnapshot.database)
            guard let personalMedicationSnapshot = try await waitForSnapshot(cloud: cloud, reference: personalReference, where: { cloudSnapshot in
                cloudSnapshot.medications.contains(where: { $0.id == personalMedication.id })
            }) else {
                fail("personal-medication", "Could not fetch medication saved into personal CloudKit workspace.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            pass("personal-medication", "Fetched \(personalMedicationSnapshot.medications.count) medication(s) from personal workspace.")

            let storeADefaults = cleanDefaults(named: "PillCareIntegrationA-\(runId)")
            let storeBDefaults = cleanDefaults(named: "PillCareIntegrationB-\(runId)")
            let storeA = MedicationStore(cloud: cloud, defaults: storeADefaults)
            let storeB = MedicationStore(cloud: cloud, defaults: storeBDefaults)
            await storeA.reload()
            let sameAccountMedication = makeMedication(runId: "SameAccount-\(runId)")
            try await storeA.upsertMedication(sameAccountMedication)

            guard try await waitForStore(storeB, where: { store in
                store.medications.contains(where: { $0.id == sameAccountMedication.id })
            }) else {
                fail("same-account-medication-sync", "A second store with different local defaults did not fetch medication from the same private CloudKit workspace.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            pass("same-account-medication-sync", "Second store fetched medication through the same real private CloudKit workspace.")

            guard let sameAccountDose = ScheduleEngine.doses(on: sameAccountMedication.startDate, medications: [sameAccountMedication]).first else {
                fail("same-account-dose-selection", "No generated dose available for same-account confirmation.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            try await storeB.confirm(sameAccountDose, status: .confirmed, note: "Same-account integration confirmation")
            await storeA.reload()
            guard storeA.confirmations[sameAccountDose.id]?.status == .confirmed else {
                fail("same-account-confirmation-sync", "First store did not fetch confirmation saved by the second store.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            pass("same-account-confirmation-sync", "First store fetched confirmation saved by the second store.")

            guard let personalDose = ScheduleEngine.doses(on: personalMedication.startDate, medications: [personalMedication]).first else {
                fail("personal-dose-selection", "No generated dose available for personal confirmation.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }

            let personalConfirmation = DoseConfirmation(
                eventId: personalDose.id,
                medicationId: personalDose.medicationId,
                timeId: personalDose.timeId,
                scheduledDate: personalDose.scheduledDate,
                amount: personalDose.amount,
                status: .confirmed,
                memberId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                memberName: "",
                timestamp: Date(),
                note: "Personal integration confirmation"
            )
            try await cloud.saveConfirmation(personalConfirmation, groupRecord: personalSnapshot.group, database: personalSnapshot.database)
            guard let personalConfirmationSnapshot = try await waitForSnapshot(cloud: cloud, reference: personalReference, where: { cloudSnapshot in
                cloudSnapshot.confirmations.contains(where: { $0.eventId == personalConfirmation.eventId && $0.memberName.isEmpty })
            }) else {
                fail("personal-confirmation", "Could not fetch confirmation saved without a group member.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            pass("personal-confirmation", "Fetched \(personalConfirmationSnapshot.confirmations.count) personal confirmation(s).")

            try await cloud.deleteConfirmation(eventId: personalConfirmation.eventId, groupRecord: personalSnapshot.group, database: personalSnapshot.database)
            try await cloud.deleteMedication(personalMedication, groupRecord: personalSnapshot.group, database: personalSnapshot.database)
            try await cloud.deleteWorkspace(reference: personalReference)
            pass("personal-cleanup", "Deleted personal test workspace from CloudKit.")

            let legacySnapshot = try await cloud.createLegacyPersonalWorkspace(name: "Legacy \(runId)")
            let legacyReference = StoredGroupReference(
                recordName: legacySnapshot.group.recordID.recordName,
                zoneName: legacySnapshot.group.recordID.zoneID.zoneName,
                ownerName: legacySnapshot.group.recordID.zoneID.ownerName,
                databaseScope: legacySnapshot.databaseScope.rawValue
            )
            let legacyMedication = makeMedication(runId: "Legacy-\(runId)")
            try await cloud.saveMedication(legacyMedication, groupRecord: legacySnapshot.group, database: legacySnapshot.database)

            let legacyDefaults = cleanDefaults(named: "PillCareIntegrationLegacy-\(runId)")
            let legacyReferenceData = try JSONEncoder().encode(legacyReference)
            legacyDefaults.set(legacyReferenceData, forKey: MedicationStore.storedGroupReferenceKey)
            let legacyStore = MedicationStore(cloud: cloud, defaults: legacyDefaults)
            await legacyStore.reload()
            guard !legacyStore.medications.contains(where: { $0.id == legacyMedication.id }) else {
                fail("legacy-private-reference", "Store loaded medication from a legacy private workspace reference.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            let canonicalMedication = makeMedication(runId: "Canonical-\(runId)")
            try await legacyStore.upsertMedication(canonicalMedication)
            let canonicalSnapshotAfterLegacyReference = try await cloud.fetchGroupSnapshot(reference: personalReference)
            guard canonicalSnapshotAfterLegacyReference?.medications.contains(where: { $0.id == canonicalMedication.id }) == true else {
                fail("legacy-private-reference", "Store did not write to canonical workspace after ignoring legacy private reference.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            try await cloud.deleteMedication(canonicalMedication, groupRecord: personalSnapshot.group, database: personalSnapshot.database)
            try await cloud.deleteMedication(legacyMedication, groupRecord: legacySnapshot.group, database: legacySnapshot.database)
            try await cloud.deleteWorkspace(reference: legacyReference)
            try await cloud.deleteWorkspace(reference: personalReference)
            pass("legacy-private-reference", "Ignored legacy private workspace reference and kept writing to canonical workspace.")

            let groupName = "Integration \(runId)"
            let firstMemberName = "Tata \(runId)"
            let firstMember = CareMember(displayName: firstMemberName, colorHex: "#2F80ED", userRecordName: "debug-user-\(runId)")
            let snapshot = try await cloud.createGroup(name: groupName, firstMember: firstMember)
            guard snapshot.name == groupName, snapshot.members.contains(where: { $0.displayName == firstMemberName }) else {
                fail("create-group", "Created snapshot did not contain expected group/member.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            pass("create-group", "Created real CloudKit group \(snapshot.group.recordID.recordName).")

            let reference = StoredGroupReference(
                recordName: snapshot.group.recordID.recordName,
                zoneName: snapshot.group.recordID.zoneID.zoneName,
                ownerName: snapshot.group.recordID.zoneID.ownerName,
                databaseScope: snapshot.databaseScope.rawValue
            )

            guard let loadedGroup = try await waitForSnapshot(cloud: cloud, reference: reference, where: { $0.name == groupName }) else {
                fail("fetch-created-group", "Could not fetch the newly created group by exact record reference.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            pass("fetch-created-group", "Fetched group with \(loadedGroup.members.count) member(s).")

            let secondMember = CareMember(displayName: "Mama \(runId)", colorHex: "#27AE60")
            try await cloud.saveMember(secondMember, groupRecord: snapshot.group, database: snapshot.database)
            guard let membersSnapshot = try await waitForSnapshot(cloud: cloud, reference: reference, where: { cloudSnapshot in
                cloudSnapshot.members.contains(where: { $0.id == secondMember.id && $0.displayName == secondMember.displayName })
            }) else {
                fail("add-member", "Could not fetch added member from CloudKit.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            pass("add-member", "Fetched \(membersSnapshot.members.count) member(s), including \(secondMember.displayName).")

            let medication = makeMedication(runId: runId)
            try await cloud.saveMedication(medication, groupRecord: snapshot.group, database: snapshot.database)
            guard let medicationSnapshot = try await waitForSnapshot(cloud: cloud, reference: reference, where: { cloudSnapshot in
                cloudSnapshot.medications.contains(where: { $0.id == medication.id })
            }) else {
                fail("save-medication", "Could not fetch saved medication from CloudKit.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            pass("save-medication", "Fetched \(medicationSnapshot.medications.count) medication(s).")

            let todayDoses = ScheduleEngine.doses(on: medication.startDate, medications: [medication])
            guard todayDoses.count == 2,
                  todayDoses.contains(where: { $0.scheduledTime.hour == 7 && $0.amount == "¼" }),
                  todayDoses.contains(where: { $0.scheduledTime.hour == 19 && $0.amount == "¼" }) else {
                fail("schedule-phase-1", "Expected ¼ - 0 - ¼ on day 1, got \(todayDoses.map(\.amount).joined(separator: ", ")).")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            pass("schedule-phase-1", "Generated day 1 doses ¼ - 0 - ¼.")

            let dayFour = Calendar.current.date(byAdding: .day, value: 3, to: medication.startDate) ?? medication.startDate
            let dayFourDoses = ScheduleEngine.doses(on: dayFour, medications: [medication])
            guard dayFourDoses.contains(where: { $0.scheduledTime.hour == 7 && $0.amount == "¼" }),
                  dayFourDoses.contains(where: { $0.scheduledTime.hour == 19 && $0.amount == "½" }) else {
                fail("schedule-phase-2", "Expected ¼ - 0 - ½ after phase change, got \(dayFourDoses.map(\.amount).joined(separator: ", ")).")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            pass("schedule-phase-2", "Generated phase change doses ¼ - 0 - ½.")

            guard let dose = todayDoses.first else {
                fail("dose-selection", "No generated dose available for confirmation.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }

            let confirmation = DoseConfirmation(
                eventId: dose.id,
                medicationId: dose.medicationId,
                timeId: dose.timeId,
                scheduledDate: dose.scheduledDate,
                amount: dose.amount,
                status: .confirmed,
                memberId: secondMember.id,
                memberName: secondMember.displayName,
                timestamp: Date(),
                note: "Integration confirmation"
            )
            try await cloud.saveConfirmation(confirmation, groupRecord: snapshot.group, database: snapshot.database)
            guard let confirmationSnapshot = try await waitForSnapshot(cloud: cloud, reference: reference, where: { cloudSnapshot in
                cloudSnapshot.confirmations.contains(where: { $0.eventId == confirmation.eventId && $0.status == .confirmed })
            }) else {
                fail("save-confirmation", "Could not fetch saved dose confirmation from CloudKit.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            pass("save-confirmation", "Fetched \(confirmationSnapshot.confirmations.count) confirmation(s).")

            let preparedShare = try await cloud.prepareShare(groupRecord: snapshot.group, database: snapshot.database, title: groupName)
            let share = preparedShare.share
            guard share.recordID.zoneID == snapshot.group.recordID.zoneID else {
                fail("prepare-share", "Share was created in an unexpected CloudKit zone.")
                return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
            }
            pass("prepare-share", "Prepared real CKShare \(share.recordID.recordName). Accepting it still requires a second iCloud account/device.")

            try await cloud.deleteConfirmation(eventId: confirmation.eventId, groupRecord: snapshot.group, database: snapshot.database)
            pass("delete-confirmation", "Deleted the test confirmation from CloudKit.")

            try await cloud.deleteMedication(medication, groupRecord: snapshot.group, database: snapshot.database)
            pass("delete-medication", "Deleted the test medication from CloudKit.")

            try await cloud.deleteMember(secondMember, groupRecord: snapshot.group, database: snapshot.database)
            pass("delete-member", "Deleted the second test member from CloudKit.")

            try await cloud.deleteWorkspace(reference: reference)
            pass("delete-workspace", "Deleted the test group workspace from CloudKit.")

            return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: true, checks: checks)
        } catch {
            fail("unexpected-error", String(describing: error))
            return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
        }
    }

    static func runPlanStory(progress: @escaping (String) -> Void) async -> IntegrationReport {
        var checks: [IntegrationCheck] = []
        let startedAt = Date()
        let runId = String(Int(startedAt.timeIntervalSince1970))
        let cloud = CloudKitRepository(zoneName: "PillCarePlanStory-\(runId)")

        func pass(_ name: String, _ detail: String) {
            checks.append(IntegrationCheck(name: name, status: "pass", detail: detail))
            progress("PASS \(name): \(detail)")
        }

        func fail(_ name: String, _ detail: String) -> IntegrationReport {
            checks.append(IntegrationCheck(name: name, status: "fail", detail: detail))
            progress("FAIL \(name): \(detail)")
            return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
        }

        do {
            progress("START plan persistence story \(runId)")

            let accountStatus = try await waitForAvailableAccount(cloud: cloud)
            guard accountStatus == .available else {
                return fail("icloud-account", "Expected available iCloud account, got \(accountStatus.rawValue).")
            }
            pass("icloud-account", "iCloud account is available.")

            try await cleanCanonicalWorkspace(cloud: cloud)
            let defaultsA = cleanDefaults(named: "PillCarePlanStoryA-\(runId)")
            let storeA = MedicationStore(cloud: cloud, defaults: defaultsA)
            await storeA.reload()
            guard storeA.hasCloudWorkspace else {
                return fail("fresh-start", "Store A did not prepare a CloudKit workspace.")
            }
            pass("fresh-start", "Store A prepared canonical personal workspace.")

            let medication = makeMedication(runId: "PlanStory-\(runId)")
            try await storeA.upsertMedication(medication)
            guard storeA.medications.contains(where: { $0.id == medication.id }) else {
                return fail("save-visible-immediate", "Saved medication was not visible in Store A immediately after upsert.")
            }
            pass("save-visible-immediate", "Saved medication is visible immediately after upsert.")

            try await Task.sleep(for: .seconds(2))
            guard storeA.medications.contains(where: { $0.id == medication.id }) else {
                return fail("save-visible-after-sync", "Saved medication disappeared from Store A after the follow-up sync window.")
            }
            pass("save-visible-after-sync", "Saved medication stayed visible after follow-up sync window.")

            let defaultsB = cleanDefaults(named: "PillCarePlanStoryB-\(runId)")
            let storeB = MedicationStore(cloud: cloud, defaults: defaultsB)
            guard try await waitForStore(storeB, where: { store in
                store.medications.contains(where: { $0.id == medication.id })
            }) else {
                return fail("restart-loads-saved-plan", "A fresh Store B did not load the medication saved by Store A from real CloudKit.")
            }
            pass("restart-loads-saved-plan", "Fresh Store B loaded the saved medication from real CloudKit.")

            try await cleanCanonicalWorkspace(cloud: cloud)
            pass("cleanup", "Deleted plan story test workspace from CloudKit.")
            return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: true, checks: checks)
        } catch {
            return fail("unexpected-error", String(describing: error))
        }
    }

    static func runPlanUpgradeCreate(progress: @escaping (String) -> Void) async -> IntegrationReport {
        var checks: [IntegrationCheck] = []
        let startedAt = Date()
        let runId = "plan-upgrade"
        let cloud = CloudKitRepository(zoneName: "PillCarePlanUpgrade")

        func pass(_ name: String, _ detail: String) {
            checks.append(IntegrationCheck(name: name, status: "pass", detail: detail))
            progress("PASS \(name): \(detail)")
        }

        func fail(_ name: String, _ detail: String) -> IntegrationReport {
            checks.append(IntegrationCheck(name: name, status: "fail", detail: detail))
            progress("FAIL \(name): \(detail)")
            return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
        }

        do {
            progress("START plan upgrade create")

            let accountStatus = try await waitForAvailableAccount(cloud: cloud)
            guard accountStatus == .available else {
                return fail("icloud-account", "Expected available iCloud account, got \(accountStatus.rawValue).")
            }
            pass("icloud-account", "iCloud account is available.")

            try await cleanCanonicalWorkspace(cloud: cloud)
            let defaults = cleanDefaults(named: "PillCarePlanUpgradeCreate")
            let store = MedicationStore(cloud: cloud, defaults: defaults)
            await store.reload()

            let medication = makeUpgradeMedication()
            try await store.upsertMedication(medication)
            guard store.medications.contains(where: { $0.id == medication.id }) else {
                return fail("create-visible-immediate", "Upgrade test medication was not visible immediately after save.")
            }
            try await Task.sleep(for: .seconds(2))
            guard store.medications.contains(where: { $0.id == medication.id }) else {
                return fail("create-visible-after-sync", "Upgrade test medication disappeared after follow-up sync window.")
            }
            pass("create-plan", "Created upgrade test medication in real CloudKit.")

            guard try await waitForStore(MedicationStore(cloud: cloud, defaults: cleanDefaults(named: "PillCarePlanUpgradeCreateReload")), where: { store in
                store.medications.contains(where: { $0.id == medication.id })
            }) else {
                return fail("create-reload", "A fresh store in the create build could not reload the upgrade test medication.")
            }
            pass("create-reload", "Create build can reload the upgrade test medication.")

            return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: true, checks: checks)
        } catch {
            return fail("unexpected-error", String(describing: error))
        }
    }

    static func runPlanUpgradeVerify(progress: @escaping (String) -> Void) async -> IntegrationReport {
        var checks: [IntegrationCheck] = []
        let startedAt = Date()
        let runId = "plan-upgrade"
        let cloud = CloudKitRepository(zoneName: "PillCarePlanUpgrade")

        func pass(_ name: String, _ detail: String) {
            checks.append(IntegrationCheck(name: name, status: "pass", detail: detail))
            progress("PASS \(name): \(detail)")
        }

        func fail(_ name: String, _ detail: String) -> IntegrationReport {
            checks.append(IntegrationCheck(name: name, status: "fail", detail: detail))
            progress("FAIL \(name): \(detail)")
            return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: false, checks: checks)
        }

        do {
            progress("START plan upgrade verify")

            let accountStatus = try await waitForAvailableAccount(cloud: cloud)
            guard accountStatus == .available else {
                return fail("icloud-account", "Expected available iCloud account, got \(accountStatus.rawValue).")
            }
            pass("icloud-account", "iCloud account is available.")

            let medication = makeUpgradeMedication()
            let defaults = cleanDefaults(named: "PillCarePlanUpgradeVerify")
            let store = MedicationStore(cloud: cloud, defaults: defaults)
            guard try await waitForStore(store, where: { store in
                store.medications.contains(where: { $0.id == medication.id })
            }) else {
                return fail("newer-build-loads-plan", "The newer build did not load the medication created by the previous build.")
            }
            pass("newer-build-loads-plan", "The newer build loaded the medication created by the previous build.")

            try await cleanCanonicalWorkspace(cloud: cloud)
            pass("cleanup", "Deleted upgrade test workspace from CloudKit.")
            return IntegrationReport(runId: runId, startedAt: startedAt, finishedAt: Date(), success: true, checks: checks)
        } catch {
            return fail("unexpected-error", String(describing: error))
        }
    }

    private static func waitForSnapshot(
        cloud: CloudKitRepository,
        reference: StoredGroupReference,
        where predicate: (CloudSnapshot) -> Bool
    ) async throws -> CloudSnapshot? {
        for attempt in 0..<6 {
            if let snapshot = try await cloud.fetchGroupSnapshot(reference: reference), predicate(snapshot) {
                return snapshot
            }
            if attempt < 5 {
                try await Task.sleep(for: .milliseconds(700))
            }
        }
        return nil
    }

    private static func waitForStore(
        _ store: MedicationStore,
        where predicate: (MedicationStore) -> Bool
    ) async throws -> Bool {
        for attempt in 0..<6 {
            await store.reload()
            if predicate(store) {
                return true
            }
            if attempt < 5 {
                try await Task.sleep(for: .milliseconds(700))
            }
        }
        return false
    }

    private static func waitForAvailableAccount(cloud: CloudKitRepository) async throws -> CKAccountStatus {
        var lastStatus = try await cloud.accountStatus()
        for attempt in 0..<8 {
            if lastStatus == .available {
                return lastStatus
            }
            if attempt < 7 {
                try await Task.sleep(for: .seconds(2))
                lastStatus = try await cloud.accountStatus()
            }
        }
        return lastStatus
    }

    private static func cleanDefaults(named name: String) -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: name) else {
            return .standard
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func cleanCanonicalWorkspace(cloud: CloudKitRepository) async throws {
        let snapshots = try await cloud.fetchAllGroupSnapshots()
        for snapshot in snapshots where cloud.isCanonicalPersonalWorkspace(snapshot) {
            for confirmation in snapshot.confirmations {
                try await cloud.deleteConfirmation(eventId: confirmation.eventId, groupRecord: snapshot.group, database: snapshot.database)
            }
            for medication in snapshot.medications {
                try await cloud.deleteMedication(medication, groupRecord: snapshot.group, database: snapshot.database)
            }
            try await cloud.deleteWorkspace(reference: reference(from: snapshot))
        }
    }

    private static func reference(from snapshot: CloudSnapshot) -> StoredGroupReference {
        StoredGroupReference(
            recordName: snapshot.group.recordID.recordName,
            zoneName: snapshot.group.recordID.zoneID.zoneName,
            ownerName: snapshot.group.recordID.zoneID.ownerName,
            databaseScope: snapshot.databaseScope.rawValue
        )
    }

    private static func makeMedication(runId: String) -> Medication {
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: Date())
        let morning = DoseTime(label: "Ráno", time: TimeOfDay(hour: 7, minute: 0))
        let noon = DoseTime(label: "Poledne", time: TimeOfDay(hour: 12, minute: 0))
        let evening = DoseTime(label: "Večer", time: TimeOfDay(hour: 19, minute: 0))

        return Medication(
            name: "Lek Integration \(runId)",
            note: "Real CloudKit integration test",
            colorHex: "#2F80ED",
            startDate: startDate,
            doseTimes: [morning, noon, evening],
            phases: [
                PlanPhase(
                    title: "Prvni 3 dny",
                    durationDays: 3,
                    doses: [
                        DoseEntry(timeId: morning.id, amount: "1/4"),
                        DoseEntry(timeId: noon.id, amount: "0"),
                        DoseEntry(timeId: evening.id, amount: "1/4")
                    ]
                ),
                PlanPhase(
                    title: "Dalsich 5 dni",
                    durationDays: 5,
                    doses: [
                        DoseEntry(timeId: morning.id, amount: "1/4"),
                        DoseEntry(timeId: noon.id, amount: "0"),
                        DoseEntry(timeId: evening.id, amount: "1/2")
                    ]
                ),
                PlanPhase(
                    title: "Udrzovaci",
                    durationDays: nil,
                    doses: [
                        DoseEntry(timeId: morning.id, amount: "1/2"),
                        DoseEntry(timeId: noon.id, amount: "0"),
                        DoseEntry(timeId: evening.id, amount: "1/2")
                    ]
                )
            ]
        )
    }

    private static func makeUpgradeMedication() -> Medication {
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: Date())
        let morningId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let eveningId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let morning = DoseTime(id: morningId, label: "Ráno", time: TimeOfDay(hour: 7, minute: 0))
        let evening = DoseTime(id: eveningId, label: "Večer", time: TimeOfDay(hour: 19, minute: 0))

        return Medication(
            id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            name: "Upgrade persistence plan",
            note: "Created by previous debug build",
            colorHex: "#2F80ED",
            startDate: startDate,
            doseTimes: [morning, evening],
            phases: [
                PlanPhase(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    title: "Upgrade test phase",
                    durationDays: nil,
                    doses: [
                        DoseEntry(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, timeId: morningId, amount: "1/4"),
                        DoseEntry(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!, timeId: eveningId, amount: "1/4")
                    ]
                )
            ]
        )
    }

    static func write(report: IntegrationReport) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = directory.appendingPathComponent("cloudkit-integration-report.json")
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to write CloudKit integration report: \(error)")
        }
    }
}

struct IntegrationReport: Codable {
    var runId: String
    var startedAt: Date
    var finishedAt: Date
    var success: Bool
    var checks: [IntegrationCheck]
}

struct IntegrationCheck: Codable {
    var name: String
    var status: String
    var detail: String
}

#endif
