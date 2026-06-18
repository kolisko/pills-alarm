import SwiftUI

struct GroupView: View {
    @EnvironmentObject private var store: MedicationStore
    @State private var groupName = ""
    @State private var firstMemberName = ""
    @State private var renamedGroupName = ""
    @State private var myMemberName = ""
    @State private var sharedMemberNames: [String: String] = [:]
    @State private var sharingController: CloudSharingController?
#if DEBUG && targetEnvironment(simulator)
    @StateObject private var diagnostics = CloudKitDiagnosticsModel()
#endif

    var body: some View {
        NavigationStack {
            AppScreen(title: "Skupina") {
                Form {
                    switch store.loadState {
                    case .loading, .idle:
                        EmptyView()

                    case .failed:
                        EmptyView()

                    case .requiresICloudAccount(let message):
                        Section {
                            Label(message, systemImage: "icloud.slash")
                                .foregroundStyle(.secondary)
                            Button("Zkusit znovu") {
                                Task { await store.reload() }
                            }
                        }

                    case .missingGroup:
                        createGroupSection

                    case .ready:
                        if store.hasGroup || !store.sharedWorkspaceProfiles.isEmpty {
                            realGroupSections
                        } else {
                            createGroupSection
                        }
                    }

                    diagnosticsSection
                }
                .refreshable {
                    await store.reload(showSyncIndicator: false)
                }
            }
            .sheet(item: $sharingController) { controller in
                CloudSharingView(controller: controller)
            }
            .task {
                if renamedGroupName.isEmpty {
                    renamedGroupName = store.careGroupName
                }
                if myMemberName.isEmpty {
                    myMemberName = store.currentMemberName
                }
            }
            .onChange(of: store.careGroupName) { _, newValue in
                if renamedGroupName.isEmpty || renamedGroupName != newValue {
                    renamedGroupName = newValue
                }
            }
            .onChange(of: store.currentMemberName) { _, newValue in
                if myMemberName != newValue {
                    myMemberName = newValue
                }
            }
            .onChange(of: store.sharedWorkspaceProfiles) { _, profiles in
                for profile in profiles where sharedMemberNames[profile.id] == nil {
                    sharedMemberNames[profile.id] = profile.currentMemberName
                }
            }
        }
    }

