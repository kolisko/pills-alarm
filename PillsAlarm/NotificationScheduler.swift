import Foundation
import UserNotifications

@MainActor
final class NotificationScheduler {
    static let shared = NotificationScheduler()

    private let center = UNUserNotificationCenter.current()

    private init() {}

    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            return
        }

        do {
            _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            assertionFailure("Notification permission failed: \(error)")
        }
    }

    func rescheduleUpcomingDoses(store: MedicationStore) {
        center.removeAllPendingNotificationRequests()

        let calendar = Calendar.current
        let now = Date()
        var requests: [UNNotificationRequest] = []

        for dayOffset in 0..<21 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let doses = store.doses(on: date)
            for dose in doses where dose.scheduledDate > now && store.confirmation(for: dose) == nil {
                let content = UNMutableNotificationContent()
                content.title = "\(dose.timeLabel): \(dose.medicationName)"
                content.body = "Dávka \(dose.amount). Potvrďte podání ve skupině."
                content.sound = .default
                content.badge = 1

                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: dose.scheduledDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                requests.append(UNNotificationRequest(identifier: dose.id, content: content, trigger: trigger))
            }
        }

        for request in requests.prefix(60) {
            center.add(request)
        }
    }
}
