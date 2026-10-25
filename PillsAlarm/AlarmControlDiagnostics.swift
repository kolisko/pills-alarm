import Foundation
import OSLog

enum AlarmDiagnosticStage: String, Codable, Sendable {
    case appLaunch, intentBegin, intentSucceeded, intentFailed, intentCancelled, wrongProcess
    case authorizationBegin, authorizationEnd, plansBegin, plansWait, plansEnd
    case cloudBegin, cloudAccount, cloudUser, cloudZone, cloudSnapshots, cloudRepair, cloudSubscriptions, cloudEnd, cloudFailed
    case schedulingBegin, schedulingEnd, schedulingFailed, schedulingCancelled
    case stateSaved, controlPublished, controlRead, controlReadFailed

    var label: String {
        switch self {
        case .appLaunch: "Spuštění aplikace"
        case .intentBegin: "Začátek akce ovladače"
        case .intentSucceeded: "Akce dokončena"
        case .intentFailed: "Akce selhala"
        case .intentCancelled: "Akce přerušena"
        case .wrongProcess: "Akce spuštěna v rozšíření místo aplikace"
        case .authorizationBegin: "Kontrola oprávnění AlarmKitu"
        case .authorizationEnd: "Výsledek oprávnění AlarmKitu"
        case .plansBegin: "Příprava plánů"
        case .plansWait: "Čekání na probíhající načítání plánů"
        case .plansEnd: "Výsledek načítání plánů"
        case .cloudBegin: "Začátek načítání iCloudu"
        case .cloudAccount: "Stav účtu iCloud"
        case .cloudUser: "Identita iCloud načtena"
        case .cloudZone: "Zóna iCloud připravena"
        case .cloudSnapshots: "Data iCloud načtena"
        case .cloudRepair: "Kontrola sdílení dokončena"
        case .cloudSubscriptions: "Odběry změn zkontrolovány"
        case .cloudEnd: "Konec načítání iCloudu"
        case .cloudFailed: "Chyba načítání iCloudu"
        case .schedulingBegin: "Začátek operace AlarmKitu"
        case .schedulingEnd: "Operace AlarmKitu dokončena"
        case .schedulingFailed: "Operace AlarmKitu selhala"
        case .schedulingCancelled: "Operace AlarmKitu přerušena"
        case .stateSaved: "Volba alarmů uložena"
        case .controlPublished: "Stav předán ovladači"
        case .controlRead: "Ovladač načetl stav"
        case .controlReadFailed: "Ovladač nemohl načíst stav"
        }
    }

    var isFailure: Bool {
        [.intentFailed, .wrongProcess, .cloudFailed, .schedulingFailed, .controlReadFailed].contains(self)
    }
}

struct AlarmDiagnosticEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let processSeconds: TimeInterval
    let processSession: UUID
    let processID: Int32
    let bundleID: String
    let version: String
    let processRole: String
    let attemptID: UUID?
    let stage: AlarmDiagnosticStage
    let fields: [String: String]

    var details: String {
        fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: " · ")
    }
}

struct AlarmDiagnosticSnapshot {
    var events: [AlarmDiagnosticEvent]
    var storageError: String?

    var report: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["Pills Alarm - diagnostika ovladace", "Export: \(formatter.string(from: Date()))"]
        if let storageError { lines.append("Storage: \(storageError)") }
        for event in events {
            lines.append("\(formatter.string(from: event.date)) \(event.stage.rawValue) [\(event.processRole) pid=\(event.processID) session=\(event.processSession) version=\(event.version) bundle=\(event.bundleID) processSeconds=\(String(format: "%.3f", event.processSeconds)) attempt=\(event.attemptID?.uuidString ?? "none")] \(event.details)")
        }
        return lines.joined(separator: "\n")
    }
}

