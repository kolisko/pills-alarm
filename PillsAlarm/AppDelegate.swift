import CloudKit
import UIKit
import UserNotifications

extension Notification.Name {
    static let cloudKitDataDidChange = Notification.Name("cloudKitDataDidChange")
    static let cloudKitShareDidAccept = Notification.Name("cloudKitShareDidAccept")
}

final class CloudKitRefreshRequest {
    private var completionHandler: ((UIBackgroundFetchResult) -> Void)?

    init(completionHandler: ((UIBackgroundFetchResult) -> Void)? = nil) {
        self.completionHandler = completionHandler
    }

    func complete(_ result: UIBackgroundFetchResult) {
        guard let completionHandler else { return }
        self.completionHandler = nil
        completionHandler(result)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        CloudKitShareAcceptanceHandler.accept(cloudKitShareMetadata)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            completionHandler(.noData)
            return
        }

        let request = CloudKitRefreshRequest(completionHandler: completionHandler)
        NotificationCenter.default.post(name: .cloudKitDataDidChange, object: request)

        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            request.complete(.noData)
        }
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            CloudKitShareAcceptanceHandler.accept(metadata)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        CloudKitShareAcceptanceHandler.accept(cloudKitShareMetadata)
    }
}

private enum CloudKitShareAcceptanceHandler {
    static func accept(_ cloudKitShareMetadata: CKShare.Metadata) {
        Task {
            do {
                try await MedicationStore.acceptShare(cloudKitShareMetadata)
                NotificationCenter.default.post(name: .cloudKitShareDidAccept, object: nil)
                NotificationCenter.default.post(name: .cloudKitDataDidChange, object: CloudKitRefreshRequest())
            } catch {
                NotificationCenter.default.post(name: .cloudKitDataDidChange, object: error)
            }
        }
    }
}
