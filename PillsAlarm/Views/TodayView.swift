import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: MedicationStore
    @State private var selectedDate = Date()

    private var doses: [GeneratedDose] {
        store.doses(on: selectedDate)
    }

    private var isShowingToday: Bool {
        selectedDate.isSameDay(as: Date())
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("Den", selection: $selectedDate, displayedComponents: .date)

                    if store.hasGroup {
                        Picker("Potvrzuje", selection: activeMemberBinding) {
                            ForEach(store.members) { member in
                                Text(member.displayName).tag(Optional(member.id))
                            }
                        }
                    }
                }

                if !isShowingToday {
                    Section {
                        HStack(spacing: 12) {
                            Label(selectedDate.relativeDayLabel(), systemImage: "calendar")
                                .font(.headline)
                            Spacer()
                            Button {
                                selectedDate = Date()
                            } label: {
                                Label("Dnes", systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } footer: {
                        Text("Zobrazuješ jiné datum.")
                    }
                }

                if doses.isEmpty {
                    EmptyStateView(title: "Na tento den nejsou naplánované dávky", systemImage: "pills")
                        .listRowBackground(Color.clear)
                } else {
                    Section(selectedDate.relativeDayLabel()) {
                        ForEach(doses) { dose in
                            DoseRow(dose: dose)
                        }
                    }
                }
            }
            .navigationTitle(selectedDate.relativeDayLabel())
            .refreshable {
                await store.reload(showSyncIndicator: false)
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
}

private struct DoseRow: View {
    @EnvironmentObject private var store: MedicationStore
    @State private var showsSkipConfirmation = false
    var dose: GeneratedDose

    private var confirmation: DoseConfirmation? {
        store.confirmation(for: dose)
    }

    private var isOverdueToday: Bool {
        confirmation == nil
            && Calendar.current.isDateInToday(dose.scheduledDate)
            && dose.scheduledDate < Date()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isOverdueToday {
                StatusBadge(
                    text: "Je čas vzít dávku",
                    systemImage: "exclamationmark.circle.fill",
                    tint: .orange
                )
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dose.timeLabel)
                        .font(.headline)
                    Text(dose.scheduledTime.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 72, alignment: .leading)

                VStack(alignment: .leading, spacing: 5) {
                    Text(dose.medicationName)
                        .font(.headline)
                    Text("Dávka \(dose.amount) · \(dose.phaseTitle)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !dose.medicationNote.isEmpty {
                        Text(dose.medicationNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            if let confirmation {
                HStack {
                    let statusText = store.hasGroup
                        ? (confirmation.status == .confirmed ? "Podáno: \(confirmation.memberName)" : "Přeskočil/a: \(confirmation.memberName)")
                        : confirmation.status.label
                    StatusBadge(
                        text: statusText,
                        systemImage: confirmation.status == .confirmed ? "checkmark.circle.fill" : "forward.circle.fill",
                        tint: confirmation.status == .confirmed ? .green : .orange
                    )
                    Text(confirmation.timestamp.shortTimeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Zpět") {
                        Task {
                            try? await store.undoConfirmation(for: dose)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(store.isSyncing)
                }
            } else {
                HStack {
                    Button {
                        Task {
                            try? await store.confirm(dose, status: .confirmed)
                        }
                    } label: {
                        Label("Podáno", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((store.hasGroup && store.activeMember == nil) || store.isSyncing)

                    Button {
                        showsSkipConfirmation = true
                    } label: {
                        Label("Přeskočit", systemImage: "forward.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled((store.hasGroup && store.activeMember == nil) || store.isSyncing)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, isOverdueToday ? 10 : 0)
        .background {
            if isOverdueToday {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.12))
            }
        }
        .confirmationDialog(
            "Opravdu přeskočit dávku?",
            isPresented: $showsSkipConfirmation,
            titleVisibility: .visible
        ) {
            Button("Přeskočit dávku", role: .destructive) {
                Task {
                    try? await store.confirm(dose, status: .skipped)
                }
            }
            Button("Zrušit", role: .cancel) {}
        }
    }
}
