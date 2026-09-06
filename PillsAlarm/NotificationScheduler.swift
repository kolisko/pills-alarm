import AlarmKit
import Combine
import Foundation
import SwiftUI
import UserNotifications
import PillCore

enum AlarmDeliveryMethod: String, CaseIterable, Identifiable {
    case localNotifications
    case alarmKit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localNotifications:
            return "Lokální notifikace"
        case .alarmKit:
            return "AlarmKit"
        }
    }
}

@MainActor
final class NotificationScheduler: ObservableObject {
    static let shared = NotificationScheduler()

    private let center = UNUserNotificationCenter.current()
    private var scheduleTask: Task<Void, Never>?

    @Published private(set) var lastScheduledCount = 0
    @Published private(set) var lastSchedulingDate: Date?
    @Published private(set) var lastSchedulingError: String?
    @Published private(set) var isChangingDeliveryMethod = false
    @Published private(set) var deliveryMethod: AlarmDeliveryMethod {
        didSet {
            UserDefaults.standard.set(deliveryMethod.rawValue, forKey: Self.deliveryMethodKey)
        }
    }
    @Published var alarmSettings: AlarmSettings {
        didSet {
            saveAlarmSettings()
        }
    }

    private static let maxPendingRequests = 60
    static let doseAlarmSoundName = "DoseAlarm.wav"
    static let doseAlarmDurationSeconds = 30
    private static let alarmSettingsKey = "alarmSettings.v1"
    private static let deliveryMethodKey = "alarmDeliveryMethod.v1"
    private static let alarmKitInfoKey = "alarmKitScheduledInfo.v1"

    private init() {
        alarmSettings = Self.loadAlarmSettings()
        deliveryMethod = Self.loadDeliveryMethod()
    }

    func requestAuthorizationIfNeeded() async {
        if deliveryMethod == .alarmKit, #available(iOS 26.0, *) {
            do {
                guard AlarmManager.shared.authorizationState == .notDetermined else { return }
                _ = try await AlarmManager.shared.requestAuthorization()
            } catch {
                lastSchedulingError = Self.userFacingMessage(for: error)
            }
            return
        }

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

    func selectDeliveryMethod(_ method: AlarmDeliveryMethod, store: MedicationStore) async {
        guard method != deliveryMethod, !isChangingDeliveryMethod else { return }

        isChangingDeliveryMethod = true
        defer { isChangingDeliveryMethod = false }

        guard await ensureAuthorization(for: method) else {
            lastSchedulingError = method == .alarmKit
                ? "AlarmKit není povolený. Způsob upozornění zůstal beze změny."
                : "Lokální notifikace nejsou povolené. Způsob upozornění zůstal beze změny."
            return
        }

        deliveryMethod = method
        rescheduleUpcomingDoses(store: store)
    }

