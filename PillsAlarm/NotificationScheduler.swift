import AlarmKit
import Combine
import Foundation
import SwiftUI
import UserNotifications
import PillCore

@MainActor
final class NotificationScheduler: ObservableObject {
    static let shared = NotificationScheduler()

    private let defaults: UserDefaults
    private let alarmClient: any AlarmKitScheduling
    private let removeLegacyNotifications: @MainActor () -> Void
    private var pendingOperation: Task<Void, Error>?
    private var operationID = UUID()

    @Published private(set) var lastScheduledCount = 0
    @Published private(set) var lastSchedulingDate: Date?
    @Published private(set) var lastSchedulingError: String?
    @Published private(set) var isChangingAlarmState = false
    @Published private(set) var alarmsEnabled: Bool {
        didSet {
            defaults.set(alarmsEnabled, forKey: Self.alarmsEnabledKey)
        }
    }
    @Published var alarmSettings: AlarmSettings {
        didSet {
            guard let data = try? JSONEncoder().encode(alarmSettings.normalized) else { return }
            defaults.set(data, forKey: Self.alarmSettingsKey)
        }
    }

    private static let maxPendingRequests = 60
    static let doseAlarmSoundName = "DoseAlarm.wav"
    static let doseAlarmDurationSeconds = 30
    private static let alarmSettingsKey = "alarmSettings.v1"
    static let alarmsEnabledKey = "alarmKitEnabled.v1"
    private static let legacyDeliveryMethodKey = "alarmDeliveryMethod.v1"
    private static let alarmKitInfoKey = "alarmKitScheduledInfo.v1"
    static let alarmKitTestID = UUID(uuidString: "E45F749D-5B66-4DC5-98C8-71BFCDF677C0")!

    init(
        defaults: UserDefaults = .standard,
        alarmClient: (any AlarmKitScheduling)? = nil,
        removeLegacyNotifications: (@MainActor () -> Void)? = nil
    ) {
        self.defaults = defaults
        let client = alarmClient ?? SystemAlarmKitClient()
        self.alarmClient = client
        self.removeLegacyNotifications = removeLegacyNotifications ?? {
            let center = UNUserNotificationCenter.current()
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
            Task { try? await center.setBadgeCount(0) }
        }
        if let data = defaults.data(forKey: Self.alarmSettingsKey),
           let settings = try? JSONDecoder().decode(AlarmSettings.self, from: data) {
            alarmSettings = settings.normalized
        } else {
            alarmSettings = .defaultValue
        }
        let savedEnabled = defaults.object(forKey: Self.alarmsEnabledKey) as? Bool
        alarmsEnabled = client.isAvailable && (savedEnabled
            ?? (defaults.string(forKey: Self.legacyDeliveryMethodKey) == "alarmKit"))
        defaults.set(alarmsEnabled, forKey: Self.alarmsEnabledKey)
        defaults.removeObject(forKey: Self.legacyDeliveryMethodKey)
    }

    var isAlarmKitAvailable: Bool { alarmClient.isAvailable }

    func restoreAlarmState() {
        removeLegacyNotifications()
        if !alarmsEnabled {
            rescheduleAlarmGroups([])
        }
    }

    func requestAuthorizationIfNeeded() async {
        guard alarmsEnabled else { return }
        do {
            try await ensureAuthorization()
        } catch {
            lastSchedulingError = error.localizedDescription
        }
    }

    func setAlarmsEnabled(_ enabled: Bool, store: MedicationStore) async {
        await setAlarmsEnabled(enabled) { self.makeUpcomingDoseAlarmGroups(store: store) }
    }

    func setAlarmsEnabled(
        _ enabled: Bool,
        alarmGroups: @MainActor () -> [ScheduledDoseAlarmGroup]
    ) async {
        guard !isChangingAlarmState else { return }
        isChangingAlarmState = true
        defer { isChangingAlarmState = false }

        removeLegacyNotifications()
        if enabled {
            do {
                try await ensureAuthorization()
            } catch {
                lastSchedulingError = error.localizedDescription
                return
            }
        }

        // Persist off before waiting for any in-flight request or cloud refresh.
        alarmsEnabled = enabled
        rescheduleAlarmGroups(enabled ? alarmGroups() : [])
        await waitForPendingOperations()
    }

