import AlarmKit
import XCTest
import PillCore
import UIKit
@testable import PillsAlarm

@MainActor
final class AlarmControlTests: XCTestCase {
    func testControlSymbolsAreBundledAndHaveDistinctStates() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let controls = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("PillsAlarmControls.appex")))
        let on = try XCTUnwrap(UIImage(named: "PillsAlarmsOn", in: controls, compatibleWith: nil))
        let off = try XCTUnwrap(UIImage(named: "PillsAlarmsOff", in: controls, compatibleWith: nil))
        let pending = try XCTUnwrap(UIImage(named: "PillsAlarmsPending", in: controls, compatibleWith: nil))
        XCTAssertTrue(on.isSymbolImage)
        XCTAssertTrue(off.isSymbolImage)
        XCTAssertTrue(pending.isSymbolImage)
        let weights: [UIImage.SymbolWeight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        let scales: [UIImage.SymbolScale] = [.small, .medium, .large]
        for size: CGFloat in [20, 32, 64] {
            for weight in weights {
                for scale in scales {
                    let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: weight, scale: scale)
                    let onImage = try XCTUnwrap(on.applyingSymbolConfiguration(configuration))
                    XCTAssertTrue(onImage.isSymbolImage)
                    XCTAssertGreaterThan(onImage.size.width, 0)
                    let onAlignment = CGRect(origin: .zero, size: onImage.size).inset(by: onImage.alignmentRectInsets)
                    let pixel = 1 / onImage.scale
                    var renderedStates = Set<Data>([try XCTUnwrap(onImage.pngData())])
                    for symbol in [off, pending] {
                        let image = try XCTUnwrap(symbol.applyingSymbolConfiguration(configuration))
                        XCTAssertTrue(image.isSymbolImage)
                        XCTAssertGreaterThan(image.size.height, 0)
                        XCTAssertEqual(onImage.size.width, image.size.width, accuracy: 0.5)
                        XCTAssertEqual(onImage.size.height, image.size.height, accuracy: 0.5)
                        let alignment = CGRect(origin: .zero, size: image.size).inset(by: image.alignmentRectInsets)
                        XCTAssertEqual(onAlignment.minX, alignment.minX, accuracy: pixel)
                        XCTAssertEqual(onAlignment.minY, alignment.minY, accuracy: pixel)
                        XCTAssertEqual(onAlignment.width, alignment.width, accuracy: pixel)
                        XCTAssertEqual(onAlignment.height, alignment.height, accuracy: pixel)
                        // Exclude the lower-right bell from the tablet's optical alignment.
                        XCTAssertGreaterThan(image.alignmentRectInsets.right, image.alignmentRectInsets.left)
                        XCTAssertLessThan(image.alignmentRectInsets.top, image.alignmentRectInsets.bottom)
                        XCTAssertTrue(renderedStates.insert(try XCTUnwrap(image.pngData())).inserted,
                                      "Every control state must have a distinct symbol")
                    }
                }
            }
        }
        let preview = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 360)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 360))
            for (row, size) in [CGFloat(20), 32, 64].enumerated() {
                for (column, symbol) in [on, off, pending].enumerated() {
                    let image = symbol.applyingSymbolConfiguration(.init(pointSize: size, weight: .regular))!
                        .withTintColor(.white, renderingMode: .alwaysOriginal)
                    let alignment = CGRect(origin: .zero, size: image.size).inset(by: image.alignmentRectInsets)
                    image.draw(at: CGPoint(x: CGFloat(column * 160 + 70) - alignment.midX,
                                           y: CGFloat(row * 120 + 50) - alignment.midY))
                }
            }
        }
        let attachment = XCTAttachment(image: preview)
        attachment.name = "Control symbols - on, off, pending at 20, 32, 64 pt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMissingControlStateDoesNotPretendAlarmsAreOff() {
        let defaults = isolatedDefaults()
        XCTAssertThrowsError(try AlarmControlState.currentValue(defaults: defaults))
        defaults.set(true, forKey: AlarmControlState.enabledKey)
        XCTAssertEqual(try AlarmControlState.currentValue(defaults: defaults), true)
        defaults.set(false, forKey: AlarmControlState.enabledKey)
        XCTAssertEqual(try AlarmControlState.currentValue(defaults: defaults), false)
    }

    func testMuteControlInvertsOnlyTheIntentValue() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires AlarmKit") }
        XCTAssertFalse(SetPillsAlarmsMutedIntent(value: true).alarmIntent.value)
        XCTAssertTrue(SetPillsAlarmsMutedIntent(value: false).alarmIntent.value)
        XCTAssertTrue(SetPillsAlarmsIntent(value: true).value)
        XCTAssertFalse(SetPillsAlarmsIntent(value: false).value)
    }

    func testRecoverySymbolExists() {
        XCTAssertNotNil(UIImage(systemName: "exclamationmark.arrow.triangle.2.circlepath"))
    }

    func testNativeOptimisticToggleShowsPendingInsteadOfUnconfirmedSuccess() {
        for enabled in [false, true] {
            let state = AlarmControlSnapshot(enabled: enabled)
            XCTAssertNil(state.pendingTarget(isMuted: !enabled))
            XCTAssertEqual(state.displayedStatus(isMuted: !enabled), enabled ? "Zapnuté" : "Vypnuté")
            XCTAssertEqual(state.pendingTarget(isMuted: enabled), !enabled)
            XCTAssertEqual(state.displayedStatus(isMuted: enabled), enabled ? "Vypínání…" : "Zapínání…")
            let running = AlarmControlSnapshot(enabled: enabled,
                change: .init(id: UUID(), requestedEnabled: !enabled, startedAt: Date()))
            for isMuted in [false, true] {
                XCTAssertEqual(running.pendingTarget(isMuted: isMuted), !enabled)
                XCTAssertEqual(running.displayedStatus(isMuted: isMuted), enabled ? "Vypínání…" : "Zapínání…")
            }
        }
    }

    func testSnapshotAdoptsLegacyStateAndDoesNotReloadOnUnchangedStartup() throws {
        for enabled in [false, true] {
            let defaults = isolatedDefaults()
            defaults.set(enabled, forKey: AlarmControlState.enabledKey)
            var reloads = 0
            let store = controlStore(defaults: defaults) { reloads += 1 }
            XCTAssertEqual(try store.snapshot(), AlarmControlSnapshot(enabled: enabled))
            store.publish(enabled)
            store.publish(enabled)
            XCTAssertEqual(reloads, 0)
            store.publish(!enabled)
            XCTAssertEqual(reloads, 1)
            XCTAssertEqual(try store.snapshot().enabled, !enabled)
        }
    }

    func testPendingStateRetainsConfirmedValueAndSurvivesStartupPublication() throws {
        for enabled in [false, true] {
            var reloads = 0
            let store = controlStore { reloads += 1 }
            store.publish(enabled)
            let lease = try store.beginChange(to: !enabled, currentEnabled: enabled)
            let pending = try store.snapshot()
            XCTAssertTrue(pending.isChanging)
            XCTAssertEqual(pending.enabled, enabled)
            XCTAssertEqual(pending.change?.requestedEnabled, !enabled)
            XCTAssertEqual(pending.status, enabled ? "Vypínání…" : "Zapínání…")
            XCTAssertEqual(reloads, 2, "Pending must refresh even though the confirmed Bool did not change")
            store.publish(enabled)
            store.publish(!enabled)
            XCTAssertEqual(try store.snapshot(), pending)
            XCTAssertEqual(reloads, 2, "Neither startup nor scheduling may overwrite the active operation")
            store.finishChange(lease, enabled: !enabled)
            XCTAssertEqual(try store.snapshot(), AlarmControlSnapshot(enabled: !enabled))
            XCTAssertEqual(reloads, 3)
        }
    }

    func testOperationLockRejectsDuplicateFromAnotherStore() throws {
        let defaults = isolatedDefaults()
        let url = isolatedLockURL()
        let app = AlarmControlStateStore(defaults: defaults, lockURL: url, reload: {})
        let other = AlarmControlStateStore(defaults: defaults, lockURL: url, reload: {})
        let lease = try app.beginChange(to: true, currentEnabled: false)
        XCTAssertEqual(try app.snapshot(), try other.snapshot())
        XCTAssertThrowsError(try other.beginChange(to: false, currentEnabled: false)) { error in
            XCTAssertEqual(error.localizedDescription, AlarmControlError.changeInProgress.localizedDescription)
        }
        try withExtendedLifetime(lease) { XCTAssertTrue(try other.snapshot().isChanging) }
    }

    func testAbandonedOperationBecomesRetryableWithoutOverwritingSnapshot() throws {
        let defaults = isolatedDefaults()
        let store = controlStore(defaults: defaults)
        var lease: AlarmControlStateStore.ChangeLease? = try store.beginChange(to: true, currentEnabled: false)
        XCTAssertNotNil(lease)
        XCTAssertTrue(try store.snapshot().isChanging)
        let saved = defaults.data(forKey: AlarmControlStateStore.snapshotKey)
        lease = nil // Models the file descriptor being closed when the app process exits.
        let abandoned = try store.snapshot()
        XCTAssertFalse(abandoned.isChanging)
        XCTAssertFalse(abandoned.enabled)
        XCTAssertTrue(abandoned.needsRecovery)
        XCTAssertEqual(abandoned.status, "Změna nedokončena")
        XCTAssertEqual(saved, defaults.data(forKey: AlarmControlStateStore.snapshotKey), "Provider recovery is read-only")
        let retry = try store.beginChange(to: true, currentEnabled: false)
        XCTAssertTrue(try store.snapshot().isChanging)
        store.finishChange(retry, enabled: true)
        XCTAssertEqual(try store.snapshot(), AlarmControlSnapshot(enabled: true))
    }

    func testStartupReconcilesAbandonedOperationWithPersistedPreference() throws {
        for enabled in [false, true] {
            let store = controlStore()
            var lease: AlarmControlStateStore.ChangeLease? = try store.beginChange(to: true, currentEnabled: false)
            XCTAssertNotNil(lease)
            lease = nil
            store.publish(enabled)
            XCTAssertEqual(try store.snapshot(), AlarmControlSnapshot(enabled: enabled))
        }
    }

    func testStalePendingDisplayDoesNotClaimSuccessOrAllowOverlappingExecution() throws {
        let store = controlStore()
        let now = Date()
        let lease = try store.beginChange(to: true, currentEnabled: false, now: now)
        for date in [now.addingTimeInterval(120), now.addingTimeInterval(-1)] {
            let stale = try store.snapshot(now: date)
            XCTAssertFalse(stale.isChanging)
            XCTAssertFalse(stale.enabled)
            XCTAssertTrue(stale.needsRecovery)
        }
        XCTAssertThrowsError(try store.beginChange(to: true, currentEnabled: false))
        store.finishChange(lease, enabled: false)
        XCTAssertFalse(try store.snapshot().needsRecovery)
    }

    func testOldCompletionCannotOverwriteAnotherSnapshot() throws {
        let defaults = isolatedDefaults()
        let store = controlStore(defaults: defaults)
        let lease = try store.beginChange(to: true, currentEnabled: false)
        let newer = AlarmControlSnapshot(enabled: false, change: .init(id: UUID(), requestedEnabled: true, startedAt: Date()))
        defaults.set(try JSONEncoder().encode(newer), forKey: AlarmControlStateStore.snapshotKey)
        store.finishChange(lease, enabled: true)
        XCTAssertEqual(try store.snapshot(), newer)
    }

    func testCancellationClearsIntermediateStateAndReleasesOperationLock() async throws {
        let store = controlStore()
        var started = false
        let task = Task {
            try await store.withChange(to: true, currentEnabled: false, finalEnabled: { false }) {
                started = true
                try await Task.sleep(for: .seconds(60))
            }
        }
        await waitUntil { started }
        XCTAssertTrue(try store.snapshot().isChanging)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try store.snapshot(), AlarmControlSnapshot(enabled: false))
        let retry = try store.beginChange(to: true, currentEnabled: false)
        store.finishChange(retry, enabled: true)
    }

    func testMissingSharedStorageDoesNotStartAlarmOperation() async {
        let store = AlarmControlStateStore(defaults: nil, lockURL: isolatedLockURL(), reload: {})
        do {
            try await store.withChange(to: true, currentEnabled: false, finalEnabled: { false }) {
                XCTFail("Do not start a control operation when its shared state cannot be written")
            }
            XCTFail("Expected storage error")
        } catch {
            XCTAssertEqual(error.localizedDescription, AlarmControlError.storageUnavailable.localizedDescription)
        }
    }

    func testIntermediateStateSpansCloudLoadingAndAlarmKitScheduling() async throws {
        let store = controlStore()
        let client = FakeAlarmKitClient()
        client.suspendNextSchedule = true
        let scheduler = NotificationScheduler(defaults: isolatedDefaults(), alarmClient: client,
            removeLegacyNotifications: {}, publishControlState: store.publish)
        var cloud: CheckedContinuation<Void, Never>?
        let task = Task {
            try await store.withChange(to: true, currentEnabled: false, finalEnabled: { scheduler.alarmsEnabled }) {
                try await scheduler.setAlarmsEnabledAndWait(true) {
                    await withCheckedContinuation { cloud = $0 }
                    return [self.group()]
                }
            }
        }
        await waitUntil { cloud != nil }
        XCTAssertEqual(try store.snapshot().status, "Zapínání…")
        XCTAssertFalse(try store.snapshot().enabled)
        XCTAssertEqual(client.scheduleAttempts, 0)
        cloud?.resume()
        await waitUntil { client.waitingSchedule != nil }
        XCTAssertTrue(try store.snapshot().isChanging)
        XCTAssertFalse(try store.snapshot().enabled)
        client.resumeSchedule()
        try await task.value
        XCTAssertEqual(try store.snapshot(), AlarmControlSnapshot(enabled: true))
        XCTAssertEqual(client.records.count, 1)
        try await store.withChange(to: false, currentEnabled: true, finalEnabled: { scheduler.alarmsEnabled }) {
            XCTAssertEqual(try store.snapshot().status, "Vypínání…")
            try await scheduler.setAlarmsEnabledAndWait(false) {
                XCTFail("Disabling must not load iCloud")
                return []
            }
        }
        XCTAssertEqual(try store.snapshot(), AlarmControlSnapshot(enabled: false))
        XCTAssertTrue(client.records.isEmpty)
    }

    func testFailedCloudAuthorizationOrSchedulingLeavesControlOffAndRetryable() async throws {
        for failure in ["cloud", "authorization", "schedule"] {
            let store = controlStore()
            let client = FakeAlarmKitClient()
            if failure == "authorization" { client.authorizationStatus = .denied }
            if failure == "schedule" { client.failScheduleAttempt = 2 }
            let scheduler = NotificationScheduler(defaults: isolatedDefaults(), alarmClient: client,
                removeLegacyNotifications: {}, publishControlState: store.publish)
            do {
                try await store.withChange(to: true, currentEnabled: false, finalEnabled: { scheduler.alarmsEnabled }) {
                    XCTAssertTrue(try store.snapshot().isChanging)
                    try await scheduler.setAlarmsEnabledAndWait(true) {
                        if failure == "cloud" { throw AlarmControlError.plansUnavailable }
                        return [self.group(), self.group(at: Date().addingTimeInterval(1200))]
                    }
                }
                XCTFail("Expected \(failure) error")
            } catch {}
            XCTAssertEqual(try store.snapshot(), AlarmControlSnapshot(enabled: false), failure)
            XCTAssertTrue(client.records.isEmpty, failure)
            let retry = try store.beginChange(to: true, currentEnabled: false)
            store.finishChange(retry, enabled: false)
        }
    }

    func testUnchangedStartupProjectionDoesNotReloadControlInEitherState() throws {
        for enabled in [false, true] {
            let defaults = isolatedDefaults()
            var reloads = 0
            AlarmControlState.publish(enabled, defaults: defaults) { reloads += 1 }
            XCTAssertEqual(reloads, 1, "First launch must initialize missing shared state")
            AlarmControlState.publish(enabled, defaults: defaults) { reloads += 1 }
            XCTAssertEqual(reloads, 1, "Cold launch must not overwrite an in-progress control interaction")
            XCTAssertEqual(try AlarmControlState.currentValue(defaults: defaults), enabled)
            AlarmControlState.publish(!enabled, defaults: defaults) { reloads += 1 }
            XCTAssertEqual(reloads, 2)
            XCTAssertEqual(try AlarmControlState.currentValue(defaults: defaults), !enabled)
        }
    }

    func testColdEnablePublishesOnlyAfterCloudAndAlarmKitHaveFinished() async throws {
        let controlDefaults = isolatedDefaults()
        controlDefaults.set(false, forKey: AlarmControlState.enabledKey)
        var reloads = 0
        let client = FakeAlarmKitClient()
        client.suspendNextSchedule = true
        let scheduler = NotificationScheduler(
            defaults: isolatedDefaults(), alarmClient: client, removeLegacyNotifications: {},
            publishControlState: { enabled in
                AlarmControlState.publish(enabled, defaults: controlDefaults) { reloads += 1 }
            }
        )
        scheduler.restoreAlarmState()
        XCTAssertEqual(reloads, 0)
        let readiness = PlanLoadReadiness()
        readiness.beginReload()
        var ready = false
        var waitingForCloud = false
        let intent = Task {
            try await scheduler.setAlarmsEnabledAndWait(true) {
                waitingForCloud = true
                try await readiness.ensureReady(isReady: { ready }) { XCTFail("Use the startup sync") }
                return [self.group()]
            }
        }
        await waitUntil { waitingForCloud }
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertEqual(client.scheduleAttempts, 0)
        XCTAssertEqual(reloads, 0)
        ready = true
        readiness.endReload()
        await waitUntil { client.waitingSchedule != nil }
        XCTAssertTrue(scheduler.isChangingAlarmState)
        XCTAssertFalse(try AlarmControlState.currentValue(defaults: controlDefaults))
        XCTAssertEqual(reloads, 0, "Do not report enabled before AlarmKit replies")
        client.resumeSchedule()
        try await intent.value
        XCTAssertEqual(client.records.count, 1)
        XCTAssertTrue(try AlarmControlState.currentValue(defaults: controlDefaults))
        XCTAssertEqual(reloads, 1)
    }

    func testFailedEnableRollsBackAndNeverPublishesEnabled() async {
        let client = FakeAlarmKitClient()
        client.failScheduleAttempt = 2
        let defaults = isolatedDefaults()
        var states: [Bool] = []
        let scheduler = NotificationScheduler(
            defaults: defaults, alarmClient: client, removeLegacyNotifications: {},
            publishControlState: { states.append($0) }
        )
        do {
            try await scheduler.setAlarmsEnabledAndWait(true) {
                [self.group(), self.group(at: Date().addingTimeInterval(1200))]
            }
            XCTFail("Partial scheduling must not report success")
        } catch {}
        XCTAssertTrue(client.records.isEmpty)
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertFalse(defaults.bool(forKey: NotificationScheduler.alarmsEnabledKey))
        XCTAssertTrue(states.allSatisfy { !$0 })
        XCTAssertNotNil(scheduler.lastSchedulingError)
        XCTAssertFalse(scheduler.isChangingAlarmState)
    }

    func testCancelledEnableDrainsAlarmKitAndDoesNotPublishEnabled() async {
        let client = FakeAlarmKitClient()
        client.suspendNextSchedule = true
        var states: [Bool] = []
        let scheduler = NotificationScheduler(
            defaults: isolatedDefaults(), alarmClient: client, removeLegacyNotifications: {},
            publishControlState: { states.append($0) }
        )
        let intent = Task { try await scheduler.setAlarmsEnabledAndWait(true) { [self.group()] } }
        await waitUntil { client.waitingSchedule != nil }
        intent.cancel()
        client.resumeSchedule()
        do {
            try await intent.value
            XCTFail("Cancelled action must not succeed")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(client.records.isEmpty)
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(states.allSatisfy { !$0 })
        XCTAssertFalse(scheduler.isChangingAlarmState)
    }

    func testRepeatedEnableFailureDoesNotCommitEarlierUnfinishedEnable() async {
        let client = FakeAlarmKitClient()
        client.suspendNextSchedule = true
        client.failScheduleAttempt = 2
        var states: [Bool] = []
        let scheduler = NotificationScheduler(
            defaults: isolatedDefaults(), alarmClient: client, removeLegacyNotifications: {},
            publishControlState: { states.append($0) }
        )
        let first = Task { try await scheduler.setAlarmsEnabledAndWait(true) { [self.group()] } }
        await waitUntil { client.waitingSchedule != nil }
        var secondStarted = false
        let second = Task {
            try await scheduler.setAlarmsEnabledAndWait(true) {
                secondStarted = true
                return [self.group()]
            }
        }
        await waitUntil { secondStarted }
        client.resumeSchedule()
        if case .success = await first.result { XCTFail("Superseded action must not succeed") }
        if case .success = await second.result { XCTFail("Scheduling failure must not succeed") }
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
        XCTAssertTrue(states.allSatisfy { !$0 })
        XCTAssertNotNil(scheduler.lastSchedulingError)
    }

    func testBothStoredAlarmStatesSurviveControlInitialization() throws {
        for enabled in [true, false] {
            let defaults = isolatedDefaults()
            let controlDefaults = isolatedDefaults()
            defaults.set(enabled, forKey: NotificationScheduler.alarmsEnabledKey)
            for _ in 0..<2 {
                let scheduler = NotificationScheduler(
                    defaults: defaults, alarmClient: FakeAlarmKitClient(), removeLegacyNotifications: {},
                    publishControlState: { controlDefaults.set($0, forKey: AlarmControlState.enabledKey) }
                )
                XCTAssertEqual(scheduler.alarmsEnabled, enabled)
                XCTAssertEqual(defaults.bool(forKey: NotificationScheduler.alarmsEnabledKey), enabled)
                XCTAssertEqual(try AlarmControlState.currentValue(defaults: controlDefaults), enabled)
            }
        }
    }

    func testMuteControlRequestsUseExistingSchedulerInBothDirections() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires AlarmKit") }
        let (scheduler, client) = fixture(enabled: true)
        client.addExisting(id: UUID())
        try await scheduler.setAlarmsEnabledAndWait(SetPillsAlarmsMutedIntent(value: true).alarmIntent.value) {
            XCTFail("Muting must not load plans")
            return []
        }
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
        try await scheduler.setAlarmsEnabledAndWait(SetPillsAlarmsMutedIntent(value: false).alarmIntent.value) {
            [self.group()]
        }
        XCTAssertTrue(scheduler.alarmsEnabled)
        XCTAssertEqual(client.records.count, 1)
    }

    func testExistingPreferenceIsPublishedWithoutChangingOtherSettings() async throws {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: NotificationScheduler.alarmsEnabledKey)
        defaults.set("spoken", forKey: NotificationScheduler.soundModeKey)
        let client = FakeAlarmKitClient()
        var states: [Bool] = []
        let scheduler = NotificationScheduler(
            defaults: defaults, alarmClient: client, removeLegacyNotifications: {},
            publishControlState: { states.append($0) }
        )
        XCTAssertEqual(states, [true])
        try await scheduler.setAlarmsEnabledAndWait(false) {
            XCTFail("Disabling must not read plans or iCloud")
            return []
        }
        XCTAssertEqual(states.last, false)
        XCTAssertFalse(defaults.bool(forKey: NotificationScheduler.alarmsEnabledKey))
        XCTAssertEqual(defaults.string(forKey: NotificationScheduler.soundModeKey), "spoken")
    }

    func testControlDisablesRingingFutureAndTestAlarmsWithoutAuthorization() async throws {
        let (scheduler, client) = fixture(enabled: true)
        let ringing = UUID()
        for id in [ringing, UUID(), NotificationScheduler.alarmKitTestID] { client.addExisting(id: id) }
        client.alertingIDs.insert(ringing)
        client.authorizationStatus = .denied
        try await scheduler.setAlarmsEnabledAndWait(false) {
            XCTFail("Disabling must work without loading any plans")
            return []
        }
        XCTAssertTrue(client.records.isEmpty)
        XCTAssertTrue(client.alertingIDs.isEmpty)
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertEqual(client.authorizationRequests, 0)
        try await scheduler.rescheduleAlarmGroups([group()]).value
        XCTAssertTrue(client.records.isEmpty)
    }

    func testEnableUsesCurrentPlansAndDoesNotRestoreOldTestAlarm() async throws {
        let (scheduler, client) = fixture()
        try await scheduler.setAlarmsEnabledAndWait(true) { [self.group()] }
        XCTAssertTrue(scheduler.alarmsEnabled)
        XCTAssertEqual(client.records.count, 1)
        XCTAssertNil(client.records[NotificationScheduler.alarmKitTestID])
        XCTAssertFalse(scheduler.isChangingAlarmState)
    }

    func testLoadFailureLeavesAlarmsOffAndReturnsErrorToControl() async {
        let (scheduler, client) = fixture()
        do {
            try await scheduler.setAlarmsEnabledAndWait(true) { throw AlarmControlError.plansUnavailable }
            XCTFail("Must not report success without plans")
        } catch {
            XCTAssertEqual(error.localizedDescription, AlarmControlError.plansUnavailable.localizedDescription)
        }
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
        XCTAssertFalse(scheduler.isChangingAlarmState)
        XCTAssertNotNil(scheduler.lastSchedulingError)
    }

    func testDeniedPermissionDoesNotLoadPlansOrReportSuccess() async {
        let (scheduler, client) = fixture()
        client.authorizationStatus = .denied
        do {
            try await scheduler.setAlarmsEnabledAndWait(true) { XCTFail("No permission"); return [] }
            XCTFail("Must throw")
        } catch {}
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
    }

    func testCancellationFailureIsReturnedAndCanBeRetried() async throws {
        let (scheduler, client) = fixture(enabled: true)
        let id = UUID()
        client.addExisting(id: id)
        client.failCancellationIDs.insert(id)
        do {
            try await scheduler.setAlarmsEnabledAndWait(false) { [] }
            XCTFail("The control must not report successful cancellation")
        } catch {}
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertNotNil(scheduler.lastSchedulingError)
        client.failCancellationIDs = []
        try await scheduler.setAlarmsEnabledAndWait(false) { [] }
        XCTAssertTrue(client.records.isEmpty)
        XCTAssertNil(scheduler.lastSchedulingError)
    }

    func testOffSupersedesEnableWaitingForPlans() async throws {
        let (scheduler, client) = fixture()
        var continuation: CheckedContinuation<Void, Never>?
        let enabling = Task {
            try await scheduler.setAlarmsEnabledAndWait(true) {
                await withCheckedContinuation { continuation = $0 }
                return [self.group()]
            }
        }
        await waitUntil { continuation != nil }
        try await scheduler.setAlarmsEnabledAndWait(false) { [] }
        continuation?.resume()
        if case .success = await enabling.result { XCTFail("Stale enable must be cancelled") }
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
        XCTAssertFalse(scheduler.isChangingAlarmState)
        XCTAssertNil(scheduler.lastSchedulingError)
    }

    func testOffSupersedesEnableAlreadyScheduling() async throws {
        let (scheduler, client) = fixture()
        client.suspendNextSchedule = true
        let enabling = Task { try await scheduler.setAlarmsEnabledAndWait(true) { [self.group()] } }
        await waitUntil { client.waitingSchedule != nil }
        let disabling = Task { try await scheduler.setAlarmsEnabledAndWait(false) { [] } }
        await waitUntil { !scheduler.alarmsEnabled }
        client.resumeSchedule()
        _ = await enabling.result
        try await disabling.value
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
        XCTAssertFalse(scheduler.isChangingAlarmState)
    }

    func testControlAndSettingsOperateOnSameState() async throws {
        let (scheduler, client) = fixture()
        await scheduler.setAlarmsEnabled(true) { [self.group()] }
        try await scheduler.setAlarmsEnabledAndWait(false) { [] }
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
        try await scheduler.setAlarmsEnabledAndWait(true) { [self.group()] }
        await scheduler.setAlarmsEnabled(false) { [] }
        XCTAssertFalse(scheduler.alarmsEnabled)
        XCTAssertTrue(client.records.isEmpty)
    }

    func testActualControlTapCancelsRealAlarms() async throws {
#if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["PILLCARE_CONTROL_UI_TEST"] == "1" else {
            throw XCTSkip("Opt-in: add and tap Alarmy Pills in the isolated simulator Control Center")
        }
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires AlarmKit") }
        let scheduler = NotificationScheduler.shared
        await scheduler.waitForPendingOperations()
        guard try AlarmManager.shared.alarms.isEmpty else { throw XCTSkip("Requires no existing alarms") }
        let original = scheduler.alarmsEnabled
        var failure: Error?
        do {
            try await scheduler.setAlarmsEnabledAndWait(true) {
                [self.group(at: Date().addingTimeInterval(30)), self.group(at: Date().addingTimeInterval(600))]
            }
            XCTAssertEqual(try AlarmManager.shared.alarms.count, 2)
            print("CONTROL_UI_TEST_READY: add Alarmy Pills, wait for ringing, then toggle off")
            let deadline = Date().addingTimeInterval(180)
            while scheduler.alarmsEnabled, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
            await scheduler.waitForPendingOperations()
            XCTAssertFalse(scheduler.alarmsEnabled, "Use the actual Control Center toggle")
            XCTAssertTrue(try AlarmManager.shared.alarms.isEmpty)
            XCTAssertEqual(try AlarmControlState.currentValue(), false)
            print("CONTROL_UI_TEST_PASSED: all real alarms removed by Control Center")
        } catch { failure = error }
        await scheduler.setAlarmsEnabled(false) { [] }
        if original { await scheduler.setAlarmsEnabled(true) { [] } }
        if let failure { throw failure }
