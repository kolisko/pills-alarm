import SwiftUI
import PillCore

struct PlanView: View {
    @EnvironmentObject private var store: MedicationStore
    @State private var newMedication: Medication?

    var body: some View {
        NavigationStack {
            AppScreen(title: "Plán") {
                Button {
                    newMedication = store.addMedication()
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                }
                .foregroundStyle(.teal)
                .disabled(!store.hasCloudWorkspace)
            } content: {
                List {
                    syncStatusSection

                    if store.medicationItems.isEmpty {
                        CloudBackedEmptyStateView(
                            loadState: store.loadState,
                            emptyTitle: "Zatím není vytvořený žádný plán",
                            systemImage: "calendar.badge.plus"
                        )
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
                                            Text(item.medication.name)
                                                .font(.headline)
                                            if item.source.isShared {
                                                Image(systemName: "person.2.fill")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(.secondary)
                                                    .accessibilityLabel("Sdílený plán")
                                            }
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
                .refreshable {
                    await store.reload(showSyncIndicator: false, forceFullRecovery: true)
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
                Picker("Forma", selection: $draft.form) {
                    ForEach(MedicationForm.allCases) { form in
                        Text(form.label).tag(form)
                    }
                }
                .pickerStyle(.segmented)
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

                Toggle("Medical Timeline", isOn: medicalTimelineBinding)
                if let identifier = store.medicalTimelinePublicIdentifier {
                    LabeledContent("Medical Timeline ID") {
                        Text(identifier)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Text(medicalTimelineFooterText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                ForEach(draft.phases.indices, id: \.self) { phaseIndex in
                    PhaseEditorView(
                        phase: $draft.phases[phaseIndex],
                        dateRange: phaseDateRange(for: phaseIndex),
                        doseTimes: draft.doseTimes,
                        medicationForm: draft.form
                    )
                }
                .onDelete { offsets in
                    guard !isReadOnly else { return }
                    draft.phases.remove(atOffsets: offsets)
                }

                if !isReadOnly {
                    Button {
                        draft = MedicationPhaseEditingUseCase.addingPhaseStartingToday(
                            to: draft,
                            title: "Nová fáze"
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

    private var medicalTimelineBinding: Binding<Bool> {
        Binding {
            draft.isPublishedToMedicalTimeline
        } set: { isPublished in
            draft.isPublishedToMedicalTimeline = isPublished
        }
    }

    private var medicalTimelineFooterText: String {
        if draft.isPublishedToMedicalTimeline {
            if store.medicalTimelinePublicIdentifier == nil {
                return "Po uložení se vytvoří jedno stabilní Medical Timeline ID. Pod ním bude veřejně dostupný seznam všech publikovaných plánů."
            }

            return "Pill Care bude pod jedním Medical Timeline ID udržovat veřejnou kopii všech publikovaných plánů. Kdokoli s tímto ID je může zobrazit."
        }

        return "Plán se nebude publikovat pro Medical Timeline."
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

    private func phaseDateRange(for phaseIndex: Int, calendar: Calendar = .current) -> PhaseDateRange? {
        guard draft.phases.indices.contains(phaseIndex) else { return nil }

        var startDate = calendar.startOfDay(for: draft.startDate)
        for previousPhaseIndex in draft.phases.indices where previousPhaseIndex < phaseIndex {
            guard let durationDays = draft.phases[previousPhaseIndex].durationDays,
                  let nextStartDate = calendar.date(byAdding: .day, value: durationDays, to: startDate)
            else {
                return nil
            }
            startDate = nextStartDate
        }

        let durationDays = draft.phases[phaseIndex].durationDays
        let endDate = durationDays.flatMap { duration -> Date? in
            guard duration > 0 else { return nil }
            return calendar.date(byAdding: .day, value: duration - 1, to: startDate)
        }

        return PhaseDateRange(startDate: startDate, durationDays: durationDays, endDate: endDate)
    }
}

private struct PhaseEditorView: View {
    @Binding var phase: PlanPhase
    var dateRange: PhaseDateRange?
    var doseTimes: [DoseTime]
    var medicationForm: MedicationForm

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Název fáze", text: $phase.title)

            Toggle("Fáze má pevné trvání", isOn: durationEnabled)

            if durationEnabled.wrappedValue {
                Stepper(value: durationDays, in: 0...365) {
                    Text("Trvání: \(phase.durationDays ?? 1) dní")
                }
            } else {
                Text("Platí až do další změny")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let dateRange {
                PhaseDateRangeView(dateRange: dateRange)
            }

            ForEach(doseTimes) { doseTime in
                VStack(alignment: .leading, spacing: 8) {
                    Text(doseTime.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    PillAmountControl(amount: doseAmountBinding(for: doseTime.id), medicationForm: medicationForm)
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
            phase.durationDays = enabled ? (phase.durationDays ?? 0) : nil
        }
    }

    private var durationDays: Binding<Int> {
        Binding<Int> {
            phase.durationDays ?? 0
        } set: { value in
            phase.durationDays = value
        }
    }

    private func doseAmountBinding(for timeId: UUID) -> Binding<Double> {
        Binding<Double> {
            phase.doses.first(where: { $0.timeId == timeId })?.amount ?? 0
        } set: { value in
            let amount = DoseAmountFormatter.normalized(value, for: medicationForm)
            if let index = phase.doses.firstIndex(where: { $0.timeId == timeId }) {
                phase.doses[index].amount = amount
            } else {
                var entry = DoseEntry(timeId: timeId, amount: 0)
                entry.amount = amount
                phase.doses.append(entry)
            }
        }
    }
}

private struct PhaseDateRange: Equatable {
    var startDate: Date
    var durationDays: Int?
    var endDate: Date?
}

private struct PhaseDateRangeView: View {
    var dateRange: PhaseDateRange

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            rangeRow(title: "Od", value: dateRange.startDate.relativeDayAndDateLabel())

            if let durationDays = dateRange.durationDays {
                if durationDays == 0 {
                    rangeRow(title: "Do", value: "Bez aktivního dne")
                } else if let endDate = dateRange.endDate {
                    rangeRow(title: "Do", value: endDate.relativeDayAndDateLabel())
                }
            } else {
                rangeRow(title: "Do", value: "Bez konce")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func rangeRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .fontWeight(.semibold)
                .frame(width: 22, alignment: .leading)
            Text(value)
        }
    }
}

private struct PillAmountControl: View {
    @Binding var amount: Double
    var medicationForm: MedicationForm
    private let controlColor = Color.teal

    var body: some View {
        switch medicationForm {
        case .tablet:
            tabletControl
        case .syrup:
            syrupControl
        }
    }

    private var tabletControl: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 8) {
                amountButton(delta: -0.25, fraction: 0.25, systemImage: "minus", label: "Ubrat čtvrt pilulky")
                    .disabled(amount <= 0)

                amountButton(delta: -1, fraction: 1, systemImage: "minus", label: "Ubrat jednu pilulku")
                    .disabled(amount <= 0)
            }

            Spacer(minLength: 18)

            PillAmountVisualization(amount: amount, medicationForm: .tablet)
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

    private var syrupControl: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 8) {
                syrupAmountButton(delta: -5, label: "Ubrat pět mililitrů")
                    .disabled(amount <= 0)

                syrupAmountButton(delta: -1, label: "Ubrat jeden mililitr")
                    .disabled(amount <= 0)
            }

            Spacer(minLength: 18)

            PillAmountVisualization(amount: amount, medicationForm: .syrup)
                .frame(minWidth: 74, alignment: .center)
                .accessibilityLabel("Dávka \(accessibilityAmount)")

            Spacer(minLength: 18)

            HStack(spacing: 8) {
                syrupAmountButton(delta: 1, label: "Přidat jeden mililitr")

                syrupAmountButton(delta: 5, label: "Přidat pět mililitrů")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var accessibilityAmount: String {
        DoseAmountFormatter.displayText(for: amount, form: medicationForm)
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

    private func syrupAmountButton(delta: Double, label: String) -> some View {
        Button {
            amount = DoseAmountFormatter.normalized(amount + delta, for: .syrup)
        } label: {
            SyrupAmountStepIcon(systemImage: delta > 0 ? "plus" : "minus", color: controlColor)
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

private struct SyrupAmountStepIcon: View {
    @Environment(\.isEnabled) private var isEnabled
    var systemImage: String
    var color: Color

    var body: some View {
        ZStack(alignment: systemImage == "plus" ? .bottomTrailing : .bottomLeading) {
            SyrupDropIcon(amountText: "", color: color, activeFillProgress: 0)
                .frame(width: 24, height: 28)

            Image(systemName: "\(systemImage).circle.fill")
                .font(.caption2.weight(.bold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, color)
                .offset(x: systemImage == "plus" ? 5 : -5, y: 5)
        }
        .frame(width: 32, height: 32)
        .opacity(isEnabled ? 1 : 0.35)
        .contentShape(Rectangle())
    }
}

struct PillAmountVisualization: View {
    var amount: Double
    var medicationForm: MedicationForm = .tablet
    var isActiveDose = false
    var doseColor: Color = .secondary
    @State private var deactivationStartDate: Date?
    @State private var deactivationStartPulse = 0.0

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
        TimelineView(.animation) { context in
            let pulse = activePulseValue(at: context.date)

            doseStack(activeFillProgress: pulse)
                .scaleEffect(1 + 0.08 * pulse)
                .opacity(1 - 0.28 * pulse)
                .shadow(color: Color.teal.opacity(0.22 * pulse), radius: 4, y: 1)
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
        .onChange(of: isActiveDose) { _, newValue in
            if newValue {
                deactivationStartDate = nil
                deactivationStartPulse = 0
            } else {
                deactivationStartPulse = activePulse(at: Date())
                deactivationStartDate = Date()
            }
        }
    }

    private func activePulseValue(at date: Date) -> Double {
        if isActiveDose {
            return activePulse(at: date)
        }

        guard let deactivationStartDate else { return 0 }
        let progress = min(max(date.timeIntervalSince(deactivationStartDate) / 0.18, 0), 1)
        return deactivationStartPulse * (1 - progress)
    }

    private func activePulse(at date: Date) -> Double {
        let period = 1.8
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return (sin(progress * 2 * .pi - .pi / 2) + 1) / 2
    }

    @ViewBuilder
    private func doseStack(activeFillProgress: Double) -> some View {
        switch medicationForm {
        case .tablet:
            pillStack(activeFillProgress: activeFillProgress)
        case .syrup:
            SyrupDropIcon(
                amountText: DoseAmountFormatter.displayText(for: amount, form: .syrup),
                color: doseColor,
                activeFillProgress: activeFillProgress
            )
            .frame(width: 44, height: 36)
        }
    }

    @ViewBuilder
    private func pillStack(activeFillProgress: Double) -> some View {
        HStack(spacing: 5) {
            if quarters == 0 {
                EmptyDoseIcon()
                    .frame(width: 36, height: 32)
            } else {
                if wholeCount >= 3 {
                    StackedPillIcon(count: wholeCount, color: doseColor, activeFillProgress: activeFillProgress)
                        .frame(width: 44, height: 38)
                } else {
                    ForEach(0..<wholeCount, id: \.self) { _ in
                        PillPortionIcon(
                            fraction: 1,
                            color: doseColor,
                            showsOutline: false,
                            activeFillProgress: activeFillProgress
                        )
                            .frame(width: 36, height: 36)
                    }
                }

                if fraction > 0 {
                    PillPortionIcon(
                        fraction: fraction,
                        color: doseColor,
                        showsOutline: true,
                        activeFillProgress: activeFillProgress
                    )
                        .frame(width: 36, height: 36)
                }
            }
        }
        .frame(height: 38)
    }
}

private struct SyrupDropIcon: View {
    var amountText: String
    var color: Color
    var activeFillProgress: Double

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let strokeWidth = max(diameter * 0.1, 2)
            let fillScale = 0.45 + 0.55 * activeFillProgress
            let fillOpacity = 0.26 * activeFillProgress

            ZStack {
                DropShape()
                    .fill(color.opacity(fillOpacity))
                    .scaleEffect(fillScale)

                DropShape()
                    .stroke(
                        color.opacity(0.95),
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                    )

                if !amountText.isEmpty {
                    Text(amountText)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .padding(.horizontal, 3)
                        .offset(y: diameter * 0.12)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct DropShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()

        path.move(to: CGPoint(x: width * 0.5, y: height * 0.04))
        path.addCurve(
            to: CGPoint(x: width * 0.86, y: height * 0.58),
            control1: CGPoint(x: width * 0.66, y: height * 0.21),
            control2: CGPoint(x: width * 0.86, y: height * 0.38)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.5, y: height * 0.96),
            control1: CGPoint(x: width * 0.86, y: height * 0.81),
            control2: CGPoint(x: width * 0.7, y: height * 0.96)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.14, y: height * 0.58),
            control1: CGPoint(x: width * 0.3, y: height * 0.96),
            control2: CGPoint(x: width * 0.14, y: height * 0.81)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.5, y: height * 0.04),
            control1: CGPoint(x: width * 0.14, y: height * 0.38),
            control2: CGPoint(x: width * 0.34, y: height * 0.21)
        )
        path.closeSubpath()
        return path
    }
}

private struct PillPortionIcon: View {
    var fraction: Double
    var color: Color
    var showsOutline: Bool
    var activeFillProgress = 0.0

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let normalizedFraction = min(max(fraction, 0), 1)
            let strokeWidth = max(diameter * 0.1, 2)
            let fillScale = 0.42 + 0.58 * activeFillProgress
            let fillOpacity = 0.26 * activeFillProgress

            ZStack {
                if normalizedFraction > 0 {
                    if normalizedFraction >= 1 {
                        Circle()
                            .fill(color.opacity(fillOpacity))
                            .scaleEffect(fillScale)

                        Circle()
                            .stroke(
                                color.opacity(0.95),
                                style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                            )
                    } else {
                        CircleSegmentShape(fraction: normalizedFraction)
                            .fill(color.opacity(fillOpacity))
                            .scaleEffect(fillScale, anchor: .center)

                        CircleSegmentShape(fraction: normalizedFraction)
                            .stroke(
                                color.opacity(0.95),
                                style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                            )
                    }
                }
            }
            .frame(width: diameter, height: diameter)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .compositingGroup()
            .shadow(color: color.opacity(normalizedFraction > 0 ? 0.08 : 0), radius: diameter / 12, y: 1)
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
    var activeFillProgress = 0.0

    var body: some View {
        ZStack {
            PillPortionIcon(
                fraction: 1,
                color: color,
                showsOutline: false,
                activeFillProgress: activeFillProgress
            )
                .opacity(0.28)
                .offset(x: -5, y: 4)

            PillPortionIcon(
                fraction: 1,
                color: color,
                showsOutline: false,
                activeFillProgress: activeFillProgress
            )
                .opacity(0.48)
                .offset(x: -2, y: 2)

            PillPortionIcon(
                fraction: 1,
                color: color,
                showsOutline: false,
                activeFillProgress: activeFillProgress
            )
                .overlay {
                    Text("\(count)×")
                        .font(.caption.weight(.black).monospacedDigit())
                        .foregroundStyle(color)
                        .minimumScaleFactor(0.7)
                }
        }
    }
}
