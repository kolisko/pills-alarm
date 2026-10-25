import SwiftUI
import UIKit

struct AlarmControlDiagnosticsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot = AlarmDiagnosticSnapshot(events: [], storageError: nil)
    @State private var copied = false

    private var latestAttempt: AlarmDiagnosticEvent? {
        snapshot.events.last { $0.stage == .intentBegin }
    }

    private var latestOutcome: String {
        guard let attempt = latestAttempt else { return "Žádný zaznamenaný pokus" }
        let end = snapshot.events.last {
            $0.attemptID == attempt.attemptID && [.intentSucceeded, .intentFailed, .intentCancelled].contains($0.stage)
        }
        return end?.stage.label ?? "Bez zaznamenaného výsledku"
    }

    var body: some View {
        List {
            Section("Poslední pokus") {
                Text(latestOutcome)
                    .font(.headline)
                if let attempt = latestAttempt {
                    LabeledContent("Požadavek", value: attempt.fields["requestedEnabled"] == "true" ? "Zapnout alarmy" : "Vypnout alarmy")
                    LabeledContent("Čas", value: attempt.date.formatted(date: .abbreviated, time: .standard))
                }
                if let error = snapshot.storageError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                ForEach(snapshot.events.reversed()) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.stage.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(event.stage.isFailure ? Color.red : Color.primary)
                        Text(event.date.formatted(date: .abbreviated, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("\(event.processRole) · PID \(event.processID) · \(event.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let attemptID = event.attemptID {
                            Text("Pokus \(attemptID.uuidString.prefix(8))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if !event.fields.isEmpty {
                            Text(event.details)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("Události (\(snapshot.events.count))")
            } footer: {
                Text("Posledních 300 událostí je uloženo pouze na tomto zařízení, bez názvů léků a dávkování. Chybějící konec záznamu sám o sobě nepotvrzuje timeout ani ukončení systému.")
            }
        }
        .navigationTitle("Diagnostika ovladače")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Obnovit diagnostiku")
                .help("Obnovit diagnostiku")
                Button {
                    UIPasteboard.general.string = snapshot.report
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel(copied ? "Diagnostika zkopírována" : "Kopírovat diagnostiku")
                .help(copied ? "Diagnostika zkopírována" : "Kopírovat diagnostiku")
            }
        }
        .task { refresh() }
        .refreshable { refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    private func refresh() {
        snapshot = AlarmDiagnosticJournal.shared.snapshot()
        copied = false
    }
}
