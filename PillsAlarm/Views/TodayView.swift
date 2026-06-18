import SwiftUI
import UIKit

struct TodayView: View {
    @EnvironmentObject private var store: MedicationStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedDate = Date()
    @State private var pageOffset = 0
    @State private var midnightWatcherID = UUID()

    private var isShowingToday: Bool {
        selectedDate.isSameDay(as: Date())
    }

    var body: some View {
        NavigationStack {
            AppScreen(
                title: selectedDate.relativeDayLabel(),
                titleColor: isShowingToday ? .primary : .teal
            ) {
                todayHeaderTrailing
            } content: {
                dayPager
            }
            .onAppear {
                syncToActualToday()
                restartMidnightWatcher()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                syncToActualToday()
                restartMidnightWatcher()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                syncToActualToday()
                restartMidnightWatcher()
            }
            .task(id: midnightWatcherID) {
                await waitForNextMidnight()
            }
        }
    }

    private var todayHeaderTrailing: some View {
        HStack(spacing: 8) {
            if !isShowingToday {
                Button {
                    syncToActualToday()
                } label: {
                    Label {
                        Text("Dnes")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    } icon: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
            }

            DatePicker("", selection: selectedDateBinding, displayedComponents: .date)
                .labelsHidden()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var dayPager: some View {
        TabView(selection: $pageOffset) {
            ForEach([-1, 0, 1], id: \.self) { offset in
                TodayDoseList(
                    date: date(forPageOffset: offset)
                )
                    .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: pageOffset) { _, newOffset in
            moveSelectedDate(by: newOffset)
        }
    }

    private var selectedDateBinding: Binding<Date> {
        Binding {
            selectedDate
        } set: { date in
            setSelectedDate(date)
        }
    }

    private func date(forPageOffset offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: selectedDate) ?? selectedDate
    }

    private func setSelectedDate(_ date: Date) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedDate = date
            pageOffset = 0
        }
    }

    private func moveSelectedDate(by offset: Int) {
        guard offset != 0 else { return }
        setSelectedDate(date(forPageOffset: offset))
    }

    private func syncToActualToday() {
        setSelectedDate(Date())
    }

    private func restartMidnightWatcher() {
        midnightWatcherID = UUID()
    }

    private func waitForNextMidnight() async {
        let now = Date()
        let nextMidnight = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: Calendar.current.startOfDay(for: now)
        ) ?? now.addingTimeInterval(24 * 60 * 60)
        let delaySeconds = max(nextMidnight.timeIntervalSince(now), 1)

        do {
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        } catch {
            return
        }

        guard !Task.isCancelled else { return }
        await MainActor.run {
            syncToActualToday()
            restartMidnightWatcher()
        }
    }
}

private struct TodayDoseList: View {
    @EnvironmentObject private var store: MedicationStore
    var date: Date

    private var doses: [GeneratedDose] {
        store.doses(on: date)
    }

    var body: some View {
        List {
            if doses.isEmpty {
                EmptyStateView(title: "Na tento den nejsou naplánované dávky", systemImage: "pills")
                    .listRowBackground(Color.clear)
            } else {
                ForEach(doses) { dose in
                    DoseRow(dose: dose)
                }
            }
        }
        .refreshable {
            await store.reload(showSyncIndicator: false)
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
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dose.timeLabel)
                        .font(.headline)
                    Text(dose.scheduledTime.label)
                        .font(.caption)
                        .foregroundStyle(isOverdueToday ? .red : .secondary)
                }
                .frame(width: 72, alignment: .leading)

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
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
                        Text(dose.phaseTitle)
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

            if let confirmation {
                HStack {
                    let memberName = store.displayName(for: confirmation)
                    let statusText = memberName.map {
                        confirmation.status == .confirmed ? "Podáno: \($0)" : "Přeskočil/a: \($0)"
                    } ?? confirmation.status.label
                    StatusBadge(
                        text: statusText,
                        systemImage: confirmation.status == .confirmed ? "checkmark.circle.fill" : "forward.circle.fill",
                        tint: confirmation.status == .confirmed ? .green : .secondary
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
                    .buttonStyle(DoseActionButtonStyle(kind: .secondary))
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

                        Spacer()

                        Button {
                            showsSkipConfirmation = true
                        } label: {
                            Label("Přeskočit", systemImage: "forward.circle")
                        }
                        .buttonStyle(DoseActionButtonStyle(kind: .secondary))
                        .disabled(store.isSyncing)
                    }
                }
            }
        }
        .padding(.vertical, 8)
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
        case .primary, .secondary:
            return .subheadline.weight(.semibold)
        }
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary:
            return .white
        case .secondary:
            return .secondary
        }
    }

    private var horizontalPadding: CGFloat {
        switch kind {
        case .primary, .secondary:
            return 14
        }
    }

    private var verticalPadding: CGFloat {
        switch kind {
        case .primary, .secondary:
            return 8
        }
    }

    private var minimumHeight: CGFloat {
        switch kind {
        case .primary, .secondary:
            return 36
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
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .primary:
            return .teal
        case .secondary:
            return Color.secondary.opacity(0.08)
        }
    }
}
