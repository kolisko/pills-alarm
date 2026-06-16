import SwiftUI

struct PlanView: View {
    @EnvironmentObject private var store: MedicationStore
    @State private var newMedication: Medication?

    var body: some View {
        NavigationStack {
            List {
                syncStatusSection

                if store.medications.isEmpty {
                    EmptyStateView(title: "Zatím není vytvořený žádný plán", systemImage: "calendar.badge.plus")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(store.medications) { medication in
                        NavigationLink {
                            MedicationEditorView(original: medication)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(medication.name)
                                    .font(.headline)
                                Text("\(medication.phases.count) fáze · start \(medication.startDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            store.deleteMedication(store.medications[index])
                        }
                    }
                }
            }
            .navigationTitle("Plán")
            .refreshable {
                await store.reload(showSyncIndicator: false)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newMedication = store.addMedication()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!store.hasCloudWorkspace)
                }
            }
            .sheet(item: $newMedication) { medication in
                NavigationStack {
                    MedicationEditorView(original: medication)
                }
            }
        }
    }

    @ViewBuilder
    private var syncStatusSection: some View {
        switch store.loadState {
        case .idle, .loading:
            EmptyView()

        case .requiresICloudAccount(let message):
            Section {
                Label(message, systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
                Button("Zkusit znovu") {
                    Task { await store.reload() }
                }
            }

        case .failed:
            EmptyView()

        case .missingGroup, .ready:
            EmptyView()
        }
    }
}

private struct MedicationEditorView: View {
    @EnvironmentObject private var store: MedicationStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Medication
    @State private var isSaving = false

    init(original: Medication) {
        _draft = State(initialValue: original)
    }

    var body: some View {
        Form {
            Section("Lék") {
                TextField("Název", text: $draft.name)
                TextField("Poznámka", text: $draft.note, axis: .vertical)
                DatePicker("Začátek plánu", selection: $draft.startDate, displayedComponents: .date)
            }

            Section("Časy") {
                ForEach($draft.doseTimes) { $doseTime in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Popisek", text: $doseTime.label)
                        DatePicker(
                            doseTime.label.isEmpty ? "Čas" : doseTime.label,
                            selection: timeBinding(for: $doseTime.time),
                            displayedComponents: .hourAndMinute
                        )
                    }
                }
                .onDelete { offsets in
                    let removedIds = offsets.map { draft.doseTimes[$0].id }
                    draft.doseTimes.remove(atOffsets: offsets)
                    for phaseIndex in draft.phases.indices {
                        draft.phases[phaseIndex].doses.removeAll { removedIds.contains($0.timeId) }
                    }
                }

                Button {
                    let time = DoseTime(label: "Nový čas", time: TimeOfDay(hour: 8, minute: 0))
                    draft.doseTimes.append(time)
                    for phaseIndex in draft.phases.indices {
                        draft.phases[phaseIndex].doses.append(DoseEntry(timeId: time.id, amount: "0"))
                    }
                } label: {
                    Label("Přidat čas", systemImage: "plus.circle")
                }
            }

            Section("Fáze dávkování") {
                ForEach($draft.phases) { $phase in
                    PhaseEditorView(phase: $phase, doseTimes: draft.doseTimes)
                }
                .onDelete { offsets in
                    draft.phases.remove(atOffsets: offsets)
                }

                Button {
                    draft.phases.append(
                        PlanPhase(
                            title: "Nová fáze",
                            durationDays: nil,
                            doses: draft.doseTimes.map { DoseEntry(timeId: $0.id, amount: "0") }
                        )
                    )
                } label: {
                    Label("Přidat fázi", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle(draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    save()
                } label: {
                    Text("Uložit")
                }
                .fontWeight(.semibold)
                .disabled(isSaving)
            }
        }
    }

    private func save() {
        guard !isSaving else { return }

        isSaving = true

        Task {
            do {
                try await store.upsertMedication(normalized(draft))
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
            }
        }
    }

    private func timeBinding(for time: Binding<TimeOfDay>) -> Binding<Date> {
        Binding<Date> {
            Calendar.current.date(bySettingHour: time.wrappedValue.hour, minute: time.wrappedValue.minute, second: 0, of: Date()) ?? Date()
        } set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            time.wrappedValue = TimeOfDay(hour: components.hour ?? 0, minute: components.minute ?? 0)
        }
    }

    private func normalized(_ medication: Medication) -> Medication {
        var result = medication
        let knownTimeIds = Set(result.doseTimes.map(\.id))
        for phaseIndex in result.phases.indices {
            result.phases[phaseIndex].doses.removeAll { !knownTimeIds.contains($0.timeId) }
            for doseTime in result.doseTimes where !result.phases[phaseIndex].doses.contains(where: { $0.timeId == doseTime.id }) {
                result.phases[phaseIndex].doses.append(DoseEntry(timeId: doseTime.id, amount: "0"))
            }
        }
        return result
    }
}

private struct PhaseEditorView: View {
    @Binding var phase: PlanPhase
    var doseTimes: [DoseTime]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Název fáze", text: $phase.title)

            Toggle("Fáze má pevné trvání", isOn: durationEnabled)

            if durationEnabled.wrappedValue {
                Stepper(value: durationDays, in: 1...365) {
                    Text("Trvání: \(phase.durationDays ?? 1) dní")
                }
            } else {
                Text("Platí až do další změny")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(doseTimes) { doseTime in
                HStack {
                    Text(doseTime.label)
                    Spacer()
                    TextField("0", text: doseAmountBinding(for: doseTime.id))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .frame(maxWidth: 96)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var durationEnabled: Binding<Bool> {
        Binding<Bool> {
            phase.durationDays != nil
        } set: { enabled in
            phase.durationDays = enabled ? (phase.durationDays ?? 1) : nil
        }
    }

    private var durationDays: Binding<Int> {
        Binding<Int> {
            phase.durationDays ?? 1
        } set: { value in
            phase.durationDays = value
        }
    }

    private func doseAmountBinding(for timeId: UUID) -> Binding<String> {
        Binding<String> {
            phase.doses.first(where: { $0.timeId == timeId })?.amount ?? "0"
        } set: { value in
            if let index = phase.doses.firstIndex(where: { $0.timeId == timeId }) {
                phase.doses[index].amount = value
            } else {
                phase.doses.append(DoseEntry(timeId: timeId, amount: value))
            }
        }
    }
}