    func rescheduleUpcomingDoses(store: MedicationStore) {
        rescheduleAlarmGroups(alarmsEnabled ? makeUpcomingDoseAlarmGroups(store: store) : [])
    }

    @discardableResult
    func rescheduleAlarmGroups(_ alarmGroups: [ScheduledDoseAlarmGroup]) -> Task<Void, Error> {
        removeLegacyNotifications()
        return enqueueOperation {
            guard self.alarmsEnabled else {
                try self.cancelAllAlarmKitAlarms()
                self.lastScheduledCount = 0
                return
            }
            try self.checkSchedulingAllowed()
            self.lastScheduledCount = try await self.scheduleAlarmKitAlarms(alarmGroups)
        }
    }

    func scheduleTestAlarm() async throws -> Date {
        guard alarmsEnabled else { throw AlarmSchedulingError.alarmsDisabled }
        var scheduledDate = Date()
        let operation = enqueueOperation(cancelPrevious: false) {
            try self.checkSchedulingAllowed()
            scheduledDate = Date().addingTimeInterval(60)
            try await self.scheduleAlarmKitTest(at: scheduledDate)
        }
        try await operation.value
        return scheduledDate
    }

    func waitForPendingOperations() async {
        while let operation = pendingOperation {
            let id = operationID
            _ = await operation.result
            if id == operationID { return }
        }
    }

