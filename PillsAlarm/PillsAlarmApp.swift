import Network
import SwiftUI

final class NetworkStatusMonitor: ObservableObject, @unchecked Sendable {
    @Published private(set) var isConnected = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "PillCareNetworkStatusMonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

@MainActor
final class CloudSyncCoordinator: ObservableObject {
    private var pendingReloadTask: Task<Void, Never>?
    private var periodicReloadTask: Task<Void, Never>?
    private var periodicReloadIntervalMinutes: Int?
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

    func startPeriodicReload(store: MedicationStore, intervalMinutes: Int) {
        let normalizedIntervalMinutes = SyncSettings.normalizedAutoRefreshIntervalMinutes(intervalMinutes)
        if periodicReloadTask != nil, periodicReloadIntervalMinutes == normalizedIntervalMinutes {
            return
        }

        stopPeriodicReload()
        periodicReloadIntervalMinutes = normalizedIntervalMinutes
        let intervalNanoseconds = UInt64(normalizedIntervalMinutes) * 60 * 1_000_000_000

        periodicReloadTask = Task { [weak self, weak store] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                guard !Task.isCancelled, let self, let store else { return }
                self.scheduleReload(store: store, showSyncIndicator: false)
            }
        }
    }

    func stopPeriodicReload() {
        periodicReloadTask?.cancel()
        periodicReloadTask = nil
        periodicReloadIntervalMinutes = nil
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

enum SyncSettings {
    static let autoRefreshIntervalMinutesKey = "sync.autoRefreshIntervalMinutes.v1"
    static let defaultAutoRefreshIntervalMinutes = 5
    static let minimumAutoRefreshIntervalMinutes = 1
    static let maximumAutoRefreshIntervalMinutes = 60

    static func normalizedAutoRefreshIntervalMinutes(_ value: Int) -> Int {
        min(max(value, minimumAutoRefreshIntervalMinutes), maximumAutoRefreshIntervalMinutes)
    }
}

@main
struct PillsAlarmApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SyncSettings.autoRefreshIntervalMinutesKey) private var autoRefreshIntervalMinutes = SyncSettings.defaultAutoRefreshIntervalMinutes
    @StateObject private var store = MedicationStore()
    @StateObject private var cloudSync = CloudSyncCoordinator()
    @StateObject private var networkStatus = NetworkStatusMonitor()

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
                    cloudSync.startPeriodicReload(store: store, intervalMinutes: autoRefreshIntervalMinutes)
                }
                .onReceive(NotificationCenter.default.publisher(for: .cloudKitDataDidChange)) { notification in
                    if let request = notification.object as? CloudKitRefreshRequest {
                        cloudSync.scheduleReload(store: store) {
                            request.complete(.newData)
                        }
                    } else if let error = notification.object as? Error {
                        store.reportSyncError(error)
                    } else {
                        cloudSync.scheduleReload(store: store)
                    }
                }
                .onChange(of: scenePhase) {
                    if scenePhase == .active {
                        cloudSync.startPeriodicReload(store: store, intervalMinutes: autoRefreshIntervalMinutes)
                        cloudSync.scheduleReload(store: store, delayNanoseconds: 250_000_000)
                    } else {
                        cloudSync.stopPeriodicReload()
                    }
                }
                .onChange(of: autoRefreshIntervalMinutes) {
                    guard scenePhase == .active else { return }
                    cloudSync.startPeriodicReload(store: store, intervalMinutes: autoRefreshIntervalMinutes)
                }
                .onChange(of: networkStatus.isConnected) { _, isConnected in
                    guard isConnected, scenePhase == .active else { return }
                    cloudSync.scheduleReload(store: store, delayNanoseconds: 250_000_000, showSyncIndicator: false)
                }
        }
    }
}
