import CloudKit
import SwiftUI
import UIKit

struct CloudSharingView: UIViewControllerRepresentable {
    let controller: CloudSharingController

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let sharingController = UICloudSharingController { _, completion in
            Task { @MainActor in
                do {
                    let share = try await controller.cloud.prepareShare(
                        groupRecord: controller.groupRecord,
                        database: controller.database,
                        title: controller.title
                    )
                    completion(share, CKContainer(identifier: CloudKitRepository.containerIdentifier), nil)
                } catch {
                    completion(nil, nil, error)
                }
            }
        }
        sharingController.delegate = context.coordinator
        sharingController.availablePermissions = [.allowReadWrite, .allowPrivate]
        return sharingController
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Pill Care"
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            NotificationCenter.default.post(name: .cloudKitDataDidChange, object: nil)
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            NotificationCenter.default.post(name: .cloudKitDataDidChange, object: nil)
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            NotificationCenter.default.post(name: .cloudKitDataDidChange, object: error)
        }
    }
}
