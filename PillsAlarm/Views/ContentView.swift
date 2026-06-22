import SwiftUI
import UIKit
import PillCore

struct ContentView: View {
    @EnvironmentObject private var store: MedicationStore
    @State private var selectedTab: AppTab = .today
    @State private var todayReturnToTodayTrigger: UUID?

    var body: some View {
        Group {
            if case .requiresICloudAccount(let message) = store.loadState {
                ICloudAccountRequiredView(message: message)
                    .environmentObject(store)
            } else {
                appTabs
                    .overlay(alignment: .top) {
                        SyncOverlay()
                            .environmentObject(store)
                    }
                    .sheet(isPresented: workspaceSelectionBinding) {
                        WorkspaceSelectionView()
                            .environmentObject(store)
                            .interactiveDismissDisabled(true)
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .cloudKitShareDidAccept)) { _ in
                        selectedTab = .group
                    }
            }
        }
    }

    private var workspaceSelectionBinding: Binding<Bool> {
        Binding {
            !store.workspaceCandidates.isEmpty
        } set: { _ in }
    }

    private var appTabs: some View {
        TabView(selection: $selectedTab) {
            TodayView(returnToTodayTrigger: todayReturnToTodayTrigger)
                .background {
                    TabBarReselectGestureObserver(selectedTab: selectedTab, observedTab: .today) {
                        todayReturnToTodayTrigger = UUID()
                    }
                }
                .tabItem {
                    Label("Dnes", systemImage: "checklist")
                }
                .tag(AppTab.today)

            PlanView()
                .tabItem {
                    Label("Plán", systemImage: "calendar.badge.clock")
                }
                .tag(AppTab.plan)

            GroupView()
                .tabItem {
                    Label("Skupina", systemImage: "person.3")
                }
                .tag(AppTab.group)

            HistoryView()
                .tabItem {
                    Label("Historie", systemImage: "clock.arrow.circlepath")
                }
                .tag(AppTab.history)

            SettingsView()
                .tabItem {
                    Label("Nastavení", systemImage: "gearshape")
                }
                .tag(AppTab.settings)
        }
        .tint(.teal)
        .onChange(of: store.medications) {
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: store)
        }
        .onChange(of: store.confirmations) {
            NotificationScheduler.shared.rescheduleUpcomingDoses(store: store)
        }
    }
}

private enum AppTab: Hashable {
    case today
    case plan
    case group
    case history
    case settings
}

private struct TabBarReselectGestureObserver: UIViewControllerRepresentable {
    var selectedTab: AppTab
    var observedTab: AppTab
    var onReselect: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isHidden = true
        controller.view.isUserInteractionEnabled = false

        context.coordinator.scheduleAttach(from: controller)

        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.scheduleAttach(from: uiViewController)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TabBarReselectGestureObserver
        private weak var tabBar: UITabBar?
        private weak var tapRecognizer: UITapGestureRecognizer?

        init(parent: TabBarReselectGestureObserver) {
            self.parent = parent
        }

        func scheduleAttach(from viewController: UIViewController, attempts: Int = 8) {
            DispatchQueue.main.async { [weak self, weak viewController] in
                guard let self, let viewController else { return }
                if self.attach(from: viewController) || attempts <= 1 { return }
                self.scheduleAttach(from: viewController, attempts: attempts - 1)
            }
        }

        @discardableResult
        func attach(from viewController: UIViewController) -> Bool {
            guard let tabBar = viewController.tabBarController?.tabBar else { return false }
            guard self.tabBar !== tabBar else { return true }

            if let tapRecognizer {
                self.tabBar?.removeGestureRecognizer(tapRecognizer)
            }

            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            tabBar.addGestureRecognizer(recognizer)

            self.tabBar = tabBar
            self.tapRecognizer = recognizer
            return true
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  parent.selectedTab == parent.observedTab,
                  let tabBar = recognizer.view as? UITabBar,
                  let selectedIndex = selectedIndex(in: tabBar, at: recognizer.location(in: tabBar)),
                  AppTab(tabIndex: selectedIndex) == parent.observedTab
            else {
                return
            }

            parent.onReselect()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        private func selectedIndex(in tabBar: UITabBar, at location: CGPoint) -> Int? {
            guard let itemCount = tabBar.items?.count, itemCount > 0 else { return nil }
            let itemWidth = tabBar.bounds.width / CGFloat(itemCount)
            guard itemWidth > 0 else { return nil }

            let index = Int(location.x / itemWidth)
            guard index >= 0 && index < itemCount else { return nil }
            return index
        }
    }
}

private extension AppTab {
    var tabIndex: Int {
        switch self {
        case .today: 0
        case .plan: 1
        case .group: 2
        case .history: 3
        case .settings: 4
        }
    }