#else
        throw XCTSkip("Simulator-only")
#endif
    }

    func testActualControlTapsRoundTripWithLoadedPlan() async throws {
#if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["PILLCARE_CONTROL_UI_TEST"] == "1",
              ProcessInfo.processInfo.environment["PILLCARE_ALARM_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in: tap the real Control Center toggle in both directions")
        }
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires AlarmKit") }
        let scheduler = NotificationScheduler.shared
        let store = MedicationStore.shared
        await scheduler.waitForPendingOperations()
        guard try AlarmManager.shared.alarms.isEmpty, store.medicationItems.isEmpty else {
            throw XCTSkip("Requires an isolated simulator without plans or alarms")
        }
        guard AlarmManager.shared.authorizationState == .authorized else {
            throw XCTSkip("Requires AlarmKit permission in the isolated simulator")
        }
        let originalEnabled = scheduler.alarmsEnabled
        let originalSound = scheduler.soundMode
        let nextDose = Date().addingTimeInterval(1200)
        let time = DoseTime(
            id: UUID(), label: "UI test",
            time: TimeOfDay(hour: Calendar.current.component(.hour, from: nextDose),
                            minute: Calendar.current.component(.minute, from: nextDose))
        )
        let medication = Medication(
            id: UUID(), name: "Control UI test", note: "", colorHex: "#009999",
            startDate: Calendar.current.startOfDay(for: nextDose), doseTimes: [time],
            phases: [PlanPhase(title: "Phase 1", durationDays: 1, doses: [DoseEntry(timeId: time.id, amount: 1)])]
        )
        var failure: Error?
        do {
            scheduler.soundMode = .tone
            try await scheduler.setAlarmsEnabledAndWait(false) { [] }
            try await store.withAlarmControlUITestMedication(medication) {
                let expectedCount = scheduler.makeUpcomingDoseAlarmGroups(store: store).count
                XCTAssertGreaterThan(expectedCount, 0)
                for (index, enabled) in [true, false, true, false, true, false].enumerated() {
                    print("CONTROL_ROUNDTRIP_READY: step=\(index + 1) targetEnabled=\(enabled)")
                    let deadline = Date().addingTimeInterval(90)
                    while scheduler.alarmsEnabled != enabled, Date() < deadline {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    await scheduler.waitForPendingOperations()
                    try await Task.sleep(for: .seconds(2))
                    XCTAssertEqual(scheduler.alarmsEnabled, enabled, "Tap the actual Control Center button")
                    XCTAssertEqual(try AlarmControlState.currentValue(), enabled)
                    XCTAssertNil(scheduler.lastSchedulingError)
                    let count = try AlarmManager.shared.alarms.count
                    XCTAssertEqual(count, enabled ? expectedCount : 0)
                    print("CONTROL_ROUNDTRIP_VERIFIED: step=\(index + 1) enabled=\(scheduler.alarmsEnabled) alarms=\(count)")
                }
            }
        } catch { failure = error }
        await scheduler.setAlarmsEnabled(false) { [] }
        scheduler.soundMode = originalSound
        if originalEnabled { await scheduler.setAlarmsEnabled(true) { [] } }
        XCTAssertTrue(try AlarmManager.shared.alarms.isEmpty)
        if let failure { throw failure }
#else
        throw XCTSkip("Simulator-only")
#endif
    }

    func testControlIntentCancelsRealRingingAndFutureAlarms() async throws {
#if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["PILLCARE_CONTROL_INTENT_TEST"] == "1",
              ProcessInfo.processInfo.environment["PILLCARE_ALARM_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in real AlarmKit test with cloud rescheduling disabled")
        }
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires AlarmKit") }
        let scheduler = NotificationScheduler.shared
        await scheduler.waitForPendingOperations()
        guard try AlarmManager.shared.alarms.isEmpty else { throw XCTSkip("Requires no existing alarms") }
        guard AlarmManager.shared.authorizationState == .authorized else {
            throw XCTSkip("Requires previously granted AlarmKit permission in the isolated simulator")
        }
        let original = scheduler.alarmsEnabled
        var failure: Error?
        do {
            try await scheduler.setAlarmsEnabledAndWait(true) {
                [self.group(at: Date().addingTimeInterval(8)), self.group(at: Date().addingTimeInterval(600))]
            }
            XCTAssertEqual(try AlarmManager.shared.alarms.count, 2)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, try !AlarmManager.shared.alarms.contains(where: { $0.state == .alerting }) {
                try await Task.sleep(for: .milliseconds(200))
            }
            XCTAssertTrue(try AlarmManager.shared.alarms.contains { $0.state == .alerting })
            _ = try await SetPillsAlarmsMutedIntent(value: true).perform()
            XCTAssertFalse(scheduler.alarmsEnabled)
            XCTAssertTrue(try AlarmManager.shared.alarms.isEmpty)
            XCTAssertEqual(try AlarmControlState.currentValue(), false)
            _ = try await SetPillsAlarmsIntent(value: false).perform()
            XCTAssertTrue(try AlarmManager.shared.alarms.isEmpty)
        } catch { failure = error }
        await scheduler.setAlarmsEnabled(false) { [] }
        if original { await scheduler.setAlarmsEnabled(true) { [] } }
        if let failure { throw failure }
