import AppIntents
import Foundation

@available(iOS 26.0, *)
struct OpenPillsAppIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Otevřít Pills"
    static let openAppWhenRun: Bool = true
    static let isDiscoverable: Bool = false

    @Parameter(title: "Alarm")
    var alarmID: String?

    init() {}

    init(alarmID: UUID) {
        self.alarmID = alarmID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try openApp(using: .shared, navigation: .shared)
        return .result()
    }

    @MainActor
    func openApp(using scheduler: NotificationScheduler, navigation: AppNavigation) throws {
        defer { navigation.openToday() }
        try scheduler.stopOpenedAlarm(id: alarmID)
    }
}
