import SwiftUI

struct PlanView: View {
    @EnvironmentObject private var store: MedicationStore
    @State private var newMedication: Medication?

    var body: some View {
        NavigationStack {
            List {
                syncStatusSection

                if store.medicationItems.isEmpty {
                    EmptyStateView(title: "Zatím není vytvořený žádný plán", systemImage: "calendar.badge.plus")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(store.medicationItems) { item in
                        NavigationLink {
                            MedicationEditorView(
                                original: item.medication,
                                source: item.source,
                                isReadOnly: !store.canEditMedication(item)
                            )
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        if item.source.isShared {
                                            Image(systemName: "person.2.fill")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.teal)
                                                .accessibilityLabel("Sdílený plán")
                                        }
                                        Text(item.medication.name)
                                            .font(.headline)
                                    }
                                    Text("\(item.medication.phases.count) fáze · start \(item.medication.startDate.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if item.source.isShared {
                                    Text("Sdílené")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.teal)
                                }
                            }
                        }
                        .deleteDisabled(!store.canEditMedication(item))
                    }
                    .onDelete { offsets in
                        let items = store.medicationItems
                        for index in offsets {
                            store.deleteMedication(items[index])
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
    private let original: Medication
    @State private var draft: Medication
    @State private var isSaving = false
    @State private var didInitializeSharing = false
    var source: WorkspaceSource?
    var isReadOnly: Bool

    init(original: Medication, source: WorkspaceSource? = nil, isReadOnly: Bool = false) {
        self.original = original
        _draft = State(initialValue: original)
        self.source = source
        self.isReadOnly = isReadOnly
    }

    var body: some View {
        Form {
            if isReadOnly {
                Section {
                    Label("Sdílený plán je v této verzi jen pro čtení.", systemImage: "person.2.fill")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Lék") {
                TextField("Název", text: $draft.name)
                TextField("Poznámka", text: $draft.note, axis: .vertical)
                DatePicker("Začátek plánu", selection: $draft.startDate, displayedComponents: .date)
            }

            Section("Sdílení") {
                if store.canSharePlans {
                    Toggle("Sdílet ve skupině", isOn: sharingBinding)
                    Text(sharingFooterText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Nejdřív vytvoř skupinu. Do té doby je plán soukromý.", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Časy") {
                ForEach($draft.doseTimes) { $doseTime in
                    HStack(spacing: 12) {
                        TextField("Popisek", text: $doseTime.label)
                            .textInputAutocapitalization(.sentences)

                        DatePicker(
                            "",
                            selection: timeBinding(for: $doseTime.time),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                    }
                }
                .onDelete { offsets in
                    guard !isReadOnly else { return }
                    let removedIds = offsets.map { draft.doseTimes[$0].id }
                    draft.doseTimes.remove(atOffsets: offsets)
                    for phaseIndex in draft.phases.indices {
                        draft.phases[phaseIndex].doses.removeAll { removedIds.contains($0.timeId) }
                    }
                }

                if !isReadOnly {
                    Button {
                        let time = DoseTime(label: "Nový čas", time: TimeOfDay(hour: 8, minute: 0))
                        draft.doseTimes.append(time)
                        for phaseIndex in draft.phases.indices {
                            draft.phases[phaseIndex].doses.append(DoseEntry(timeId: time.id, amount: 0))
                        }
                    } label: {
                        Label("Přidat čas", systemImage: "plus.circle")
                    }
                }
            }

            Section("Fáze dávkování") {
                ForEach($draft.phases) { $phase in
                    PhaseEditorView(phase: $phase, doseTimes: draft.doseTimes)
                }
                .onDelete { offsets in
                    guard !isReadOnly else { return }
                    draft.phases.remove(atOffsets: offsets)
                }

                if !isReadOnly {
                    Button {
                        draft.phases.append(
                            PlanPhase(
                                title: "Nová fáze",
                                durationDays: nil,
                                doses: draft.doseTimes.map { DoseEntry(timeId: $0.id, amount: 0) }
                            )
                        )
                    } label: {
                        Label("Přidat fázi", systemImage: "plus.circle")
                    }
                }
            }
        }
        .disabled(isReadOnly)
        .onAppear {
            guard !didInitializeSharing else { return }
            didInitializeSharing = true
            if source?.isShared == true, draft.sharedGroupId == nil {
                draft.sharedGroupId = store.sharingGroupId ?? source?.id
            }
        }
        .navigationTitle(draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isReadOnly {
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
    }

    private func save() {
        guard !isSaving else { return }

        isSaving = true

        Task {
            do {
                let medication = normalized(draft)
                if let source {
                    let item = MedicationListItem(medication: original, source: source)
                    let shouldShare = medication.sharedGroupId != nil
                    if source.isShared != shouldShare {
                        try await store.setMedication(item, updatedMedication: medication, sharedWithOwnedGroup: shouldShare)
                    } else {
                        try await store.upsertMedication(medication)
                    }
                } else {
                    try await store.upsertMedication(medication)
                }
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
            }
        }
    }

    private var sharingBinding: Binding<Bool> {
        Binding {
            draft.sharedGroupId != nil
        } set: { isShared in
            draft.sharedGroupId = isShared ? store.sharingGroupId : nil
        }
    }

    private var sharingFooterText: String {
        if draft.sharedGroupId != nil || source?.isShared == true {
            return "Plán bude viditelný členům skupiny \(store.sharingGroupName)."
        }

        return "Plán zůstane soukromý a uvidíš ho jen na svých zařízeních."
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
                result.phases[phaseIndex].doses.append(DoseEntry(timeId: doseTime.id, amount: 0))
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
                VStack(alignment: .leading, spacing: 8) {
                    Text(doseTime.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    PillAmountControl(amount: doseAmountBinding(for: doseTime.id))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.vertical, 6)
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

    private func doseAmountBinding(for timeId: UUID) -> Binding<Double> {
        Binding<Double> {
            phase.doses.first(where: { $0.timeId == timeId })?.amount ?? 0
        } set: { value in
            let amount = DoseAmountFormatter.normalized(value)
            if let index = phase.doses.firstIndex(where: { $0.timeId == timeId }) {
                phase.doses[index].amount = amount
            } else {
                phase.doses.append(DoseEntry(timeId: timeId, amount: amount))
            }
        }
    }
}

private struct PillAmountControl: View {
    @Binding var amount: Double
    private let controlColor = Color.teal

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 8) {
                amountButton(delta: -0.25, fraction: 0.25, systemImage: "minus", label: "Ubrat čtvrt pilulky")
                    .disabled(amount <= 0)

                amountButton(delta: -1, fraction: 1, systemImage: "minus", label: "Ubrat jednu pilulku")
                    .disabled(amount <= 0)
            }

            Spacer(minLength: 18)

            PillAmountVisualization(amount: amount)
                .frame(minWidth: 74, alignment: .center)
                .accessibilityLabel("Dávka \(accessibilityAmount)")

            Spacer(minLength: 18)

            HStack(spacing: 8) {
                amountButton(delta: 1, fraction: 1, systemImage: "plus", label: "Přidat jednu pilulku")

                amountButton(delta: 0.25, fraction: 0.25, systemImage: "plus", label: "Přidat čtvrt pilulky")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var accessibilityAmount: String {
        DoseAmountFormatter.displayText(for: amount)
    }

    private func amountButton(delta: Double, fraction: Double, systemImage: String, label: String) -> some View {
        Button {
            amount = DoseAmountFormatter.normalized(amount + delta)
        } label: {
            PillAmountStepIcon(fraction: fraction, systemImage: systemImage, color: controlColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct PillAmountStepIcon: View {
    @Environment(\.isEnabled) private var isEnabled
    var fraction: Double
    var systemImage: String
    var color: Color

    var body: some View {
        ZStack(alignment: systemImage == "plus" ? .bottomTrailing : .bottomLeading) {
            PillPortionIcon(fraction: fraction, color: color, showsOutline: true)
                .frame(width: 24, height: 24)

            Image(systemName: "\(systemImage).circle.fill")
                .font(.caption2.weight(.bold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, color)
                .offset(x: systemImage == "plus" ? 5 : -5, y: 5)
        }
        .frame(width: 32, height: 30)
        .opacity(isEnabled ? 1 : 0.35)
        .contentShape(Rectangle())
    }
}

struct PillAmountVisualization: View {
    var amount: Double
    private let doseColor = Color(red: 0.12, green: 0.48, blue: 0.72)

    private var normalizedAmount: Double {
        DoseAmountFormatter.normalized(amount)
    }

    private var quarters: Int {
        Int((normalizedAmount * 4).rounded())
    }

    private var wholeCount: Int {
        quarters / 4
    }

    private var fraction: Double {
        Double(quarters % 4) / 4
    }

    var body: some View {
        HStack(spacing: 5) {
            if quarters == 0 {
                EmptyDoseIcon()
                    .frame(width: 32, height: 28)
            } else {
                if wholeCount >= 3 {
                    StackedPillIcon(count: wholeCount, color: doseColor)
                        .frame(width: 38, height: 34)
                } else {
                    ForEach(0..<wholeCount, id: \.self) { _ in
                        PillPortionIcon(fraction: 1, color: doseColor, showsOutline: false)
                            .frame(width: 30, height: 30)
                    }
                }

                if fraction > 0 {
                    PillPortionIcon(fraction: fraction, color: doseColor, showsOutline: true)
                        .frame(width: 30, height: 30)
                }
            }
        }
        .frame(height: 32)
    }
}

private struct PillPortionIcon: View {
    var fraction: Double
    var color: Color
    var showsOutline: Bool

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let normalizedFraction = min(max(fraction, 0), 1)

            ZStack {
                Circle()
                    .fill(color.opacity(showsOutline ? 0.08 : 0.95))

                if normalizedFraction > 0 {
                    if normalizedFraction >= 1 {
                        Circle()
                            .fill(color.opacity(0.95))
                    } else {
                        CircleSegmentShape(fraction: normalizedFraction)
                            .fill(color.opacity(0.95))
                    }
                }

                if showsOutline {
                    Circle()
                        .stroke(color.opacity(0.45), lineWidth: 1.4)
                }

                if normalizedFraction > 0, normalizedFraction < 1 {
                    CircleSegmentShape(fraction: normalizedFraction)
                        .stroke(Color.white.opacity(0.78), lineWidth: 1.1)
                }
            }
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            }
            .frame(width: diameter, height: diameter)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .compositingGroup()
            .shadow(color: color.opacity(normalizedFraction > 0 ? 0.18 : 0), radius: diameter / 10, y: 1)
        }
    }
}

private struct CircleSegmentShape: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        let normalizedFraction = min(max(fraction, 0), 1)
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = Angle.degrees(-90)
        let end = Angle.degrees(-90 + 360 * normalizedFraction)

        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.closeSubpath()
        return path
    }
}

private struct EmptyDoseIcon: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.34), lineWidth: 1.4)
                    }

                Path { path in
                    path.move(to: CGPoint(x: width * 0.28, y: height * 0.5))
                    path.addLine(to: CGPoint(x: width * 0.72, y: height * 0.5))
                }
                .stroke(Color.secondary.opacity(0.58), style: StrokeStyle(lineWidth: 2, lineCap: .round))

                Path { path in
                    path.move(to: CGPoint(x: width * 0.72, y: height * 0.26))
                    path.addLine(to: CGPoint(x: width * 0.28, y: height * 0.74))
                }
                .stroke(Color.secondary.opacity(0.42), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
            .frame(width: width, height: height)
        }
    }
}

private struct StackedPillIcon: View {
    var count: Int
    var color: Color

    var body: some View {
        ZStack {
            PillPortionIcon(fraction: 1, color: color, showsOutline: false)
                .opacity(0.28)
                .offset(x: -5, y: 4)

            PillPortionIcon(fraction: 1, color: color, showsOutline: false)
                .opacity(0.48)
                .offset(x: -2, y: 2)

            PillPortionIcon(fraction: 1, color: color, showsOutline: false)
                .overlay {
                    Text("\(count)×")
                        .font(.caption.weight(.black).monospacedDigit())
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.7)
                }
        }
    }
}
