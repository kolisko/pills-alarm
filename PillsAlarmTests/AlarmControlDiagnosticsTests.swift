import XCTest
@testable import PillsAlarm

@MainActor
final class AlarmControlDiagnosticsTests: XCTestCase {
    func testJournalSurvivesReopeningAndKeepsUnfinishedAttempt() throws {
        let directory = temporaryDirectory()
        let journal = AlarmDiagnosticJournal(directory: directory)
        let attempt = UUID()
        let start = event(stage: .intentBegin, attempt: attempt)
        let cloud = event(stage: .cloudBegin, attempt: attempt, offset: 1)
        journal.append(start)
        journal.append(cloud)

        let reopened = AlarmDiagnosticJournal(directory: directory).snapshot()
        XCTAssertEqual(reopened.events.map(\.id), [start.id, cloud.id])
        XCTAssertEqual(reopened.events.map(\.stage), [.intentBegin, .cloudBegin])
        XCTAssertTrue(reopened.events.allSatisfy { $0.attemptID == attempt })
        XCTAssertNil(reopened.storageError)
        XCTAssertTrue(reopened.report.contains("attempt=\(attempt)"))
    }

    func testJournalBoundsHistoryAndPreservesNewestEvents() {
        let journal = AlarmDiagnosticJournal(directory: temporaryDirectory(), maximumEvents: 3)
        let events = (0..<8).map { event(stage: .controlRead, offset: TimeInterval($0)) }
        events.forEach(journal.append)
        XCTAssertEqual(journal.snapshot().events.map(\.id), events.suffix(3).map(\.id))
    }

    func testSeparateWritersDoNotOverwriteEachOthersEvents() {
        let directory = temporaryDirectory()
        let first = AlarmDiagnosticJournal(directory: directory)
        let second = AlarmDiagnosticJournal(directory: directory)
        let events = (0..<40).map { event(stage: .controlRead, offset: TimeInterval($0)) }
        DispatchQueue.concurrentPerform(iterations: events.count) { index in
            (index.isMultiple(of: 2) ? first : second).append(events[index])
        }
        let snapshot = AlarmDiagnosticJournal(directory: directory).snapshot()
        XCTAssertEqual(Set(snapshot.events.map(\.id)), Set(events.map(\.id)))
        XCTAssertNil(snapshot.storageError)
    }

    func testCorruptEntryDoesNotHideOtherEvents() throws {
        let directory = temporaryDirectory()
        let journal = AlarmDiagnosticJournal(directory: directory)
        journal.append(event(stage: .appLaunch))
        try Data("invalid json".utf8).write(to: directory.appendingPathComponent("broken.json"))
        let snapshot = journal.snapshot()
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertNotNil(snapshot.storageError)
    }