    private var createGroupSection: some View {
        Section("Sdílení") {
            TextField("Název skupiny", text: $groupName)
            TextField("Moje jméno v péči", text: $firstMemberName)
            Button {
                Task {
                    await store.createGroup(name: groupName, firstMemberName: firstMemberName)
                    renamedGroupName = groupName
                }
            } label: {
                Label("Zapnout sdílení", systemImage: "person.3.fill")
            }
            .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || firstMemberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var realGroupSections: some View {
        if store.hasGroup {
            Section {
                TextField("Název skupiny", text: $renamedGroupName)

                TextField("Moje jméno", text: $myMemberName)
                    .textInputAutocapitalization(.words)

                HStack {
                    Spacer()
                    Button("Uložit") {
                        Task {
                            await store.saveGroupSettings(name: renamedGroupName, myName: myMemberName)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSaveGroupSettings || store.isSyncing)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } header: {
                Text("Skupina")
            } footer: {
                if store.currentMemberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Vyplň svoje jméno, aby bylo jasné, kdo potvrdil dávku.")
                }
            }
        } else {
            createGroupSection
        }

        if store.hasGroup {
            Section("Ostatní členové") {
                if otherMembers.isEmpty {
                    Text("Zatím žádní další členové")
                        .foregroundStyle(.secondary)
                }

                ForEach(otherMembers) { member in
                    MemberRow(member: member)
                }

                Button {
                    Task {
                        if let controller = await store.prepareSharingController() {
                            sharingController = controller
                        }
                    }
                } label: {
                    Label("Pozvat přes iCloud", systemImage: "person.badge.plus")
                }
                .disabled(store.isSyncing)
            }

            Section("Plány ve skupině") {
                if store.sharedOwnPlanItems.isEmpty {
                    Text("Zatím tu nejsou žádné tvoje sdílené plány")
                        .foregroundStyle(.secondary)
                }

                ForEach(store.sharedOwnPlanItems) { item in
                    PlanSharingRow(item: item, actionTitle: "Odebrat") {
                        Task {
                            try? await store.setMedication(item, sharedWithOwnedGroup: false)
                        }
                    }
                }
            }

            Section("Přidat plán do skupiny") {
                if store.privateOwnPlanItems.isEmpty {
                    Text("Nemáš žádné soukromé plány k přidání")
                        .foregroundStyle(.secondary)
                }

                ForEach(store.privateOwnPlanItems) { item in
                    PlanSharingRow(item: item, actionTitle: "Přidat") {
                        Task {
                            try? await store.setMedication(item, sharedWithOwnedGroup: true)
                        }
                    }
                }
            }
        }

        ForEach(store.sharedWorkspaceProfiles) { profile in
            Section {
                if !profile.name.isEmpty {
                    Text(profile.name)
                        .foregroundStyle(.secondary)
                }

                TextField(
                    "Moje jméno",
                    text: Binding(
                        get: { sharedMemberNames[profile.id] ?? profile.currentMemberName },
                        set: { sharedMemberNames[profile.id] = $0 }
                    )
                )
                .textInputAutocapitalization(.words)

                HStack {
                    Spacer()
                    Button("Uložit") {
                        Task {
                            await store.saveSharedWorkspaceProfile(
                                workspaceId: profile.id,
                                myName: sharedMemberNames[profile.id] ?? profile.currentMemberName
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((sharedMemberNames[profile.id] ?? profile.currentMemberName).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSyncing)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } header: {
                Label("Sdílená skupina", systemImage: "person.2.fill")
            } footer: {
                if profile.currentMemberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Vyplň svoje jméno, aby bylo jasné, kdo potvrdil dávku ve sdílené skupině.")
                }
            }

            if !profile.otherMembers.isEmpty {
                Section("Ostatní členové ve sdílení") {
                    ForEach(profile.otherMembers) { member in
                        MemberRow(member: member)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    Task {
                        await store.removeSharedWorkspace(workspaceId: profile.id)
                    }
                } label: {
                    Label("Odebrat skupinu z aplikace", systemImage: "person.2.slash")
                }
                .disabled(store.isSyncing)
            }
        }
    }

    private var canSaveGroupSettings: Bool {
        !renamedGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !myMemberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var otherMembers: [CareMember] {
        let currentMemberId = store.activeMember?.id
        return store.members.filter { $0.id != currentMemberId }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
#if DEBUG
#if targetEnvironment(simulator)
        Section("Debug CloudKit") {
            Button {
                Task {
                    await diagnostics.run()
                    await store.reload()
                }
            } label: {
                Label("Spustit reálný CloudKit test", systemImage: "stethoscope")
            }
            .disabled(diagnostics.isRunning)

            if diagnostics.isRunning {
                ProgressView("Běží reálný iCloud test...")
            }

            if let report = diagnostics.lastReport {
                StatusBadge(
                    text: report.success ? "test prošel" : "test selhal",
                    systemImage: report.success ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    tint: report.success ? .green : .red
                )
            }

            if !diagnostics.lines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(diagnostics.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.hasPrefix("FAIL") ? .red : .secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
        }
#else
        EmptyView()
#endif
#else
        EmptyView()
#endif
    }
}

private struct MemberRow: View {
    var member: CareMember

    var body: some View {
        HStack {
            Circle()
                .fill(Color(hex: member.colorHex))
                .frame(width: 12, height: 12)
            Text(member.displayName)
            Spacer()
        }
    }
}

private struct PlanSharingRow: View {
    var item: MedicationListItem
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.medication.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(item.medication.phases.count) fáze")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
