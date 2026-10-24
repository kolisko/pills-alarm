import AppIntents

@available(iOS 26.0, *)
struct SetPillsAlarmsMutedIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Ztlumit alarmy Pills"
    static let isDiscoverable = false
    static let openAppWhenRun = false
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Ztlumeno")
    var value: Bool

    init() {}

    init(value: Bool) { self.value = value }

    var alarmIntent: SetPillsAlarmsIntent { SetPillsAlarmsIntent(value: !value) }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await alarmIntent.perform()
    }
}

// Preserve the enabled-value contract for actions iOS may still have cached from earlier versions.
@available(iOS 26.0, *)
struct SetPillsAlarmsIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Alarmy Pills"
    static let isDiscoverable = false
    static let openAppWhenRun = false
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Zapnuto")
    var value: Bool

    init() {}

    init(value: Bool) { self.value = value }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await apply()
        return .result()
    }

    @MainActor
    private func apply() async throws {
#if PILLS_CONTROL_EXTENSION
        // LiveActivityIntent routes execution to the app, which owns the AlarmKit alarms.
        throw AlarmControlError.openAppFirst
#else
        try await NotificationScheduler.shared.setAlarmsEnabledAndWait(value) {
            let store = MedicationStore.shared
            if store.loadState != .ready {
                await store.reload(showSyncIndicator: false)
            }
            guard store.loadState == .ready else { throw AlarmControlError.plansUnavailable }
            return NotificationScheduler.shared.makeUpcomingDoseAlarmGroups(store: store)
        }
#endif
    }
}