    func pendingDoseAlarms() async -> [ScheduledAlarmInfo] {
        await waitForPendingOperations()
        let storedByID = Dictionary(loadAlarmKitInfo().map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        do {
            return try alarmClient.alarms().compactMap { alarm in
                guard let scheduledDate = alarm.scheduledDate, scheduledDate > Date() else { return nil }
                let stored = storedByID[alarm.id]
                return ScheduledAlarmInfo(
                    id: alarm.id.uuidString,
                    title: stored?.title ?? "AlarmKit alarm",
                    body: stored?.body ?? "",
                    scheduledDate: scheduledDate
                )
            }.sorted { $0.scheduledDate < $1.scheduledDate }
        } catch {
            lastSchedulingError = error.localizedDescription
            return []
        }
    }

    func alarmKitAuthorizationStatus() -> AlarmAuthorizationStatus {
        alarmClient.authorizationStatus
    }

    private func enqueueOperation(
        cancelPrevious: Bool = true,
        _ operation: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Error> {
        let previous = pendingOperation
        if cancelPrevious { previous?.cancel() }
        let id = UUID()
        operationID = id

        // Cancellation alone cannot stop an AlarmKit call already awaiting its reply.
        // Drain the previous operation before starting replacements or cancelling all alarms.
        let task = Task { @MainActor in
            _ = await previous?.result
            try Task.checkCancellation()
            do {
                try await operation()
                try Task.checkCancellation()
                if self.operationID == id {
                    self.lastSchedulingDate = Date()
                    self.lastSchedulingError = nil
                }
            } catch {
                if !(error is CancellationError), self.operationID == id {
                    self.lastScheduledCount = (try? self.alarmClient.alarms().filter { $0.id != Self.alarmKitTestID }.count) ?? 0
                    self.lastSchedulingDate = Date()
                    self.lastSchedulingError = error.localizedDescription
                }
                throw error
            }
        }
        pendingOperation = task
        return task
    }

    private func ensureAuthorization() async throws {
        guard alarmClient.isAvailable else { throw AlarmSchedulingError.alarmKitUnavailable }
        guard try await alarmClient.requestAuthorization() else { throw AlarmSchedulingError.alarmKitNotAuthorized }
    }

    private func checkSchedulingAllowed() throws {
        try Task.checkCancellation()
        guard alarmsEnabled else { throw AlarmSchedulingError.alarmsDisabled }
        guard alarmClient.isAvailable else { throw AlarmSchedulingError.alarmKitUnavailable }
        guard alarmClient.authorizationStatus.isUsable else { throw AlarmSchedulingError.alarmKitNotAuthorized }
    }

    private func makeUpcomingDoseAlarmGroups(store: MedicationStore) -> [ScheduledDoseAlarmGroup] {
        let alarms = AlarmSchedulingRules.upcomingAlarms(
            now: Date(),
            settings: alarmSettings,
            dosesForDate: { store.doses(on: $0) },
            confirmationForDose: { store.confirmation(for: $0) },
            calendar: .current
        )
        return Array(AlarmSchedulingRules.groupedByMinute(alarms, calendar: .current).prefix(Self.maxPendingRequests))
    }

    private static func content(for alarmGroup: ScheduledDoseAlarmGroup) -> (title: String, body: String) {
        guard let firstAlarm = alarmGroup.alarms.first else {
            return ("Připomínka léků", "Zkontrolujte naplánované dávky v aplikaci.")
        }
        guard alarmGroup.alarms.count > 1 else {
            let dose = firstAlarm.dose
            return ("\(dose.timeLabel): \(dose.medicationName)", "Dávka \(dose.amount). Potvrďte podání ve skupině.")
        }
        let count = alarmGroup.medicationCount
        let countLabel: String
        switch count {
        case 1: countLabel = "1 lék"
        case 2...4: countLabel = "\(count) léky"
        default: countLabel = "\(count) léků"
        }
        let details = alarmGroup.alarms.map { "\($0.dose.medicationName): \($0.dose.amount)" }.joined(separator: ", ")
        return ("Čas na \(countLabel)", "\(details). Potvrďte podání ve skupině.")
    }

    private func scheduleAlarmKitAlarms(_ alarmGroups: [ScheduledDoseAlarmGroup]) async throws -> Int {
        let alarms = try alarmClient.alarms()
        try cancelAlarms(alarms.filter { $0.id != Self.alarmKitTestID })
        let preservedTestInfo = loadAlarmKitInfo().filter { info in
            info.id == Self.alarmKitTestID && alarms.contains { $0.id == info.id }
        }
        var storedInfo = preservedTestInfo
        var scheduledIDs: [UUID] = []
        do {
            for group in alarmGroups {
                try checkSchedulingAllowed()
                let content = Self.content(for: group)
                let info = StoredAlarmKitInfo(id: UUID(), title: content.title, body: content.body, scheduledDate: group.scheduledDate)
                try await alarmClient.schedule(info)
                scheduledIDs.append(info.id)
                try checkSchedulingAllowed()
                storedInfo.append(info)
            }
        } catch {
            for id in scheduledIDs { try? alarmClient.cancel(id: id) }
            saveAlarmKitInfo(preservedTestInfo)
            throw error
        }
        saveAlarmKitInfo(storedInfo)
        return scheduledIDs.count
    }

    private func scheduleAlarmKitTest(at scheduledDate: Date) async throws {
        let existing = try alarmClient.alarms().filter { $0.id == Self.alarmKitTestID }
        try cancelAlarms(existing)
        var storedInfo = loadAlarmKitInfo().filter { $0.id != Self.alarmKitTestID }
        saveAlarmKitInfo(storedInfo)
        let info = StoredAlarmKitInfo(
            id: Self.alarmKitTestID, title: "Test alarmu Pill Care",
            body: "Pokud vidíte a slyšíte tento alarm, AlarmKit funguje.", scheduledDate: scheduledDate
        )
        try await alarmClient.schedule(info)
        do {
            try checkSchedulingAllowed()
        } catch {
            try? alarmClient.cancel(id: info.id)
            throw error
        }
        storedInfo.append(info)
        saveAlarmKitInfo(storedInfo)
    }

    private func cancelAlarms(_ alarms: [AlarmKitAlarm]) throws {
        var firstError: Error?
        for alarm in alarms {
            do { try alarmClient.cancel(id: alarm.id) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private func cancelAllAlarmKitAlarms() throws {
        try cancelAlarms(alarmClient.alarms())
        defaults.removeObject(forKey: Self.alarmKitInfoKey)
    }

    private func saveAlarmKitInfo(_ info: [StoredAlarmKitInfo]) {
        guard let data = try? JSONEncoder().encode(info) else { return }
        defaults.set(data, forKey: Self.alarmKitInfoKey)
    }

    private func loadAlarmKitInfo() -> [StoredAlarmKitInfo] {
        guard let data = defaults.data(forKey: Self.alarmKitInfoKey),
              let info = try? JSONDecoder().decode([StoredAlarmKitInfo].self, from: data) else { return [] }
        return info
    }
}

@MainActor
protocol AlarmKitScheduling {
    var isAvailable: Bool { get }
    var authorizationStatus: AlarmAuthorizationStatus { get }
    func requestAuthorization() async throws -> Bool
    func alarms() throws -> [AlarmKitAlarm]
    func schedule(_ info: StoredAlarmKitInfo) async throws
    func cancel(id: UUID) throws
}

@MainActor
private final class SystemAlarmKitClient: AlarmKitScheduling {
    var isAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    var authorizationStatus: AlarmAuthorizationStatus {
        guard #available(iOS 26.0, *) else { return .unavailable }
        switch AlarmManager.shared.authorizationState {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .unknown
        }
    }

    func requestAuthorization() async throws -> Bool {
        guard #available(iOS 26.0, *) else { throw AlarmSchedulingError.alarmKitUnavailable }
        if AlarmManager.shared.authorizationState == .notDetermined {
            return try await AlarmManager.shared.requestAuthorization() == .authorized
        }
        return AlarmManager.shared.authorizationState == .authorized
    }

    func alarms() throws -> [AlarmKitAlarm] {
        guard #available(iOS 26.0, *) else { return [] }
        return try AlarmManager.shared.alarms.map { alarm in
            let date: Date?
            if case .fixed(let scheduledDate)? = alarm.schedule { date = scheduledDate }
            else { date = nil }
            return AlarmKitAlarm(id: alarm.id, scheduledDate: date)
        }
    }

    func cancel(id: UUID) throws {
        guard #available(iOS 26.0, *) else { return }
        try AlarmManager.shared.cancel(id: id)
    }

    func schedule(_ info: StoredAlarmKitInfo) async throws {
        guard #available(iOS 26.0, *) else { throw AlarmSchedulingError.alarmKitUnavailable }
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: info.title))
        } else {
            alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: info.title),
                stopButton: AlarmButton(text: "Zastavit", textColor: .white, systemImageName: "stop.fill")
            )
        }
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: DoseAlarmMetadata(body: info.body), tintColor: .teal
        )
        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule: .fixed(info.scheduledDate), attributes: attributes,
            sound: .named(NotificationScheduler.doseAlarmSoundName)
        )
        _ = try await AlarmManager.shared.schedule(id: info.id, configuration: configuration)
    }
}

