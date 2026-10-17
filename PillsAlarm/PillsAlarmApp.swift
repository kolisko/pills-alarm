import Network
import SwiftUI
import PillCore

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
    private var needsFullRecovery = false
    private var completions: [() -> Void] = []
    private let reloadStore: @MainActor (MedicationStore, Bool, Bool) async -> Void
    private let waitForAlarms: @MainActor () async -> Void

    init(
        reloadStore: @escaping @MainActor (MedicationStore, Bool, Bool) async -> Void = { store, showIndicator, fullRecovery in
            await store.reload(showSyncIndicator: showIndicator, forceFullRecovery: fullRecovery)
        },
        waitForAlarms: @escaping @MainActor () async -> Void = {
            await NotificationScheduler.shared.waitForPendingOperations()
        }
    ) {
        self.reloadStore = reloadStore
        self.waitForAlarms = waitForAlarms
    }

    func scheduleReload(
        store: MedicationStore,
        delayNanoseconds: UInt64 = 700_000_000,
        showSyncIndicator: Bool = true,
        forceFullRecovery: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        if let completion {
            completions.append(completion)
        }

        needsReload = true
        needsFullRecovery = needsFullRecovery || forceFullRecovery
        // The active reload loop will consume this request; don't cancel it or enqueue it twice.
        guard !isReloading else { return }
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
            let forceFullRecovery = needsFullRecovery
            needsFullRecovery = false
            await reloadStore(store, showSyncIndicator, forceFullRecovery)
        } while needsReload
        isReloading = false

        // The cloud request is complete only after the latest alarm pass has finished too.
        // Release the cloud reload gate first so a newer update can replace stale alarm work.
        await waitForAlarms()
        guard !isReloading, !needsReload else { return }

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
                    // The benchmark owns AlarmKit fixtures; startup must not reschedule over them.
                    if ProcessInfo.processInfo.environment["PILLCARE_ALARM_BENCHMARK"] == "1" {
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
#if DEBUG
#if targetEnvironment(simulator)
                    if ProcessInfo.processInfo.environment["PILLCARE_ALARM_BENCHMARK"] == "1" { return }
#endif
#endif
                    if scenePhase == .active {
                        NotificationScheduler.shared.restoreAlarmState()
                        cloudSync.startPeriodicReload(store: store, intervalMinutes: autoRefreshIntervalMinutes)
                        cloudSync.scheduleReload(store: store, delayNanoseconds: 250_000_000, forceFullRecovery: true)
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
                    cloudSync.scheduleReload(store: store, delayNanoseconds: 250_000_000, showSyncIndicator: false, forceFullRecovery: true)
                }
        }
    }
}