    func rescheduleUpcomingDoses(store: MedicationStore) {
        let alarms = makeUpcomingDoseAlarms(store: store)
        let requestedMethod = deliveryMethod
        scheduleTask?.cancel()
        scheduleTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let scheduledCount: Int
                switch requestedMethod {
                case .localNotifications:
                    scheduledCount = try await self.scheduleLocalNotifications(alarms)
                    if #available(iOS 26.0, *) {
                        try? self.cancelAllAlarmKitAlarms()
                    }
                case .alarmKit:
                    guard #available(iOS 26.0, *) else {
                        throw AlarmSchedulingError.alarmKitUnavailable
                    }
                    guard AlarmManager.shared.authorizationState == .authorized else {
                        throw AlarmSchedulingError.alarmKitNotAuthorized
                    }
                    scheduledCount = try await self.scheduleAlarmKitAlarms(alarms)
                    self.center.removeAllPendingNotificationRequests()
                }

                self.lastScheduledCount = scheduledCount
                self.lastSchedulingDate = Date()
                self.lastSchedulingError = nil
            } catch is CancellationError {
            } catch {
                if requestedMethod == .alarmKit {
                    await self.fallbackToLocalNotifications(after: error, alarms: alarms)
                } else {
                    self.lastScheduledCount = 0
                    self.lastSchedulingDate = Date()
                    self.lastSchedulingError = Self.userFacingMessage(for: error)
                }
            }
        }
    }

    func pendingDoseAlarms() async -> [ScheduledAlarmInfo] {
        if deliveryMethod == .alarmKit, #available(iOS 26.0, *) {
            return pendingAlarmKitAlarms()
        }

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

    func alarmKitAuthorizationStatus() -> AlarmAuthorizationStatus {
        guard #available(iOS 26.0, *) else {
            return AlarmAuthorizationStatus(label: "Vyžaduje iOS 26", isUsable: false)
        }

        switch AlarmManager.shared.authorizationState {
        case .notDetermined:
            return AlarmAuthorizationStatus(label: "Nevyžádáno", isUsable: false)
        case .denied:
            return AlarmAuthorizationStatus(label: "Zakázáno", isUsable: false)
        case .authorized:
            return AlarmAuthorizationStatus(label: "Povoleno", isUsable: true)
        @unknown default:
            return AlarmAuthorizationStatus(label: "Neznámé", isUsable: false)
        }
    }

    private func makeUpcomingDoseAlarms(store: MedicationStore) -> [ScheduledDoseAlarm] {
        return AlarmSchedulingRules.upcomingAlarms(
            now: Date(),
            settings: alarmSettings,
            dosesForDate: { store.doses(on: $0) },
            confirmationForDose: { store.confirmation(for: $0) },
            calendar: .current
        )
        .prefix(Self.maxPendingRequests)
        .map { $0 }
    }

    private func scheduleLocalNotifications(_ alarms: [ScheduledDoseAlarm]) async throws -> Int {
        center.removeAllPendingNotificationRequests()
        var scheduledCount = 0

        for alarm in alarms {
            try Task.checkCancellation()
            let request = Self.notificationRequest(
                for: alarm.dose,
                scheduledDate: alarm.scheduledDate,
                repeatIndex: alarm.repeatIndex,
                calendar: .current
            )
            try await center.add(request)
            scheduledCount += 1
        }

        return scheduledCount
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

    private static func loadDeliveryMethod() -> AlarmDeliveryMethod {
        guard let rawValue = UserDefaults.standard.string(forKey: deliveryMethodKey),
              let method = AlarmDeliveryMethod(rawValue: rawValue) else {
            return .localNotifications
        }

        if method == .alarmKit, #unavailable(iOS 26.0) {
            return .localNotifications
        }
        return method
    }

    private func ensureAuthorization(for method: AlarmDeliveryMethod) async -> Bool {
        switch method {
        case .localNotifications:
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return true
            case .notDetermined:
                return (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) == true
            case .denied:
                return false
            @unknown default:
                return false
            }
        case .alarmKit:
            guard #available(iOS 26.0, *) else { return false }
            switch AlarmManager.shared.authorizationState {
            case .authorized:
                return true
            case .notDetermined:
                return (try? await AlarmManager.shared.requestAuthorization()) == .authorized
            case .denied:
                return false
            @unknown default:
                return false
            }
        }
    }

    @available(iOS 26.0, *)
    private func scheduleAlarmKitAlarms(_ alarms: [ScheduledDoseAlarm]) async throws -> Int {
        try cancelAllAlarmKitAlarms()
        var storedInfo: [StoredAlarmKitInfo] = []

        do {
            for alarm in alarms {
                try Task.checkCancellation()
                let id = UUID()
                let title = "\(alarm.dose.timeLabel): \(alarm.dose.medicationName)"
                let body = "Dávka \(alarm.dose.amount). Potvrďte podání ve skupině."
                let alert: AlarmPresentation.Alert
                if #available(iOS 26.1, *) {
                    alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title))
                } else {
                    alert = AlarmPresentation.Alert(
                        title: LocalizedStringResource(stringLiteral: title),
                        stopButton: AlarmButton(text: "Zastavit", textColor: .white, systemImageName: "stop.fill")
                    )
                }
                let presentation = AlarmPresentation(alert: alert)
                let attributes = AlarmAttributes(
                    presentation: presentation,
                    metadata: DoseAlarmMetadata(body: body),
                    tintColor: .teal
                )
                let configuration = AlarmManager.AlarmConfiguration.alarm(
                    schedule: .fixed(alarm.scheduledDate),
                    attributes: attributes,
                    sound: .named(Self.doseAlarmSoundName)
                )

                _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
                storedInfo.append(StoredAlarmKitInfo(id: id, title: title, body: body, scheduledDate: alarm.scheduledDate))
            }
        } catch {
            try? cancelAllAlarmKitAlarms()
            throw error
        }

        saveAlarmKitInfo(storedInfo)
        return storedInfo.count
    }

    @available(iOS 26.0, *)
    private func cancelAllAlarmKitAlarms() throws {
        for alarm in try AlarmManager.shared.alarms {
            try AlarmManager.shared.cancel(id: alarm.id)
        }
        UserDefaults.standard.removeObject(forKey: Self.alarmKitInfoKey)
    }

    @available(iOS 26.0, *)
    private func pendingAlarmKitAlarms() -> [ScheduledAlarmInfo] {
        let storedByID = Dictionary(uniqueKeysWithValues: loadAlarmKitInfo().map { ($0.id, $0) })
        guard let alarms = try? AlarmManager.shared.alarms else { return [] }

        return alarms.compactMap { alarm in
            guard case .fixed(let scheduledDate)? = alarm.schedule,
                  scheduledDate > Date() else {
                return nil
            }
            let stored = storedByID[alarm.id]
            return ScheduledAlarmInfo(
                id: alarm.id.uuidString,
                title: stored?.title ?? "AlarmKit alarm",
                body: stored?.body ?? "",
                scheduledDate: scheduledDate
            )
        }
        .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private func fallbackToLocalNotifications(after alarmKitError: Error, alarms: [ScheduledDoseAlarm]) async {
        if #available(iOS 26.0, *) {
            try? cancelAllAlarmKitAlarms()
        }
        deliveryMethod = .localNotifications

        do {
            lastScheduledCount = try await scheduleLocalNotifications(alarms)
            lastSchedulingError = "AlarmKit se nepodařilo naplánovat (\(Self.userFacingMessage(for: alarmKitError))). Byly obnoveny lokální notifikace."
        } catch {
            lastScheduledCount = 0
            lastSchedulingError = Self.userFacingMessage(for: error)
        }
        lastSchedulingDate = Date()
    }

    private func saveAlarmKitInfo(_ info: [StoredAlarmKitInfo]) {
        guard let data = try? JSONEncoder().encode(info) else { return }
        UserDefaults.standard.set(data, forKey: Self.alarmKitInfoKey)
    }

    private func loadAlarmKitInfo() -> [StoredAlarmKitInfo] {
        guard let data = UserDefaults.standard.data(forKey: Self.alarmKitInfoKey),
              let info = try? JSONDecoder().decode([StoredAlarmKitInfo].self, from: data) else {
            return []
        }
        return info
    }
}

private enum AlarmSchedulingError: LocalizedError {
    case alarmKitUnavailable
    case alarmKitNotAuthorized

    var errorDescription: String? {
        switch self {
        case .alarmKitUnavailable:
            return "AlarmKit vyžaduje iOS 26 nebo novější."
        case .alarmKitNotAuthorized:
            return "AlarmKit není povolený v systémovém nastavení."
        }
    }
}

@available(iOS 26.0, *)
private struct DoseAlarmMetadata: AlarmMetadata {
    var body: String
}

private struct StoredAlarmKitInfo: Codable {
    var id: UUID
    var title: String
    var body: String
    var scheduledDate: Date
}

struct AlarmAuthorizationStatus {
    var label: String
    var isUsable: Bool
}

struct ScheduledAlarmInfo: Identifiable, Hashable {
    var id: String
    var title: String
    var body: String
    var scheduledDate: Date
}