private enum AlarmSchedulingError: LocalizedError {
    case alarmsDisabled
    case alarmKitUnavailable
    case alarmKitNotAuthorized

    var errorDescription: String? {
        switch self {
        case .alarmsDisabled: "Alarmy jsou vypnuté."
        case .alarmKitUnavailable: "AlarmKit vyžaduje iOS 26 nebo novější."
        case .alarmKitNotAuthorized: "AlarmKit není povolený v systémovém nastavení."
        }
    }
}

@available(iOS 26.0, *)
private struct DoseAlarmMetadata: AlarmMetadata {
    var body: String
}

struct StoredAlarmKitInfo: Codable, Sendable {
    var id: UUID
    var title: String
    var body: String
    var scheduledDate: Date
}

struct AlarmKitAlarm {
    var id: UUID
    var scheduledDate: Date?
}

enum AlarmAuthorizationStatus {
    case notDetermined, denied, authorized, unavailable, unknown

    var isUsable: Bool { self == .authorized }

    var label: String {
        switch self {
        case .notDetermined: "Nevyžádáno"
        case .denied: "Zakázáno"
        case .authorized: "Povoleno"
        case .unavailable: "Vyžaduje iOS 26"
        case .unknown: "Neznámé"
        }
    }
}

struct ScheduledAlarmInfo: Identifiable, Hashable {
    var id: String
    var title: String
    var body: String
    var scheduledDate: Date
}
