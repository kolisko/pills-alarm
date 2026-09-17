import AppIntents

@available(iOS 26.0, *)
struct OpenPillsAppIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Otevřít Pills"
    static let openAppWhenRun: Bool = true
    static let isDiscoverable: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppNavigation.shared.openToday()
        return .result()
    }
}
