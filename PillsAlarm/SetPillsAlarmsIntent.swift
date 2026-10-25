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
        try await AlarmControlDiagnostics.withIntentAttempt(enabled: !value, intent: "SetPillsAlarmsMutedIntent") {
            try await alarmIntent.perform()
        }
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
        try await AlarmControlDiagnostics.withIntentAttempt(enabled: value, intent: "SetPillsAlarmsIntent") {
            try await apply()
        }
        return .result()
    }

    @MainActor
    private func apply() async throws {
#if PILLS_CONTROL_EXTENSION
        // LiveActivityIntent routes execution to the app, which owns the AlarmKit alarms.
        AlarmControlDiagnostics.record(.wrongProcess)
        throw AlarmControlError.openAppFirst
#else
        try await NotificationScheduler.shared.setAlarmsEnabledAndWait(value) {
            let store = MedicationStore.shared
            AlarmControlDiagnostics.record(.plansBegin, fields: ["loadState": store.loadState.diagnosticName])
            defer {
                AlarmControlDiagnostics.record(.plansEnd, fields: ["loadState": store.loadState.diagnosticName,
                    "medications": "\(store.medicationItems.count)", "confirmations": "\(store.confirmations.count)"])
            }
            try await store.ensurePlansLoaded()
            return NotificationScheduler.shared.makeUpcomingDoseAlarmGroups(store: store)
        }
#endif
    }
}
