import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: MedicationStore

    private var confirmations: [ConfirmationListItem] {
        store.confirmationItems
    }

    var body: some View {
        NavigationStack {
            List {
                if confirmations.isEmpty {
                    EmptyStateView(title: "Zatím žádná historie", systemImage: "clock")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(confirmations) { item in
                        let confirmation = item.confirmation
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                StatusBadge(
                                    text: confirmation.status.label,
                                    systemImage: confirmation.status == .confirmed ? "checkmark.circle.fill" : "forward.circle.fill",
                                    tint: confirmation.status == .confirmed ? .green : .orange
                                )
                                Spacer()
                                Text(confirmation.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                if item.source.isShared {
                                    Image(systemName: "person.2.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.teal)
                                        .accessibilityLabel("Sdílený záznam")
                                }
                                Text(summary(for: confirmation, memberName: store.displayName(for: confirmation)))
                                    .font(.headline)
                            }
                            Text("Plánováno \(confirmation.scheduledDate.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Historie")
            .refreshable {
                await store.reload(showSyncIndicator: false)
            }
        }
    }

    private func summary(for confirmation: DoseConfirmation, memberName: String?) -> String {
        guard let memberName else {
            return confirmation.amount
        }

        return "\(confirmation.amount) potvrdil/a \(memberName)"
    }
}
