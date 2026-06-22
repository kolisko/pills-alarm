import SwiftUI
import PillCore

struct HistoryView: View {
    @EnvironmentObject private var store: MedicationStore

    private var confirmations: [ConfirmationListItem] {
        store.confirmationItems
    }

    var body: some View {
        NavigationStack {
            AppScreen(title: "Historie") {
                List {
                    if confirmations.isEmpty {
                        CloudBackedEmptyStateView(
                            loadState: store.loadState,
                            emptyTitle: "Zatím žádná historie",
                            systemImage: "clock"
                        )
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(confirmations) { item in
                            HistoryRow(
                                item: item,
                                dose: dose(for: item),
                                memberName: store.displayName(for: item.confirmation)
                            )
                        }
                    }
                }
                .refreshable {
                    await store.reload(showSyncIndicator: false)
                }
            }
        }
    }

    private func dose(for item: ConfirmationListItem) -> HistoryDoseDisplay {
        let confirmation = item.confirmation
        guard let medicationItem = store.medicationItems.first(where: {
            $0.medication.id == confirmation.medicationId && $0.source.id == item.source.id
        }) ?? store.medicationItems.first(where: {
            $0.medication.id == confirmation.medicationId
        }) else {
            return HistoryDoseDisplay(
                medicationName: "Neznámý plán",
                medicationNote: "",
                timeLabel: "Dávka",
                scheduledTimeLabel: confirmation.scheduledDate.shortTimeLabel,
                phaseTitle: "Plánováno \(confirmation.scheduledDate.formatted(date: .abbreviated, time: .omitted))",
                amount: confirmation.amount,
                isShared: item.source.isShared
            )
        }

        let medication = medicationItem.medication
        if let generatedDose = ScheduleEngine
            .doses(
                on: confirmation.scheduledDate,
                medication: medication,
                workspaceId: medicationItem.source.id,
                isShared: medicationItem.source.isShared,
                workspaceName: medicationItem.source.name
            )
            .first(where: {
                $0.timeId == confirmation.timeId
                    && Calendar.current.isDate($0.scheduledDate, inSameDayAs: confirmation.scheduledDate)
            }) {
            return HistoryDoseDisplay(
                medicationName: generatedDose.medicationName,
                medicationNote: generatedDose.medicationNote,
                timeLabel: generatedDose.timeLabel,
                scheduledTimeLabel: generatedDose.scheduledTime.label,
                phaseTitle: generatedDose.phaseTitle,
                amount: confirmation.amount,
                isShared: generatedDose.isShared
            )
        }

        let doseTime = medication.doseTimes.first { $0.id == confirmation.timeId }
        return HistoryDoseDisplay(
            medicationName: medication.name,
            medicationNote: medication.note,
            timeLabel: doseTime?.label ?? "Dávka",
            scheduledTimeLabel: doseTime?.time.label ?? confirmation.scheduledDate.shortTimeLabel,
            phaseTitle: "Plánováno \(confirmation.scheduledDate.formatted(date: .abbreviated, time: .omitted))",
            amount: confirmation.amount,
            isShared: medicationItem.source.isShared
        )
    }
}

private struct HistoryDoseDisplay {
    var medicationName: String
    var medicationNote: String
    var timeLabel: String
    var scheduledTimeLabel: String
    var phaseTitle: String
    var amount: String
    var isShared: Bool
}

private struct HistoryRow: View {
    var item: ConfirmationListItem
    var dose: HistoryDoseDisplay
    var memberName: String?

    private var confirmation: DoseConfirmation {
        item.confirmation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dose.timeLabel)
                        .font(.headline)
                    Text(dose.scheduledTimeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 72, alignment: .leading)

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(dose.medicationName)
                                .font(.headline)
                            if dose.isShared {
                                Image(systemName: "person.2.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Sdílený záznam")
                            }
                        }
                        Text(dose.phaseTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Plánováno \(confirmation.scheduledDate.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !dose.medicationNote.isEmpty {
                            Text(dose.medicationNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    PillAmountVisualization(amount: DoseAmountFormatter.value(from: dose.amount))
                        .accessibilityLabel("Dávka \(dose.amount)")
                }
                .accessibilityElement(children: .combine)

                Spacer()
            }

            HStack {
                StatusBadge(
                    text: statusText,
                    systemImage: confirmation.status == .confirmed ? "checkmark.circle.fill" : "forward.circle.fill",
                    tint: confirmation.status == .confirmed ? .green : .secondary
                )
                Text(confirmation.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, 8)
    }

    private var statusText: String {
        guard let memberName else {
            return confirmation.status.label
        }

        switch confirmation.status {
        case .confirmed:
            return "Podáno: \(memberName)"
        case .skipped:
            return "Přeskočil/a: \(memberName)"
        }
    }
}
