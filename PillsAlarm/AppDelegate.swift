import CloudKit
import UIKit

extension Notification.Name {
    static let cloudKitDataDidChange = Notification.Name("cloudKitDataDidChange")
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

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Task {
            do {
                try await MedicationStore.acceptShare(cloudKitShareMetadata)
                NotificationCenter.default.post(name: .cloudKitDataDidChange, object: CloudKitRefreshRequest())
            } catch {
                NotificationCenter.default.post(name: .cloudKitDataDidChange, object: error)
            }
        }
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
