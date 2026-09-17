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

    func testAlarmIntentStopsExactAlarmThenRoutesToToday() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit requires iOS 26") }
        let (scheduler, client) = makeFixture()
        let id = UUID()
        let otherAlertingID = UUID()
        let futureID = UUID()
        [id, otherAlertingID, futureID].forEach { client.addExisting(id: $0) }
        client.alertingIDs = [id, otherAlertingID]
        let navigation = AppNavigation()
        navigation.selectedTab = .settings
        let intent = OpenPillsAppIntent(alarmID: id)
        XCTAssertEqual(intent.alarmID, id.uuidString)
        try intent.openApp(using: scheduler, navigation: navigation)

        XCTAssertTrue(OpenPillsAppIntent.openAppWhenRun)
        XCTAssertFalse(OpenPillsAppIntent.isDiscoverable)
        XCTAssertEqual(navigation.selectedTab, .today)
        XCTAssertNotNil(navigation.returnToTodayTrigger)
        XCTAssertEqual(client.stopAttempts, [id])
        XCTAssertTrue(client.cancellationAttempts.isEmpty)
        XCTAssertEqual(Set(client.records.keys), [otherAlertingID, futureID])
        XCTAssertTrue(scheduler.alarmsEnabled)
        XCTAssertEqual(client.scheduleAttempts, 0)
    }

    func testOpenTestAlarmStopsOnlyTestAndRepeatedOpenIsHarmless() throws {
        let (scheduler, client) = makeFixture()
        let testID = NotificationScheduler.alarmKitTestID
        let futureID = UUID()
        [testID, futureID].forEach { client.addExisting(id: $0) }
        client.alertingIDs = [testID]
        try scheduler.stopOpenedAlarm(id: testID.uuidString)
        try scheduler.stopOpenedAlarm(id: testID.uuidString)
        XCTAssertEqual(client.stopAttempts, [testID])
        XCTAssertEqual(Set(client.records.keys), [futureID])
    }

    func testStaleActionCannotStopNewScheduledTestWithSameID() throws {
        let (scheduler, client) = makeFixture()
        client.addExisting(id: NotificationScheduler.alarmKitTestID)
        try scheduler.stopOpenedAlarm(id: NotificationScheduler.alarmKitTestID.uuidString)
        XCTAssertTrue(client.stopAttempts.isEmpty)
        XCTAssertEqual(client.records.count, 1)
    }

    func testMissingTargetDoesNotStopAnotherAlertingAlarm() throws {
        let (scheduler, client) = makeFixture()
        let other = UUID()
        client.addExisting(id: other)
        client.alertingIDs = [other]
        try scheduler.stopOpenedAlarm(id: UUID().uuidString)
        XCTAssertTrue(client.stopAttempts.isEmpty)
        XCTAssertEqual(Set(client.records.keys), [other])
    }

    func testLegacyIntentStopsOnlyUnambiguousAlertingAlarm() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit requires iOS 26") }
        let (scheduler, client) = makeFixture()
        let id = UUID()
        let future = UUID()
        [id, future].forEach { client.addExisting(id: $0) }
        client.alertingIDs = [id]
        let intent = OpenPillsAppIntent()
        XCTAssertNil(intent.alarmID)
        try intent.openApp(using: scheduler, navigation: AppNavigation())
        XCTAssertEqual(client.stopAttempts, [id])
        XCTAssertEqual(Set(client.records.keys), [future])
    }

    func testLegacyIntentDoesNotGuessBetweenSeveralAlertingAlarms() {
        let (scheduler, client) = makeFixture()
        let ids = [UUID(), UUID()]
        ids.forEach { client.addExisting(id: $0) }
        client.alertingIDs = Set(ids)
        XCTAssertThrowsError(try scheduler.stopOpenedAlarm(id: nil))
        XCTAssertTrue(client.stopAttempts.isEmpty)
        XCTAssertTrue(client.cancellationAttempts.isEmpty)
        XCTAssertEqual(client.records.count, 2)
    }

    func testInvalidIDDoesNotFallBackToAnotherAlarm() {
        let (scheduler, client) = makeFixture()
        let id = UUID()
        client.addExisting(id: id)
        client.alertingIDs = [id]
        XCTAssertThrowsError(try scheduler.stopOpenedAlarm(id: "invalid"))
        XCTAssertTrue(client.stopAttempts.isEmpty)
    }

    func testStopFailureCancelsOnlySameStillAlertingAlarm() throws {
        let (scheduler, client) = makeFixture()
        let id = UUID()
        let future = UUID()
        [id, future].forEach { client.addExisting(id: $0) }
        client.alertingIDs = [id]
        client.failStop = true
        try scheduler.stopOpenedAlarm(id: id.uuidString)
        XCTAssertEqual(client.stopAttempts, [id])
        XCTAssertEqual(client.cancellationAttempts, [id])
        XCTAssertEqual(Set(client.records.keys), [future])
    }

    func testAlarmDisappearingDuringStopIsAlreadyHandled() throws {
        let (scheduler, client) = makeFixture()
        let id = UUID()
        client.addExisting(id: id)
        client.alertingIDs = [id]
        client.failStop = true
        client.removeBeforeStopFailure = true
        try scheduler.stopOpenedAlarm(id: id.uuidString)
        XCTAssertTrue(client.cancellationAttempts.isEmpty)
        XCTAssertNil(scheduler.lastSchedulingError)
    }

    func testSystemFailureIsNotHiddenAndStillNavigatesToApp() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit requires iOS 26") }
        let (scheduler, client) = makeFixture()
        let id = UUID()
        client.addExisting(id: id)
        client.alertingIDs = [id]
        client.failStop = true
        client.failCancellationIDs = [id]
        let navigation = AppNavigation()
        navigation.selectedTab = .settings
        XCTAssertThrowsError(try OpenPillsAppIntent(alarmID: id).openApp(using: scheduler, navigation: navigation))
        XCTAssertNotNil(scheduler.lastSchedulingError)
        XCTAssertEqual(navigation.selectedTab, .today)
        XCTAssertNotNil(client.records[id])
    }

    func testLookupFailureDoesNotCancelAnyAlarm() {
        let (scheduler, client) = makeFixture()
        client.failAlarmLookup = true
        XCTAssertThrowsError(try scheduler.stopOpenedAlarm(id: UUID().uuidString))
        XCTAssertTrue(client.stopAttempts.isEmpty)
        XCTAssertTrue(client.cancellationAttempts.isEmpty)
        XCTAssertNotNil(scheduler.lastSchedulingError)
    }

    private func makeFixture() -> (NotificationScheduler, FakeAlarmKitClient) {
        let suite = "AlarmNavigationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: NotificationScheduler.alarmsEnabledKey)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let client = FakeAlarmKitClient()
        return (NotificationScheduler(defaults: defaults, alarmClient: client, removeLegacyNotifications: {}), client)
    }
}
