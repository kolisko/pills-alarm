import SwiftUI
import UIKit
import PillCore

struct TodayView: View {
    @EnvironmentObject private var store: MedicationStore
    @Environment(\.scenePhase) private var scenePhase
    var returnToTodayTrigger: UUID?
    @State private var selectedDate = Date()
    @State private var displayedDate = Date()
    @State private var midnightWatcherID = UUID()
    @State private var returnToTodayRequest: TodayPageAnimationRequest?

    private var isShowingToday: Bool {
        displayedDate.isSameDay(as: Date())
    }

    var body: some View {
        NavigationStack {
            AppScreen(
                title: displayedDate.relativeDayTitle(),
                subtitle: displayedDate.relativeWeekdaySubtitle(),
                titleColor: isShowingToday ? .primary : .teal,
                titleAction: todayTitleAction
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
            .onChange(of: returnToTodayTrigger) {
                animateToActualToday()
            }
            .task(id: midnightWatcherID) {
                await waitForNextMidnight()
            }
        }
    }

    private var todayHeaderTrailing: some View {
        DatePicker("", selection: selectedDateBinding, displayedComponents: .date)
            .labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
    }

    private var todayTitleAction: (() -> Void)? {
        guard !isShowingToday else { return nil }
        return {
            animateToActualToday()
        }
    }

    private var dayPager: some View {
        TodayPageController(
            store: store,
            baseDate: selectedDate,
            animationRequest: returnToTodayRequest,
            onPreviewDate: { date in
                displayedDate = date
            },
            onCancel: {
                displayedDate = selectedDate
            },
            onCommitDate: { date in
                setSelectedDate(date)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedDateBinding: Binding<Date> {
        Binding {
            displayedDate
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
            displayedDate = date
        }
    }

    private func syncToActualToday() {
        setSelectedDate(Date())
    }

    private func animateToActualToday() {
        let today = Date()
        guard !displayedDate.isSameDay(as: today) else {
            syncToActualToday()
            return
        }

        returnToTodayRequest = TodayPageAnimationRequest(targetDate: today)
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

private struct TodayPageAnimationRequest: Equatable {
    let id = UUID()
    var targetDate: Date
}

private struct TodayPageController: UIViewControllerRepresentable {
    @ObservedObject var store: MedicationStore
    var baseDate: Date
    var animationRequest: TodayPageAnimationRequest?
    var onPreviewDate: (Date) -> Void
    var onCancel: () -> Void
    var onCommitDate: (Date) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageViewController = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        pageViewController.dataSource = context.coordinator
        pageViewController.delegate = context.coordinator
        pageViewController.view.backgroundColor = .clear
        context.coordinator.attachScrollDelegate(to: pageViewController)
        context.coordinator.update(parent: self, in: pageViewController, forceRecenter: true)
        return pageViewController
    }

    func updateUIViewController(_ pageViewController: UIPageViewController, context: Context) {
        context.coordinator.update(parent: self, in: pageViewController, forceRecenter: false)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIScrollViewDelegate {
        private var parent: TodayPageController
        private var controllers: [Date: PageHostController] = [:]
        private var isTransitioning = false
        private var pendingPreviewDate: Date?
        private var isShowingPendingPreview = false
        private var isProgrammaticTransition = false
        private var lastBaseDate: Date?
        private var handledAnimationRequestID: UUID?

        init(parent: TodayPageController) {
            self.parent = parent
        }

        func attachScrollDelegate(to pageViewController: UIPageViewController) {
            pageViewController.view.subviews
                .compactMap { $0 as? UIScrollView }
                .forEach { $0.delegate = self }
        }

        func update(parent: TodayPageController, in pageViewController: UIPageViewController, forceRecenter: Bool) {
            let previousBaseDate = lastBaseDate
            self.parent = parent
            updateRootViews()

            let baseDateChanged = previousBaseDate.map { !$0.isSameDay(as: parent.baseDate) } ?? true
            lastBaseDate = parent.baseDate

            if handleAnimationRequest(in: pageViewController) {
                return
            }

            guard !isTransitioning else { return }
            guard forceRecenter || baseDateChanged else { return }
            if let currentDate = currentDate(in: pageViewController),
               currentDate.isSameDay(as: parent.baseDate) {
                return
            }

            pageViewController.setViewControllers(
                [controller(for: parent.baseDate)],
                direction: .forward,
                animated: false
            )
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let date = (viewController as? PageHostController)?.date,
                  let previousDate = Calendar.current.date(byAdding: .day, value: -1, to: date)
            else {
                return nil
            }
            return controller(for: previousDate)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let date = (viewController as? PageHostController)?.date,
                  let nextDate = Calendar.current.date(byAdding: .day, value: 1, to: date)
            else {
                return nil
            }
            return controller(for: nextDate)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isTransitioning = true
            guard let date = (pendingViewControllers.first as? PageHostController)?.date else { return }
            pendingPreviewDate = date
            isShowingPendingPreview = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isTransitioning, !isProgrammaticTransition, let pendingPreviewDate else { return }
            let width = scrollView.bounds.width
            guard width > 0 else { return }

            let progress = abs(scrollView.contentOffset.x - width) / width
            if progress >= 0.5 {
                guard !isShowingPendingPreview else { return }
                isShowingPendingPreview = true
                parent.onPreviewDate(pendingPreviewDate)
            } else {
                guard isShowingPendingPreview else { return }
                isShowingPendingPreview = false
                parent.onPreviewDate(parent.baseDate)
            }
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard !isProgrammaticTransition else { return }
            isTransitioning = false
            pendingPreviewDate = nil
            isShowingPendingPreview = false

            guard completed, let currentDate = currentDate(in: pageViewController) else {
                parent.onCancel()
                return
            }

            if currentDate.isSameDay(as: parent.baseDate) {
                parent.onCancel()
            } else {
                parent.onCommitDate(currentDate)
            }
        }

        private func handleAnimationRequest(in pageViewController: UIPageViewController) -> Bool {
            guard let request = parent.animationRequest,
                  handledAnimationRequestID != request.id else {
                return false
            }

            guard !isTransitioning else {
                return true
            }

            handledAnimationRequestID = request.id
            animate(to: request.targetDate, in: pageViewController)
            return true
        }

        private func animate(to targetDate: Date, in pageViewController: UIPageViewController) {
            let targetDate = dayKey(for: targetDate)
            let currentDate = currentDate(in: pageViewController).map(dayKey(for:)) ?? dayKey(for: parent.baseDate)

            guard !currentDate.isSameDay(as: targetDate) else {
                parent.onCommitDate(targetDate)
                return
            }

            let direction: UIPageViewController.NavigationDirection = targetDate < currentDate ? .reverse : .forward
            isTransitioning = true
            isProgrammaticTransition = true
            pendingPreviewDate = targetDate
            isShowingPendingPreview = true
            parent.onPreviewDate(targetDate)

            pageViewController.setViewControllers(
                [controller(for: targetDate)],
                direction: direction,
                animated: true
            ) { [weak self] completed in
                guard let self else { return }
                self.isTransitioning = false
                self.isProgrammaticTransition = false
                self.pendingPreviewDate = nil
                self.isShowingPendingPreview = false

                if completed {
                    self.parent.onCommitDate(targetDate)
                } else {
                    self.parent.onCancel()
                }
            }
        }

        private func currentDate(in pageViewController: UIPageViewController) -> Date? {
            (pageViewController.viewControllers?.first as? PageHostController)?.date
        }

        private func controller(for date: Date) -> PageHostController {
            let key = dayKey(for: date)
            if let controller = controllers[key] {
                return controller
            }

            let controller = PageHostController(
                date: key,
                rootView: pageView(for: key)
            )
            controller.view.backgroundColor = .clear
            controllers[key] = controller
            return controller
        }

        private func updateRootViews() {
            for (date, controller) in controllers {
                controller.rootView = pageView(for: date)
            }
        }

        private func pageView(for date: Date) -> AnyView {
            AnyView(
                TodayDoseList(date: date)
                    .environmentObject(parent.store)
            )
        }

        private func dayKey(for date: Date) -> Date {
            Calendar.current.startOfDay(for: date)
        }
    }

    final class PageHostController: UIHostingController<AnyView> {
        let date: Date

        init(date: Date, rootView: AnyView) {
            self.date = date
            super.init(rootView: rootView)
        }

        @available(*, unavailable)
        @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
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
                CloudBackedEmptyStateView(
                    loadState: store.loadState,
                    emptyTitle: "Na tento den nejsou naplánované dávky",
                    systemImage: "pills"
                )
                    .listRowBackground(Color.clear)
            } else {
                ForEach(doses) { dose in
                    DoseRow(dose: dose)
                }
            }
        }
        .refreshable {
            await store.reload(showSyncIndicator: false, forceFullRecovery: true)
        }
    }
}

private struct DoseRow: View {
    @EnvironmentObject private var store: MedicationStore
    @AppStorage(DoseActionSettings.actionLeadTimeMinutesKey) private var actionLeadTimeMinutes = DoseActionSettings.defaultActionLeadTimeMinutes
    @State private var showsSkipConfirmation = false
    @State private var showsUndoConfirmation = false
    @State private var showsStatusDetails = false
    var dose: GeneratedDose

    private var confirmation: DoseConfirmation? {
        store.confirmation(for: dose)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            rowContent(now: context.date)
        }
    }

    @ViewBuilder
    private func rowContent(now: Date) -> some View {
        let state = DoseBusinessRules.presentationState(
            for: dose,
            confirmation: confirmation,
            canRecordDose: store.canRecordDose(dose),
            now: now,
            actionLeadTimeMinutes: actionLeadTimeMinutes
        )

        VStack(alignment: .leading, spacing: state.showsActions || state.showsMemberWarning ? 12 : 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dose.timeLabel)
                        .font(.headline)
                        .foregroundStyle(state.isSubdued ? .secondary : .primary)
                    Text(dose.scheduledTime.label)
                        .font(.caption)
                        .foregroundStyle(state.isOverdueToday ? .red : .secondary)
                    if !state.showsActions && !state.showsMemberWarning {
                        doseStateIndicator
                            .padding(.top, 2)
                    }
                }
                .frame(width: 72, alignment: .leading)

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(dose.medicationName)
                                .font(.headline)
                                .foregroundStyle(state.isSubdued ? .secondary : .primary)
                            if dose.isShared {
                                Image(systemName: "person.2.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Sdílená dávka")
                            }
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

                    PillAmountVisualization(
                        amount: DoseAmountFormatter.value(from: dose.amount, for: dose.medicationForm),
                        medicationForm: dose.medicationForm,
                        isActiveDose: state.showsActions,
                        doseColor: state.isSubdued ? .secondary : .primary
                    )
                        .frame(width: 118, alignment: .trailing)
                        .accessibilityLabel("Dávka \(dose.amount)")
                }
                .accessibilityElement(children: .combine)

                Spacer()
            }

            if state.showsMemberWarning {
                Label("Nejdřív vyplň svoje jméno ve Skupině.", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } else if state.showsActions {
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
        .padding(.top, 8)
        .padding(.bottom, state.showsActions || state.showsMemberWarning ? 8 : 4)
        .transaction { transaction in
            transaction.animation = nil
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
        .confirmationDialog(
            "Opravdu vrátit stav dávky?",
            isPresented: $showsUndoConfirmation,
            titleVisibility: .visible
        ) {
            Button("Vrátit stav dávky", role: .destructive) {
                Task {
                    try? await store.undoConfirmation(for: dose)
                }
            }
            Button("Zrušit", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var doseStateIndicator: some View {
        if let confirmation {
            Button {
                showsStatusDetails = true
            } label: {
                Image(systemName: confirmation.status == .confirmed ? "checkmark.circle.fill" : "forward.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(confirmation.status == .confirmed ? .green : .secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsStatusDetails) {
                confirmationPopover(confirmation)
            }
            .accessibilityLabel(confirmation.status.label)
        } else {
            Circle()
                .stroke(
                    Color.secondary.opacity(0.55),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 3])
                )
                .frame(width: 17, height: 17)
                .frame(width: 20, height: 20)
                .accessibilityLabel("Dávka zatím není aktivní")
        }
    }

    private func confirmationPopover(_ confirmation: DoseConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                confirmation.status.label,
                systemImage: confirmation.status == .confirmed ? "checkmark.circle.fill" : "forward.circle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(confirmation.status == .confirmed ? .green : .secondary)

            Text("\(store.displayName(for: confirmation) ?? "Neznámý člen") v \(confirmation.timestamp.shortTimeLabel)")
            .font(.caption)
            .foregroundStyle(.secondary)

            Button {
                showsStatusDetails = false
                showsUndoConfirmation = true
            } label: {
                Text(confirmation.status == .confirmed ? "Zrušit podání" : "Zrušit přeskočení")
                    .font(.caption)
                    .underline()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(store.isSyncing)
        }
        .padding(14)
        .presentationCompactAdaptation(.popover)
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
