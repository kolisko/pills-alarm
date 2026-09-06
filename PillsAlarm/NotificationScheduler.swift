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
    private static let testNotificationIdentifier = "pillcare-test-notification"
    private static let alarmKitTestID = UUID(uuidString: "E45F749D-5B66-4DC5-98C8-71BFCDF677C0")!

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
        let alarmGroups = makeUpcomingDoseAlarmGroups(store: store)
        let requestedMethod = deliveryMethod
        scheduleTask?.cancel()
        scheduleTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let scheduledCount: Int
                switch requestedMethod {
                case .localNotifications:
                    scheduledCount = try await self.scheduleLocalNotifications(alarmGroups)
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
                    scheduledCount = try await self.scheduleAlarmKitAlarms(alarmGroups)
                    self.center.removeAllPendingNotificationRequests()
                }

                self.lastScheduledCount = scheduledCount
                self.lastSchedulingDate = Date()
                self.lastSchedulingError = nil
            } catch is CancellationError {
            } catch {
                if requestedMethod == .alarmKit {
                    await self.fallbackToLocalNotifications(after: error, alarmGroups: alarmGroups)
                } else {
                    self.lastScheduledCount = 0
                    self.lastSchedulingDate = Date()
                    self.lastSchedulingError = Self.userFacingMessage(for: error)
                }
            }
        }
    }

    func scheduleTestAlarm() async throws -> Date {
        if let scheduleTask {
            await scheduleTask.value
        }

        let scheduledDate = Date().addingTimeInterval(60)
        switch deliveryMethod {
        case .localNotifications:
            guard await ensureAuthorization(for: .localNotifications) else {
                throw AlarmSchedulingError.localNotificationsNotAuthorized
            }
            try await scheduleLocalTestNotification(at: scheduledDate)
        case .alarmKit:
            guard #available(iOS 26.0, *) else {
                throw AlarmSchedulingError.alarmKitUnavailable
            }
            guard await ensureAuthorization(for: .alarmKit) else {
                throw AlarmSchedulingError.alarmKitNotAuthorized
            }
            try await scheduleAlarmKitTest(at: scheduledDate)
        }

        return scheduledDate
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

    private func makeUpcomingDoseAlarmGroups(store: MedicationStore) -> [ScheduledDoseAlarmGroup] {
        let alarms = AlarmSchedulingRules.upcomingAlarms(
            now: Date(),
            settings: alarmSettings,
            dosesForDate: { store.doses(on: $0) },
            confirmationForDose: { store.confirmation(for: $0) },
            calendar: .current
        )

        return AlarmSchedulingRules.groupedByMinute(alarms, calendar: .current)
            .prefix(Self.maxPendingRequests)
            .map { $0 }
    }

    private func scheduleLocalNotifications(_ alarmGroups: [ScheduledDoseAlarmGroup]) async throws -> Int {
        let pendingRequests = await center.pendingNotificationRequests()
        let doseRequestIDs = pendingRequests
            .map(\.identifier)
            .filter { $0 != Self.testNotificationIdentifier }
        center.removePendingNotificationRequests(withIdentifiers: doseRequestIDs)
        var scheduledCount = 0

        for alarmGroup in alarmGroups {
            try Task.checkCancellation()
            let request = Self.notificationRequest(for: alarmGroup, calendar: .current)
            try await center.add(request)
            scheduledCount += 1
        }

        return scheduledCount
    }

    private func scheduleLocalTestNotification(at scheduledDate: Date) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Test upozornění Pill Care"
        content.body = "Pokud vidíte a slyšíte toto upozornění, lokální notifikace fungují."
        content.sound = UNNotificationSound(named: UNNotificationSoundName(Self.doseAlarmSoundName))

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: scheduledDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.testNotificationIdentifier,
            content: content,
            trigger: trigger
        )
        try await center.add(request)
    }

    private static func notificationRequest(for alarmGroup: ScheduledDoseAlarmGroup, calendar: Calendar) -> UNNotificationRequest {
        let alarmContent = content(for: alarmGroup)
        let content = UNMutableNotificationContent()
        content.title = alarmContent.title
        content.body = alarmContent.body
        content.sound = UNNotificationSound(named: UNNotificationSoundName(Self.doseAlarmSoundName))
        content.badge = 1

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: alarmGroup.scheduledDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let timestamp = Int(alarmGroup.scheduledDate.timeIntervalSince1970)
        return UNNotificationRequest(identifier: "dose-alarm-group-\(timestamp)", content: content, trigger: trigger)
    }

    private static func content(for alarmGroup: ScheduledDoseAlarmGroup) -> (title: String, body: String) {
        guard let firstAlarm = alarmGroup.alarms.first else {
            return (
                title: "Připomínka léků",
                body: "Zkontrolujte naplánované dávky v aplikaci."
            )
        }

        guard alarmGroup.alarms.count > 1 else {
            let dose = firstAlarm.dose
            return (
                title: "\(dose.timeLabel): \(dose.medicationName)",
                body: "Dávka \(dose.amount). Potvrďte podání ve skupině."
            )
        }

        let medications = alarmGroup.alarms.map(\.dose)
        let uniqueMedicationNames = medications.reduce(into: [String]()) { names, dose in
            if !names.contains(dose.medicationName) {
                names.append(dose.medicationName)
            }
        }
        let count = uniqueMedicationNames.count
        let countLabel: String
        switch count {
        case 1:
            countLabel = "1 lék"
        case 2...4:
            countLabel = "\(count) léky"
        default:
            countLabel = "\(count) léků"
        }
        let details = medications
            .map { "\($0.medicationName): \($0.amount)" }
            .joined(separator: ", ")

        return (
            title: "Čas na \(countLabel)",
            body: "\(details). Potvrďte podání ve skupině."
        )
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
    private func scheduleAlarmKitAlarms(_ alarmGroups: [ScheduledDoseAlarmGroup]) async throws -> Int {
        let preservedTestInfo = try cancelDoseAlarmKitAlarmsPreservingTest()
        var storedInfo = preservedTestInfo
        var scheduledDoseIDs: [UUID] = []

        do {
            for alarmGroup in alarmGroups {
                try Task.checkCancellation()
                let id = UUID()
                let alarmContent = Self.content(for: alarmGroup)
                try await scheduleAlarmKitAlarm(
                    id: id,
                    title: alarmContent.title,
                    body: alarmContent.body,
                    at: alarmGroup.scheduledDate
                )
                scheduledDoseIDs.append(id)
                storedInfo.append(
                    StoredAlarmKitInfo(
                        id: id,
                        title: alarmContent.title,
                        body: alarmContent.body,
                        scheduledDate: alarmGroup.scheduledDate
                    )
                )
            }
        } catch {
            for id in scheduledDoseIDs {
                try? AlarmManager.shared.cancel(id: id)
            }
            saveAlarmKitInfo(preservedTestInfo)
            throw error
        }

        saveAlarmKitInfo(storedInfo)
        return storedInfo.count - preservedTestInfo.count
    }

    @available(iOS 26.0, *)
    private func scheduleAlarmKitTest(at scheduledDate: Date) async throws {
        try? AlarmManager.shared.cancel(id: Self.alarmKitTestID)

        var storedInfo = loadAlarmKitInfo().filter { $0.id != Self.alarmKitTestID }
        saveAlarmKitInfo(storedInfo)

        let title = "Test alarmu Pill Care"
        let body = "Pokud vidíte a slyšíte tento alarm, AlarmKit funguje."
        try await scheduleAlarmKitAlarm(
            id: Self.alarmKitTestID,
            title: title,
            body: body,
            at: scheduledDate
        )
        storedInfo.append(
            StoredAlarmKitInfo(
                id: Self.alarmKitTestID,
                title: title,
                body: body,
                scheduledDate: scheduledDate
            )
        )
        saveAlarmKitInfo(storedInfo)
    }

    @available(iOS 26.0, *)
    private func scheduleAlarmKitAlarm(id: UUID, title: String, body: String, at scheduledDate: Date) async throws {
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
            schedule: .fixed(scheduledDate),
            attributes: attributes,
            sound: .named(Self.doseAlarmSoundName)
        )

        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
    }

    @available(iOS 26.0, *)
    private func cancelDoseAlarmKitAlarmsPreservingTest() throws -> [StoredAlarmKitInfo] {
        let alarms = try AlarmManager.shared.alarms
        let activeIDs = Set(alarms.map(\.id))

        for alarm in alarms where alarm.id != Self.alarmKitTestID {
            try AlarmManager.shared.cancel(id: alarm.id)
        }

        return loadAlarmKitInfo().filter {
            $0.id == Self.alarmKitTestID && activeIDs.contains($0.id)
        }
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

    private func fallbackToLocalNotifications(
        after alarmKitError: Error,
        alarmGroups: [ScheduledDoseAlarmGroup]
    ) async {
        if #available(iOS 26.0, *) {
            try? cancelAllAlarmKitAlarms()
        }
        deliveryMethod = .localNotifications

        do {
            lastScheduledCount = try await scheduleLocalNotifications(alarmGroups)
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
    case localNotificationsNotAuthorized

    var errorDescription: String? {
        switch self {
        case .alarmKitUnavailable:
            return "AlarmKit vyžaduje iOS 26 nebo novější."
        case .alarmKitNotAuthorized:
            return "AlarmKit není povolený v systémovém nastavení."
        case .localNotificationsNotAuthorized:
            return "Lokální notifikace nejsou povolené v systémovém nastavení."
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
