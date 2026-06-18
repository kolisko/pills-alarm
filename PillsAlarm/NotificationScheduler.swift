import Combine
import Foundation
import UserNotifications

@MainActor
final class NotificationScheduler: ObservableObject {
    static let shared = NotificationScheduler()

    private let center = UNUserNotificationCenter.current()
    private var scheduleTask: Task<Void, Never>?

    @Published private(set) var lastScheduledCount = 0
    @Published private(set) var lastSchedulingDate: Date?
    @Published private(set) var lastSchedulingError: String?
    @Published var alarmSettings: AlarmSettings {
        didSet {
            saveAlarmSettings()
        }
    }

    private static let maxPendingRequests = 60
    static let doseAlarmSoundName = "DoseAlarm.wav"
    static let doseAlarmDurationSeconds = 30
    private static let scheduleHorizonDays = 7
    private static let scheduleLookbackDays = 1
    private static let alarmSettingsKey = "alarmSettings.v1"

    private init() {
        alarmSettings = Self.loadAlarmSettings()
    }

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
        let requests = makeUpcomingDoseRequests(store: store)
        scheduleTask?.cancel()
        scheduleTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                self.center.removeAllPendingNotificationRequests()
                var scheduledCount = 0

                for request in requests.prefix(Self.maxPendingRequests) {
                    try Task.checkCancellation()
                    try await self.center.add(request)
                    scheduledCount += 1
                }

                self.lastScheduledCount = scheduledCount
                self.lastSchedulingDate = Date()
                self.lastSchedulingError = nil
            } catch is CancellationError {
            } catch {
                self.lastScheduledCount = 0
                self.lastSchedulingDate = Date()
                self.lastSchedulingError = Self.userFacingMessage(for: error)
            }
        }
    }

    func pendingDoseAlarms() async -> [ScheduledAlarmInfo] {
        let requests = await center.pendingNotificationRequests()
        return requests
            .compactMap { request -> ScheduledAlarmInfo? in
                guard let trigger = request.trigger as? UNCalendarNotificationTrigger,
                      let nextDate = trigger.nextTriggerDate() else {
                    return nil
                }

                return ScheduledAlarmInfo(
                    id: request.identifier,
                    title: request.content.title,
                    body: request.content.body,
                    scheduledDate: nextDate
                )
            }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    func notificationSettings() async -> UNNotificationSettings {
        await center.notificationSettings()
    }

    private func makeUpcomingDoseRequests(store: MedicationStore) -> [UNNotificationRequest] {
        let calendar = Calendar.current
        let now = Date()
        let settings = alarmSettings
        let repeatOffsets = settings.repeatOffsetsMinutes
        var schedulableDoses: [GeneratedDose] = []

        for dayOffset in -Self.scheduleLookbackDays..<Self.scheduleHorizonDays {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let doses = store.doses(on: date)
            for dose in doses where store.confirmation(for: dose) == nil {
                let hasFutureAlarm = repeatOffsets.contains { offset in
                    guard let scheduledDate = calendar.date(byAdding: .minute, value: offset, to: dose.scheduledDate) else {
                        return false
                    }

                    return scheduledDate > now
                }

                if hasFutureAlarm {
                    schedulableDoses.append(dose)
                }
            }
        }

        schedulableDoses.sort { $0.scheduledDate < $1.scheduledDate }
        let repeatingDoseIds = Set(schedulableDoses.prefix(settings.repeatingDoseLimit).map(\.id))

        return schedulableDoses.flatMap { dose in
            let offsets = repeatingDoseIds.contains(dose.id) ? repeatOffsets : [0]
            return offsets.enumerated().compactMap { index, offset -> UNNotificationRequest? in
                guard let scheduledDate = calendar.date(byAdding: .minute, value: offset, to: dose.scheduledDate),
                      scheduledDate > now else {
                    return nil
                }

                return Self.notificationRequest(for: dose, scheduledDate: scheduledDate, repeatIndex: index, calendar: calendar)
            }
        }
        .sorted { lhs, rhs in
            guard let leftDate = (lhs.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(),
                  let rightDate = (rhs.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() else {
                return lhs.identifier < rhs.identifier
            }
            return leftDate < rightDate
        }
    }

    private static func notificationRequest(for dose: GeneratedDose, scheduledDate: Date, repeatIndex: Int, calendar: Calendar) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "\(dose.timeLabel): \(dose.medicationName)"
        content.body = "Dávka \(dose.amount). Potvrďte podání ve skupině."
        content.sound = UNNotificationSound(named: UNNotificationSoundName(Self.doseAlarmSoundName))
        content.badge = 1

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: scheduledDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: "\(dose.id)-alarm-\(repeatIndex)", content: content, trigger: trigger)
    }

    private static func userFacingMessage(for error: Error) -> String {
        let nsError = error as NSError
        guard !nsError.localizedDescription.isEmpty else {
            return "Alarm se nepodařilo naplánovat."
        }

        return nsError.localizedDescription
    }

    private static func loadAlarmSettings() -> AlarmSettings {
        guard let data = UserDefaults.standard.data(forKey: alarmSettingsKey),
              let settings = try? JSONDecoder().decode(AlarmSettings.self, from: data) else {
            return .defaultValue
        }

        return settings.normalized
    }

    private func saveAlarmSettings() {
        guard let data = try? JSONEncoder().encode(alarmSettings.normalized) else { return }
        UserDefaults.standard.set(data, forKey: Self.alarmSettingsKey)
    }
}

struct ScheduledAlarmInfo: Identifiable, Hashable {
    var id: String
    var title: String
    var body: String
    var scheduledDate: Date
}

struct AlarmSettings: Codable, Equatable {
    var repeatIntervalMinutes: Int
    var repeatDurationMinutes: Int
    var repeatingDoseLimit: Int

    static let defaultValue = AlarmSettings(
        repeatIntervalMinutes: 15,
        repeatDurationMinutes: 120,
        repeatingDoseLimit: 2
    )

    var repeatOffsetsMinutes: [Int] {
        guard repeatIntervalMinutes > 0 else { return [0] }
        return Array(stride(from: 0, through: repeatDurationMinutes, by: repeatIntervalMinutes))
    }

    var normalized: AlarmSettings {
        AlarmSettings(
            repeatIntervalMinutes: min(max(repeatIntervalMinutes, 5), 60),
            repeatDurationMinutes: min(max(repeatDurationMinutes, 15), 240),
            repeatingDoseLimit: min(max(repeatingDoseLimit, 1), 5)
        )
    }
}
