import SwiftUI

@main
struct PillsAlarmApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = MedicationStore()

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
                .onReceive(NotificationCenter.default.publisher(for: .cloudKitDataDidChange)) { _ in
                    Task {
                        await store.reload()
                    }
                }
                .onChange(of: scenePhase) {
                    if scenePhase == .active {
                        Task {
                            await store.reload()
                        }
                    }
                }
        }
    }
}