// Separate atomic files avoid read-modify-write races between the app and its extension.
// Logging is best-effort and must never change the result of an alarm operation.
final class AlarmDiagnosticJournal: @unchecked Sendable {
    static let shared = AlarmDiagnosticJournal(directory: FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: AlarmControlState.groupID)?
        .appendingPathComponent("Library/Application Support/AlarmControlDiagnostics", isDirectory: true))

    private let directory: URL?
    private let maximumEvents: Int
    private let lock = NSLock()
    private var lastWriteError: String?
    private let logger = Logger(subsystem: "com.kolisko.pillcare", category: "AlarmControlDiagnostics")

    init(directory: URL?, maximumEvents: Int = 300) {
        self.directory = directory
        self.maximumEvents = max(1, maximumEvents)
    }

    func append(_ event: AlarmDiagnosticEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard var directory else {
            lastWriteError = "Sdílené úložiště není dostupné."
            return
        }
        do {
            let manager = FileManager.default
            if !manager.fileExists(atPath: directory.path) {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try directory.setResourceValues(values)
            }
            let name = String(format: "%020.3f", event.date.timeIntervalSince1970) + "-" + event.id.uuidString + ".json"
            try JSONEncoder().encode(event).write(to: directory.appendingPathComponent(name),
                                                  options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let files = try eventFiles(in: directory)
            for file in files.prefix(max(0, files.count - maximumEvents)) {
                try? manager.removeItem(at: file)
            }
            lastWriteError = nil
        } catch {
            lastWriteError = AlarmControlDiagnostics.errorCode(error)
            logger.error("Diagnostic write failed: \(self.lastWriteError ?? "unknown", privacy: .public)")
        }
    }

    func snapshot() -> AlarmDiagnosticSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let directory else {
            return AlarmDiagnosticSnapshot(events: [], storageError: "Sdílené úložiště není dostupné.")
        }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return AlarmDiagnosticSnapshot(events: [], storageError: lastWriteError)
        }
        do {
            let files = try eventFiles(in: directory).suffix(maximumEvents)
            var unreadable = 0
            let events = files.compactMap { url -> AlarmDiagnosticEvent? in
                do { return try JSONDecoder().decode(AlarmDiagnosticEvent.self, from: Data(contentsOf: url)) }
                catch {
                    if FileManager.default.fileExists(atPath: url.path) { unreadable += 1 }
                    return nil
                }
            }.sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.processSeconds < $1.processSeconds
            }
            return AlarmDiagnosticSnapshot(events: events,
                storageError: lastWriteError ?? (unreadable > 0 ? "Nečitelné záznamy: \(unreadable)" : nil))
        } catch {
            return AlarmDiagnosticSnapshot(events: [], storageError: AlarmControlDiagnostics.errorCode(error))
        }
    }

    private func eventFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

enum AlarmControlDiagnostics {
    @TaskLocal static var attemptID: UUID?
    @TaskLocal static var journalOverride: AlarmDiagnosticJournal?
    private static let processSession = UUID()
    private static let processStarted = ContinuousClock.now

    static func record(_ stage: AlarmDiagnosticStage, fields: [String: String] = [:], always: Bool = false) {
        guard always || attemptID != nil else { return }
        let bundle = Bundle.main
#if PILLS_CONTROL_EXTENSION
        let role = "control-extension"
#else
        let role = "app"
#endif
        let event = AlarmDiagnosticEvent(
            id: UUID(), date: Date(), processSeconds: elapsedSeconds(since: processStarted),
            processSession: processSession, processID: ProcessInfo.processInfo.processIdentifier,
            bundleID: bundle.bundleIdentifier ?? "unknown",
            version: "\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))",
            processRole: role, attemptID: attemptID, stage: stage, fields: fields
        )
        (journalOverride ?? .shared).append(event)
    }

    // Never persist localized descriptions or userInfo: CloudKit can include medical record contents.
    static func errorCode(_ error: Error) -> String {
        var result: [String] = []
        var next: NSError? = error as NSError
        for _ in 0..<3 {
            guard let current = next else { break }
            result.append("\(current.domain):\(current.code)")
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result.joined(separator: " <- ")
    }

    private static func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    @MainActor
    static func withIntentAttempt<T>(enabled: Bool, intent: String, operation: () async throws -> T) async rethrows -> T {
        if attemptID != nil { return try await operation() }
        return try await $attemptID.withValue(UUID()) {
            let started = ContinuousClock.now
            record(.intentBegin, fields: ["requestedEnabled": "\(enabled)", "intent": intent])
            do {
                let result = try await operation()
                record(.intentSucceeded, fields: ["elapsedSeconds": String(format: "%.3f", elapsedSeconds(since: started))])
                return result
            } catch {
                record(error is CancellationError ? .intentCancelled : .intentFailed,
                       fields: ["error": errorCode(error), "elapsedSeconds": String(format: "%.3f", elapsedSeconds(since: started))])
                throw error
            }
        }
    }
}
