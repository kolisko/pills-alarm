import SwiftUI

@MainActor
final class CloudSyncCoordinator: ObservableObject {
    private var pendingReloadTask: Task<Void, Never>?
    private var isReloading = false
    private var needsReload = false
    private var completions: [() -> Void] = []

    func scheduleReload(
        store: MedicationStore,
        delayNanoseconds: UInt64 = 700_000_000,
        showSyncIndicator: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        if let completion {
            completions.append(completion)
        }

        needsReload = true
        pendingReloadTask?.cancel()
        pendingReloadTask = Task { [weak self, weak store] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)

            guard !Task.isCancelled, let self, let store else { return }
            await self.performReloadIfNeeded(store: store, showSyncIndicator: showSyncIndicator)
        }
    }

    private func performReloadIfNeeded(store: MedicationStore, showSyncIndicator: Bool) async {
        guard !isReloading else {
            needsReload = true
            return
        }

        isReloading = true
        repeat {
            needsReload = false
            await store.reload(showSyncIndicator: showSyncIndicator)
        } while needsReload
        isReloading = false

        let pendingCompletions = completions
        completions = []
        pendingCompletions.forEach { $0() }
    }
}

@main
struct PillsAlarmApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = MedicationStore()
    @StateObject private var cloudSync = CloudSyncCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .task {
#if DEBUG
#if targetEnvironment(simulator)
                    if CloudKitIntegrationRunner.isRequested {
                        await CloudKitIntegrationRunner.runAndWriteReport()
                        return
                    }
#endif
#endif

                    await store.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: .cloudKitDataDidChange)) { notification in
                    if let request = notification.object as? CloudKitRefreshRequest {
                        cloudSync.scheduleReload(store: store) {
                            request.complete(.newData)
                        }
                    } else {
                        cloudSync.scheduleReload(store: store)
                    }
                }
                .onChange(of: scenePhase) {
                    if scenePhase == .active {
                        cloudSync.scheduleReload(store: store, delayNanoseconds: 250_000_000)
                    }
                }
        }
    }
}