#else
        throw XCTSkip("Simulator-only")
#endif
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "AlarmControlTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private func isolatedLockURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AlarmControlTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("operation.lock")
    }

    private func controlStore(defaults: UserDefaults? = nil, reload: @escaping () -> Void = {}) -> AlarmControlStateStore {
        AlarmControlStateStore(defaults: defaults ?? isolatedDefaults(), lockURL: isolatedLockURL(), reload: reload)
    }

    private func fixture(enabled: Bool = false) -> (NotificationScheduler, FakeAlarmKitClient) {
        let defaults = isolatedDefaults()
        defaults.set(enabled, forKey: NotificationScheduler.alarmsEnabledKey)
        let client = FakeAlarmKitClient()
        return (NotificationScheduler(defaults: defaults, alarmClient: client, removeLegacyNotifications: {}), client)
    }

    private func group(at date: Date = Date().addingTimeInterval(600)) -> ScheduledDoseAlarmGroup {
        let dose = GeneratedDose(
            id: UUID().uuidString, baseEventId: UUID().uuidString, workspaceId: "control-test",
            isShared: false, workspaceName: "", medicationId: UUID(), medicationName: "Control test",
            medicationNote: "", medicationColorHex: "#009999", timeId: UUID(), timeLabel: "Morning",
            scheduledDate: date, scheduledTime: TimeOfDay(hour: 8, minute: 0), amount: "1", phaseTitle: "Phase 1"
        )
        return ScheduledDoseAlarmGroup(scheduledDate: date, alarms: [ScheduledDoseAlarm(dose: dose, scheduledDate: date, repeatIndex: 0)])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition())
    }
}
