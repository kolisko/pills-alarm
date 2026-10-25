import Foundation
import WidgetKit
import Darwin

struct AlarmControlSnapshot: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
        let id: UUID
        let requestedEnabled: Bool
        let startedAt: Date
    }

    let enabled: Bool
    var change: Change?
    var needsRecovery = false

    var isChanging: Bool { change != nil }
    var status: String {
        if let change { return change.requestedEnabled ? "Zapínání…" : "Vypínání…" }
        if needsRecovery { return "Změna nedokončena" }
        return enabled ? "Zapnuté" : "Vypnuté"
    }

    // WidgetKit renders the optimistic Bool before the intent can publish its shared snapshot.
    func pendingTarget(isMuted: Bool) -> Bool? {
        if let change { return change.requestedEnabled }
        return isMuted == enabled ? !isMuted : nil
    }

    func displayedStatus(isMuted: Bool) -> String {
        if let target = pendingTarget(isMuted: isMuted) { return target ? "Zapínání…" : "Vypínání…" }
        return status
    }
}

// flock is released by the OS even if the app dies before its defer can run.
final class AlarmControlChangeLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { close(descriptor) }

    static func acquire(at url: URL?) throws -> AlarmControlChangeLock? {
        guard let url else { throw AlarmControlError.storageUnavailable }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            return AlarmControlChangeLock(descriptor: descriptor)
        }
        let code = errno
        close(descriptor)
        if code == EWOULDBLOCK { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    static func isHeld(at url: URL?) throws -> Bool {
        let probe = try acquire(at: url)
        return withExtendedLifetime(probe) { probe == nil }
    }
}

@MainActor
final class AlarmControlStateStore {
    static let snapshotKey = "alarmControlSnapshot.v1"
    static let maximumBusyAge: TimeInterval = 120

    final class ChangeLease {
        let change: AlarmControlSnapshot.Change
        private let lock: AlarmControlChangeLock

        init(change: AlarmControlSnapshot.Change, lock: AlarmControlChangeLock) {
            self.change = change
            self.lock = lock
        }
    }

    private let defaults: UserDefaults?
    private let lockURL: URL?
    private let reload: () -> Void

    init(defaults: UserDefaults?, lockURL: URL?, reload: @escaping () -> Void) {
        self.defaults = defaults
        self.lockURL = lockURL
        self.reload = reload
    }

    func snapshot(now: Date = Date()) throws -> AlarmControlSnapshot {
        var result = try storedSnapshot()
        if let change = result.change {
            let age = now.timeIntervalSince(change.startedAt)
            let active = try AlarmControlChangeLock.isHeld(at: lockURL)
            if age < 0 || age >= Self.maximumBusyAge || !active {
                // Read-only recovery: do not overwrite a newer app write from the extension.
                result.change = nil
                result.needsRecovery = true
            }
        }
        AlarmControlDiagnostics.record(.controlRead, fields: ["enabled": "\(result.enabled)",
            "changing": "\(result.isChanging)", "needsRecovery": "\(result.needsRecovery)"], always: true)
        return result
    }

    func publish(_ enabled: Bool) {
        let previous = try? storedSnapshot()
        if previous?.change != nil {
            do {
                if try AlarmControlChangeLock.isHeld(at: lockURL) { return }
            } catch {
                AlarmControlDiagnostics.record(.controlReadFailed,
                    fields: ["error": AlarmControlDiagnostics.errorCode(error)], always: true)
                return
            }
        }
        try? save(AlarmControlSnapshot(enabled: enabled), previous: previous)
    }

    func beginChange(to enabled: Bool, currentEnabled: Bool, now: Date = Date()) throws -> ChangeLease {
        guard let lock = try AlarmControlChangeLock.acquire(at: lockURL) else {
            throw AlarmControlError.changeInProgress
        }
        let change = AlarmControlSnapshot.Change(id: UUID(), requestedEnabled: enabled, startedAt: now)
        try save(AlarmControlSnapshot(enabled: currentEnabled, change: change), previous: try? storedSnapshot())
        return ChangeLease(change: change, lock: lock)
    }