    func testErrorReportDoesNotPersistDescriptionsOrRecordContents() {
        let underlying = NSError(domain: NSURLErrorDomain, code: -1001,
                                 userInfo: [NSLocalizedDescriptionKey: "Private medication dosage"])
        let error = NSError(domain: "CKErrorDomain", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Patient name and medication",
            NSUnderlyingErrorKey: underlying,
            "record": "Confidential record"
        ])
        XCTAssertEqual(AlarmControlDiagnostics.errorCode(error), "CKErrorDomain:4 <- NSURLErrorDomain:-1001")
    }

    func testFailedAttemptRemainsAfterLaterSuccessAndReopening() async {
        let directory = temporaryDirectory()
        let journal = AlarmDiagnosticJournal(directory: directory)
        await AlarmControlDiagnostics.$journalOverride.withValue(journal) {
            do {
                try await AlarmControlDiagnostics.withIntentAttempt(enabled: true, intent: "test") {
                    AlarmControlDiagnostics.record(.cloudBegin)
                    throw NSError(domain: "TestCloud", code: 42)
                }
                XCTFail("Original error must propagate")
            } catch {
                XCTAssertEqual((error as NSError).code, 42)
            }
            await AlarmControlDiagnostics.withIntentAttempt(enabled: false, intent: "test") {}
        }
        let events = AlarmDiagnosticJournal(directory: directory).snapshot().events
        XCTAssertEqual(events.filter { $0.stage == .intentFailed }.count, 1)
        XCTAssertEqual(events.filter { $0.stage == .intentSucceeded }.count, 1)
        XCTAssertEqual(Set(events.compactMap(\.attemptID)).count, 2)
    }

    func testTaskLocalContextPropagatesWithoutCreatingNestedAttempts() async throws {
        let journal = AlarmDiagnosticJournal(directory: temporaryDirectory())
        await AlarmControlDiagnostics.$journalOverride.withValue(journal) {
            await AlarmControlDiagnostics.withIntentAttempt(enabled: true, intent: "muted") {
                await AlarmControlDiagnostics.withIntentAttempt(enabled: true, intent: "legacy") {
                    await Task { AlarmControlDiagnostics.record(.schedulingBegin) }.value
                }
            }
        }
        let events = journal.snapshot().events
        XCTAssertEqual(events.map(\.stage), [.intentBegin, .schedulingBegin, .intentSucceeded])
        XCTAssertEqual(Set(events.compactMap(\.attemptID)).count, 1)
        XCTAssertNil(AlarmControlDiagnostics.attemptID)
    }

    func testUnavailableStorageCannotBreakIntent() async {
        let journal = AlarmDiagnosticJournal(directory: nil)
        let value = await AlarmControlDiagnostics.$journalOverride.withValue(journal) {
            await AlarmControlDiagnostics.withIntentAttempt(enabled: true, intent: "test") { 123 }
        }
        XCTAssertEqual(value, 123)
        XCTAssertNotNil(journal.snapshot().storageError)
    }

    func testTracedSchedulerFailureKeepsAlarmsOffAndLogsFailure() async {
        let defaults = isolatedDefaults()
        let client = FakeAlarmKitClient()
        client.authorizationStatus = .denied
        let scheduler = NotificationScheduler(defaults: defaults, alarmClient: client, removeLegacyNotifications: {})
        let journal = AlarmDiagnosticJournal(directory: temporaryDirectory())
        await AlarmControlDiagnostics.$journalOverride.withValue(journal) {
            do {
                try await AlarmControlDiagnostics.withIntentAttempt(enabled: true, intent: "test") {
                    try await scheduler.setAlarmsEnabledAndWait(true) {
                        XCTFail("Denied authorization must not load cloud plans")
                        return []
                    }
                }
                XCTFail("Must report denied authorization")
            } catch {}
        }
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
        XCTAssertEqual(journal.snapshot().events.map(\.stage), [.intentBegin, .authorizationBegin, .intentFailed])
    }

    func testTracedDisableDoesNotLoadCloudAndRecordsSystemCount() async throws {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: NotificationScheduler.alarmsEnabledKey)
        let client = FakeAlarmKitClient()
        client.addExisting(id: UUID())
        let scheduler = NotificationScheduler(defaults: defaults, alarmClient: client, removeLegacyNotifications: {})
        let journal = AlarmDiagnosticJournal(directory: temporaryDirectory())
        try await AlarmControlDiagnostics.$journalOverride.withValue(journal) {
            try await AlarmControlDiagnostics.withIntentAttempt(enabled: false, intent: "test") {
                try await scheduler.setAlarmsEnabledAndWait(false) {
                    XCTFail("Disabling must not load plans")
                    return []
                }
            }
        }
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
        let events = journal.snapshot().events
        XCTAssertEqual(events.last?.stage, .intentSucceeded)
        XCTAssertEqual(events.first { $0.stage == .schedulingEnd }?.fields["systemCount"], "0")
        XCTAssertFalse(events.contains { $0.stage == .authorizationBegin || $0.stage == .cloudBegin })
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AlarmDiagnosticsTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "AlarmDiagnosticsTests.\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func event(stage: AlarmDiagnosticStage, attempt: UUID? = nil, offset: TimeInterval = 0) -> AlarmDiagnosticEvent {
        AlarmDiagnosticEvent(id: UUID(), date: Date(timeIntervalSince1970: 1_800_000_000 + offset), processSeconds: offset,
            processSession: UUID(), processID: 123, bundleID: "test.bundle", version: "test", processRole: "app",
            attemptID: attempt, stage: stage, fields: [:])
    }
}
