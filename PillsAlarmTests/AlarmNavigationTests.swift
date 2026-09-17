import AppIntents
import XCTest
@testable import PillsAlarm

@MainActor
final class AlarmNavigationTests: XCTestCase {
    func testOrdinaryLaunchStartsOnTodayWithoutAnAlarmRequest() {
        let navigation = AppNavigation()
        XCTAssertEqual(navigation.selectedTab, .today)
        XCTAssertNil(navigation.returnToTodayTrigger)
    }

    func testOpenAlarmFromEveryTabSelectsTodayAndRequestsActualDate() {
        for tab in [AppTab.today, .plan, .group, .history, .settings] {
            let navigation = AppNavigation()
            navigation.selectedTab = tab
            navigation.openToday()
            XCTAssertEqual(navigation.selectedTab, .today)
            XCTAssertNotNil(navigation.returnToTodayTrigger)
        }
    }

    func testOpenRequestIsRetainedBeforeAnyViewSubscribes() {
        let navigation = AppNavigation()
        navigation.openToday()
        let request = navigation.returnToTodayTrigger

        XCTAssertNotNil(request)
        XCTAssertEqual(navigation.selectedTab, .today)
        XCTAssertEqual(navigation.returnToTodayTrigger, request)
    }

    func testRepeatedOpenRequestsResetTheDateEvenOnTodayTab() {
        let navigation = AppNavigation()
        navigation.openToday()
        let firstRequest = navigation.returnToTodayTrigger
        navigation.openToday()

        XCTAssertEqual(navigation.selectedTab, .today)
        XCTAssertNotEqual(navigation.returnToTodayTrigger, firstRequest)
    }

    func testAlarmIntentRequestsForegroundAndRoutesToToday() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit requires iOS 26") }
        let navigation = AppNavigation.shared
        let previousTab = navigation.selectedTab
        defer { navigation.selectedTab = previousTab }
        navigation.selectedTab = .settings
        let previousRequest = navigation.returnToTodayTrigger

        _ = try await OpenPillsAppIntent().perform()

        XCTAssertTrue(OpenPillsAppIntent.openAppWhenRun)
        XCTAssertFalse(OpenPillsAppIntent.isDiscoverable)
        XCTAssertEqual(navigation.selectedTab, .today)
        XCTAssertNotEqual(navigation.returnToTodayTrigger, previousRequest)
    }
}