    func finishChange(_ lease: ChangeLease, enabled: Bool) {
        guard let previous = try? storedSnapshot(), previous.change?.id == lease.change.id else { return }
        try? save(AlarmControlSnapshot(enabled: enabled), previous: previous)
    }

    func withChange<T>(to enabled: Bool, currentEnabled: Bool, finalEnabled: () -> Bool,
                       operation: () async throws -> T) async throws -> T {
        let lease = try beginChange(to: enabled, currentEnabled: currentEnabled)
        defer { finishChange(lease, enabled: finalEnabled()) }
        return try await operation()
    }

    private func storedSnapshot() throws -> AlarmControlSnapshot {
        guard let defaults else { throw AlarmControlError.storageUnavailable }
        if let data = defaults.data(forKey: Self.snapshotKey) {
            return try JSONDecoder().decode(AlarmControlSnapshot.self, from: data)
        }
        guard let enabled = defaults.object(forKey: AlarmControlState.enabledKey) as? Bool else {
            throw AlarmControlError.openAppFirst
        }
        return AlarmControlSnapshot(enabled: enabled)
    }

    private func save(_ snapshot: AlarmControlSnapshot, previous: AlarmControlSnapshot?) throws {
        guard let defaults else { throw AlarmControlError.storageUnavailable }
        defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.snapshotKey)
        defaults.set(snapshot.enabled, forKey: AlarmControlState.enabledKey)
        let changed = previous != snapshot
        AlarmControlDiagnostics.record(.controlPublished, fields: ["enabled": "\(snapshot.enabled)",
            "changing": "\(snapshot.isChanging)", "requestedEnabled": snapshot.change.map { "\($0.requestedEnabled)" } ?? "none",
            "reloadRequested": "\(changed)"], always: true)
        if changed { reload() }
    }
}

enum AlarmControlState {
    static let groupID = "group.com.kolisko.pillcare.controls"
    static let kind = "com.kolisko.pillcare.alarm-control"
    static let enabledKey = "alarmsEnabled"

    @MainActor static let store = AlarmControlStateStore(
        defaults: UserDefaults(suiteName: groupID),
        lockURL: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("Library/Application Support/AlarmControl/operation.lock"),
        reload: {
            if #available(iOS 18.0, *) { ControlCenter.shared.reloadControls(ofKind: kind) }
        }
    )

    static func currentValue(defaults: UserDefaults? = UserDefaults(suiteName: groupID)) throws -> Bool {
        guard let value = defaults?.object(forKey: enabledKey) as? Bool else {
            AlarmControlDiagnostics.record(.controlReadFailed, fields: ["reason": "missingSharedState"], always: true)
            throw AlarmControlError.openAppFirst
        }
        AlarmControlDiagnostics.record(.controlRead, fields: ["enabled": "\(value)"], always: true)
        return value
    }

    // A read-only projection for the extension. The existing app preference remains authoritative.
    @MainActor static func publish(_ enabled: Bool) {
        store.publish(enabled)
    }

    static func publish(_ enabled: Bool, defaults: UserDefaults?, reload: () -> Void) {
        guard let defaults else { return }
        let changed = defaults.object(forKey: enabledKey) as? Bool != enabled
        defaults.set(enabled, forKey: enabledKey)
        AlarmControlDiagnostics.record(.controlPublished,
            fields: ["enabled": "\(enabled)", "reloadRequested": "\(changed)"], always: true)
        // A cold launch must not overwrite the control's pending action with an unchanged value.
        if changed { reload() }
    }
}

enum AlarmControlError: LocalizedError {
    case openAppFirst
    case plansUnavailable
    case changeInProgress
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .openAppFirst: "Nejprve otevřete aplikaci Pills Alarm."
        case .plansUnavailable: "Plány léků se nepodařilo načíst. Otevřete Pills Alarm a zkuste zapnutí znovu."
        case .changeInProgress: "Změna alarmů ještě probíhá. Počkejte na její dokončení."
        case .storageUnavailable: "Stav ovladače není dostupný. Otevřete Pills Alarm a zkuste to znovu."
        }
    }
}