    init?(tabIndex: Int) {
        switch tabIndex {
        case 0: self = .today
        case 1: self = .plan
        case 2: self = .group
        case 3: self = .history
        case 4: self = .settings
        default: return nil
        }
    }
}

private struct SyncOverlay: View {
    @EnvironmentObject private var store: MedicationStore

    var body: some View {
        VStack(spacing: 8) {
            if store.isSyncing {
                SyncLine()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if let message = store.syncErrorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.18), value: store.isSyncing)
        .animation(.easeInOut(duration: 0.18), value: store.syncErrorMessage)
    }
}

private struct SyncLine: View {
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.teal.opacity(0.12))
                Rectangle()
                    .fill(.teal.opacity(0.65))
                    .frame(width: max(80, proxy.size.width * 0.28))
                    .offset(x: isAnimating ? proxy.size.width : -max(80, proxy.size.width * 0.28))
            }
            .onAppear {
                isAnimating = true
            }
            .animation(.linear(duration: 1.15).repeatForever(autoreverses: false), value: isAnimating)
        }
        .frame(height: 2)
    }
}

private struct WorkspaceSelectionView: View {
    @EnvironmentObject private var store: MedicationStore
    @State private var pendingDelete: WorkspaceCandidate?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Aplikace našla více možných úložišť v iCloudu. Vyber to správné, aby se znovu zobrazil tvůj plán.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Nalezená úložiště") {
                    ForEach(store.workspaceCandidates) { candidate in
                        Button {
                            Task { await store.selectWorkspace(candidate) }
                        } label: {
                            WorkspaceCandidateRow(candidate: candidate)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        guard let index = offsets.first else { return }
                        let candidate = store.workspaceCandidates[index]
                        guard !candidate.isActive else { return }
                        pendingDelete = candidate
                    }
                }
            }
            .navigationTitle("Vyber úložiště")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                pendingDelete?.canDeleteFromCloud == true ? "Smazat úložiště?" : "Odebrat ze seznamu?",
                isPresented: Binding {
                    pendingDelete != nil
                } set: { isPresented in
                    if !isPresented {
                        pendingDelete = nil
                    }
                },
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { candidate in
                Button(candidate.canDeleteFromCloud ? "Smazat úložiště" : "Odebrat ze seznamu", role: .destructive) {
                    Task {
                        await store.deleteWorkspaceCandidate(candidate)
                        pendingDelete = nil
                    }
                }
                Button("Zrušit", role: .cancel) {
                    pendingDelete = nil
                }
            } message: { candidate in
                Text("\(candidate.name): \(candidate.medicationCount) léků, \(candidate.memberCount) členů, \(candidate.confirmationCount) záznamů historie.")
            }
        }
    }
}

private struct WorkspaceCandidateRow: View {
    var candidate: WorkspaceCandidate

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: candidate.typeLabel == "Sdílené" ? "person.2.fill" : "externaldrive.fill")
                .foregroundStyle(.teal)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(candidate.name)
                        .font(.headline)
                    if candidate.isActive {
                        StatusBadge(text: "aktivní", systemImage: "checkmark.circle.fill", tint: .teal)
                    }
                }

                Text("\(candidate.medicationCount) léků · \(candidate.memberCount) členů · \(candidate.confirmationCount) záznamů historie")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(candidate.typeLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct ICloudAccountRequiredView: View {
    @EnvironmentObject private var store: MedicationStore
    @State private var isRetrying = false
    @State private var retryMessage: String?
    var message: String

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 28) {
                Spacer(minLength: 36)

                Image(systemName: "icloud.slash")
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundStyle(.teal)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Přihlášení k iCloudu")
                        .font(.largeTitle.bold())
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Label("Otevři Nastavení", systemImage: "gear")
                    Label("Přihlas se k Apple účtu a zapni iCloud", systemImage: "person.crop.circle.badge.checkmark")
                    Label("Vrať se sem a zkus ověření znovu", systemImage: "arrow.clockwise")
                }
                .font(.headline)

                Button {
                    retryMessage = nil
                    isRetrying = true
                    Task {
                        await store.reload()
                        isRetrying = false

                        if case .requiresICloudAccount = store.loadState {
                            retryMessage = "Ověření doběhlo, ale iCloud ještě není připravený. Chvíli počkej a zkus to znovu."
                        }
                    }
                } label: {
                    if isRetrying || store.isSyncing {
                        HStack {
                            ProgressView()
                                .tint(.white)
                            Text("Ověřuji iCloud")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Zkusit znovu", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.teal)
                .disabled(isRetrying || store.isSyncing)

                if let retryMessage {
                    Label(retryMessage, systemImage: "info.circle")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .padding(28)
            .navigationTitle("iCloud")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
