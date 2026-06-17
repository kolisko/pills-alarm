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
                    HStack(spacing: 6) {
                        if dose.isShared {
                            Image(systemName: "person.2.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.teal)
                                .accessibilityLabel("Sdílená dávka")
                        }
                        Text(dose.medicationName)
                            .font(.headline)
                    }
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
                    let memberName = store.displayName(for: confirmation)
                    let statusText = memberName.map {
                        confirmation.status == .confirmed ? "Podáno: \($0)" : "Přeskočil/a: \($0)"
                    } ?? confirmation.status.label
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
                    .buttonStyle(DoseActionButtonStyle(kind: .undo))
                    .disabled(store.isSyncing)
                }
            } else {
                if !store.canRecordDose(dose) {
                    Label("Nejdřív vyplň svoje jméno ve Skupině.", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                } else {
                    HStack {
                        Button {
                            Task {
                                try? await store.confirm(dose, status: .confirmed)
                            }
                        } label: {
                            Label("Podat", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(DoseActionButtonStyle(kind: .primary))
                        .disabled(store.isSyncing)

                        Button {
                            showsSkipConfirmation = true
                        } label: {
                            Label("Přeskočit", systemImage: "forward.circle")
                        }
                        .buttonStyle(DoseActionButtonStyle(kind: .secondary))
                        .controlSize(.small)
                        .disabled(store.isSyncing)
                    }
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

private struct DoseActionButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case undo
    }

    @Environment(\.isEnabled) private var isEnabled
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: minimumHeight)
            .background(backgroundShape(configuration: configuration))
            .overlay(borderShape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.42)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var font: Font {
        switch kind {
        case .primary:
            return .subheadline.weight(.semibold)
        case .secondary, .undo:
            return .caption.weight(.semibold)
        }
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary:
            return .white
        case .secondary:
            return .secondary
        case .undo:
            return .teal
        }
    }

    private var horizontalPadding: CGFloat {
        switch kind {
        case .primary:
            return 14
        case .secondary, .undo:
            return 10
        }
    }

    private var verticalPadding: CGFloat {
        switch kind {
        case .primary:
            return 8
        case .secondary, .undo:
            return 6
        }
    }

    private var minimumHeight: CGFloat {
        switch kind {
        case .primary:
            return 36
        case .secondary, .undo:
            return 30
        }
    }

    @ViewBuilder
    private func backgroundShape(configuration: Configuration) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(backgroundColor)
    }

    @ViewBuilder
    private var borderShape: some View {
        switch kind {
        case .primary:
            EmptyView()
        case .secondary:
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        case .undo:
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.teal.opacity(0.25), lineWidth: 1)
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .primary:
            return .teal
        case .secondary:
            return Color.secondary.opacity(0.08)
        case .undo:
            return Color.teal.opacity(0.09)
        }
    }
}
