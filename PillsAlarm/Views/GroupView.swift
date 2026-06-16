import SwiftUI

struct GroupView: View {
    @EnvironmentObject private var store: MedicationStore
    @State private var groupName = ""
    @State private var firstMemberName = ""
    @State private var renamedGroupName = ""
    @State private var newMemberName = ""
    @State private var sharingController: CloudSharingController?
#if DEBUG && targetEnvironment(simulator)
    @StateObject private var diagnostics = CloudKitDiagnosticsModel()
#endif

    var body: some View {
        NavigationStack {
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
                    if store.hasGroup {
                        realGroupSections
                    } else {
                        createGroupSection
                    }
                }

                diagnosticsSection
            }
            .navigationTitle("Skupina")
            .refreshable {
                await store.reload(showSyncIndicator: false)
            }
            .sheet(item: $sharingController) { controller in
                CloudSharingView(controller: controller)
            }
            .task {
                if renamedGroupName.isEmpty {
                    renamedGroupName = store.careGroupName
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
        Section("Skupina") {
            TextField("Název skupiny", text: $renamedGroupName)
                .onSubmit {
                    Task { await store.setGroupName(renamedGroupName) }
                }

            Picker("Moje jméno", selection: activeMemberBinding) {
                ForEach(store.members) { member in
                    Text(member.displayName).tag(Optional(member.id))
                }
            }

            Button {
                if let controller = store.makeSharingController() {
                    sharingController = controller
                }
            } label: {
                Label("Pozvat přes iCloud", systemImage: "person.badge.plus")
            }
        }

        Section("Členové") {
            ForEach(store.members) { member in
                MemberRow(member: member)
            }
            .onDelete { offsets in
                for index in offsets {
                    store.deleteMember(store.members[index])
                }
            }

            HStack {
                TextField("mama, tata, babicka...", text: $newMemberName)
                Button {
                    store.addMember(named: newMemberName)
                    newMemberName = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newMemberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var activeMemberBinding: Binding<UUID?> {
        Binding {
            store.activeMemberId
        } set: { value in
            store.activeMemberId = value
        }
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
    @EnvironmentObject private var store: MedicationStore
    @State private var member: CareMember

    init(member: CareMember) {
        _member = State(initialValue: member)
    }

    var body: some View {
        HStack {
            Circle()
                .fill(Color(hex: member.colorHex))
                .frame(width: 12, height: 12)
            TextField("Jméno", text: $member.displayName)
                .onSubmit {
                    store.updateMember(member)
                }
            Spacer()
            if store.activeMemberId == member.id {
                StatusBadge(text: "já", systemImage: "person.fill", tint: .teal)
            }
        }
    }
}
