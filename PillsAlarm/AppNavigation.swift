import Combine
import Foundation

enum AppTab: Hashable {
    case today
    case plan
    case group
    case history
    case settings
}

@MainActor
final class AppNavigation: ObservableObject {
    static let shared = AppNavigation()

    @Published var selectedTab: AppTab = .today
    @Published private(set) var returnToTodayTrigger: UUID?

    func openToday() {
        // Keep the destination available even when the intent runs before ContentView exists.
        selectedTab = .today
        returnToTodayTrigger = UUID()
    }
}
