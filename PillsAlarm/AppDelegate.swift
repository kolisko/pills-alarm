import CloudKit
import UIKit

extension Notification.Name {
    static let cloudKitDataDidChange = Notification.Name("cloudKitDataDidChange")
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Task {
            do {
                try await MedicationStore.acceptShare(cloudKitShareMetadata)
                NotificationCenter.default.post(name: .cloudKitDataDidChange, object: nil)
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

        NotificationCenter.default.post(name: .cloudKitDataDidChange, object: nil)
        completionHandler(.newData)
    }
}
