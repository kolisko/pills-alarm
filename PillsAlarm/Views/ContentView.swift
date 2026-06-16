import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: MedicationStore

    var body: some View {
        appTabs
            .overlay(alignment: .top) {
                SyncOverlay()
                    .environmentObject(store)
            }
            .sheet(isPresented: workspaceSelectionBinding) {
                WorkspaceSelectionView()
                    .environmentObject(store)
                    .interactiveDismissDisabled(true)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }

    private var workspaceSelectionBinding: Binding<Bool> {
        Binding {
            !store.workspaceCandidates.isEmpty
        } set: { _ in }
    }

    private var appTabs: some View {
        TabView {
            TodayView()
                .tabItem {
                    Label("Dnes", systemImage: "checklist")
                }

            PlanView()
                .tabItem {
                    Label("Plán", systemImage: "calendar.badge.clock")
                }

            GroupView()
                .tabItem {
                    Label("Skupina", systemImage: "person.3")
                }

            HistoryView()
                .tabItem {
                    Label("Historie", systemImage: "clock.arrow.circlepath")
                }

            SettingsView()
                .tabItem {
                    Label("Nastavení", systemImage: "gearshape")
                }
        }
        .tint(.teal)
        .onChange(of: store.medications) {
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: store)
        }
        .onChange(of: store.confirmations) {
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: store)
        }
    }
}

private struct SyncOverlay: View {
    @EnvironmentObject private var store: MedicationStore

    var body: some View {
        VStack(spacing: 8) {
            if store.isSyncing {
                SyncLine()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if let message = store.syncErrorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        store.dismissSyncError()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.18), value: store.isSyncing)
        .animation(.easeInOut(duration: 0.18), value: store.syncErrorMessage)
    }
}

private struct SyncLine: View {
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.teal.opacity(0.12))
                Rectangle()
                    .fill(.teal.opacity(0.65))
                    .frame(width: max(80, proxy.size.width * 0.28))
                    .offset(x: isAnimating ? proxy.size.width : -max(80, proxy.size.width * 0.28))
            }
            .onAppear {
                isAnimating = true
            }
            .animation(.linear(duration: 1.15).repeatForever(autoreverses: false), value: isAnimating)
        }
        .frame(height: 2)
    }
}

private struct WorkspaceSelectionView: View {
    @EnvironmentObject private var store: MedicationStore
    @State private var pendingDelete: WorkspaceCandidate?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Aplikace našla více možných úložišť v iCloudu. Vyber to správné, aby se znovu zobrazil tvůj plán.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Nalezená úložiště") {
                    ForEach(store.workspaceCandidates) { candidate in
                        Button {
                            Task { await store.selectWorkspace(candidate) }
                        } label: {
                            WorkspaceCandidateRow(candidate: candidate)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        guard let index = offsets.first else { return }
                        let candidate = store.workspaceCandidates[index]
                        guard !candidate.isActive else { return }
                        pendingDelete = candidate
                    }
                }
            }
            .navigationTitle("Vyber úložiště")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                pendingDelete?.canDeleteFromCloud == true ? "Smazat úložiště?" : "Odebrat ze seznamu?",
                isPresented: Binding {
                    pendingDelete != nil
                } set: { isPresented in
                    if !isPresented {
                        pendingDelete = nil
                    }
                },
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { candidate in
                Button(candidate.canDeleteFromCloud ? "Smazat úložiště" : "Odebrat ze seznamu", role: .destructive) {
                    Task {
                        await store.deleteWorkspaceCandidate(candidate)
                        pendingDelete = nil
                    }
                }
                Button("Zrušit", role: .cancel) {
                    pendingDelete = nil
                }
            } message: { candidate in
                Text("\(candidate.name): \(candidate.medicationCount) léků, \(candidate.memberCount) členů, \(candidate.confirmationCount) záznamů historie.")
            }
        }
    }
}

private struct WorkspaceCandidateRow: View {
    var candidate: WorkspaceCandidate

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: candidate.typeLabel == "Sdílené" ? "person.2.fill" : "externaldrive.fill")
                .foregroundStyle(.teal)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(candidate.name)
                        .font(.headline)
                    if candidate.isActive {
                        StatusBadge(text: "aktivní", systemImage: "checkmark.circle.fill", tint: .teal)
                    }
                }

                Text("\(candidate.medicationCount) léků · \(candidate.memberCount) členů · \(candidate.confirmationCount) záznamů historie")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(candidate.typeLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct ICloudAccountRequiredView: View {
    @EnvironmentObject private var store: MedicationStore
    var message: String

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 28) {
                Spacer(minLength: 36)

                Image(systemName: "icloud.slash")
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundStyle(.teal)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Přihlášení k iCloudu")
                        .font(.largeTitle.bold())
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Label("Otevři Nastavení", systemImage: "gear")
                    Label("Přihlas se k Apple účtu a zapni iCloud", systemImage: "person.crop.circle.badge.checkmark")
                    Label("Vrať se sem a zkus ověření znovu", systemImage: "arrow.clockwise")
                }
                .font(.headline)

                Button {
                    Task { await store.reload() }
                } label: {
                    Label("Zkusit znovu", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.teal)

                Spacer()
            }
            .padding(28)
            .navigationTitle("iCloud")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
