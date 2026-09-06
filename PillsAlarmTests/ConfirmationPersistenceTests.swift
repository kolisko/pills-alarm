import CloudKit
import XCTest
import PillCore
@testable import PillsAlarm

@MainActor
final class ConfirmationPersistenceTests: XCTestCase {
    func testNewRecordUsesVersionCheckedSavePolicy() async throws {
        let expected = confirmation(.confirmed)
        let record = try makeRecord(expected)
        let saved = try await CloudKitRepository.createConfirmationRecord(
            record,
            save: { submitted, policy in
                XCTAssertEqual(policy, .ifServerRecordUnchanged)
                XCTAssertEqual(submitted.recordID, record.recordID)
                XCTAssertNil(submitted.recordChangeTag)
                return [submitted]
            },
            fetch: { XCTFail("Unnecessary fetch"); return record }
        )
        XCTAssertEqual(saved, expected)
    }

    func testVersionConflictUsesEntireServerRecordForBothStatuses() async throws {
        for status in DoseStatus.allCases {
            let existing = confirmation(status)
            let server = try makeRecord(existing)
            let requested = try makeRecord(confirmation(status == .confirmed ? .skipped : .confirmed))
            var attempts = 0
            let saved = try await CloudKitRepository.createConfirmationRecord(
                requested,
                save: { _, _ in attempts += 1; throw self.conflict(server) },
                fetch: { XCTFail("Conflict already contains server record"); return server }
            )
            XCTAssertEqual(saved, existing)
            XCTAssertEqual(attempts, 1, "Never retry by overwriting")
        }
    }

    func testPartialFailureAndUnderlyingConflictAreRecognized() async throws {
        let existing = confirmation(.skipped)
        let server = try makeRecord(existing)
        let partial = NSError(domain: CKError.errorDomain, code: CKError.partialFailure.rawValue, userInfo: [
            CKPartialErrorsByItemIDKey: [server.recordID: conflict(server)]
        ])
        let wrapped = NSError(domain: "TestWrapper", code: 1, userInfo: [NSUnderlyingErrorKey: partial])
        for error in [partial, wrapped] {
            let result = try await CloudKitRepository.createConfirmationRecord(
                try makeRecord(confirmation(.confirmed)),
                save: { _, _ in throw error },
                fetch: { XCTFail("Server record is present"); return server }
            )
            XCTAssertEqual(result, existing)
        }
    }

    func testConflictWithoutServerRecordFetchesWinner() async throws {
        let expected = confirmation(.confirmed)
        let server = try makeRecord(expected)
        var fetches = 0
        let result = try await CloudKitRepository.createConfirmationRecord(
            try makeRecord(confirmation(.skipped)),
            save: { _, _ in throw CKError(.serverRecordChanged) },
            fetch: { fetches += 1; return server }
        )
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(result, expected)
    }

    func testNetworkAndPermissionFailuresAreNotConflicts() async throws {
        let record = try makeRecord(confirmation(.confirmed))
        for code in [CKError.networkFailure, .networkUnavailable, .permissionFailure, .notAuthenticated] {
            do {
                _ = try await CloudKitRepository.createConfirmationRecord(
                    record,
                    save: { _, _ in throw CKError(code) },
                    fetch: { XCTFail("Must not hide a real error"); return record }
                )
                XCTFail("Expected \(code)")
            } catch {
                XCTAssertEqual((error as? CKError)?.code, code)
            }
        }
    }

    func testFallbackFetchFailurePropagatesWithoutSavingAgain() async throws {
        let record = try makeRecord(confirmation(.confirmed))
        for code in [CKError.networkFailure, .unknownItem] {
            var attempts = 0
            do {
                _ = try await CloudKitRepository.createConfirmationRecord(
                    record,
                    save: { _, _ in attempts += 1; throw CKError(.serverRecordChanged) },
                    fetch: { throw CKError(code) }
                )
                XCTFail("Expected fetch failure")
            } catch {
                XCTAssertEqual((error as? CKError)?.code, code)
                XCTAssertEqual(attempts, 1)
            }
        }
    }

    func testMissingSaveResultIsNotSuccess() async throws {
        let record = try makeRecord(confirmation(.confirmed))
        do {
            _ = try await CloudKitRepository.createConfirmationRecord(
                record, save: { _, _ in [] }, fetch: { XCTFail("Unexpected fetch"); return record }
            )
            XCTFail("Empty save response is not success")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .internalError)
        }
    }

    func testMalformedServerPayloadIsNotAccepted() async throws {
        let record = try makeRecord(confirmation(.confirmed))
        let malformed = try makeRecord(confirmation(.skipped))
        malformed[Field.payload] = Data("invalid".utf8) as NSData
        do {
            _ = try await CloudKitRepository.createConfirmationRecord(
                record, save: { _, _ in throw self.conflict(malformed) }, fetch: { malformed }
            )
            XCTFail("Corrupt data must not be shown as successful confirmation")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .internalError)
        }
    }

    func testUnrelatedRecordConflictIsNotMistakenForThisDose() async throws {
        let record = try makeRecord(confirmation(.confirmed))
        let error = NSError(domain: CKError.errorDomain, code: CKError.partialFailure.rawValue, userInfo: [
            CKPartialErrorsByItemIDKey: [CKRecord.ID(recordName: "other-dose"): CKError(.serverRecordChanged)]
        ])
        do {
            _ = try await CloudKitRepository.createConfirmationRecord(
                record, save: { _, _ in throw error }, fetch: { XCTFail("Unrelated conflict"); return record }
            )
            XCTFail("Expected original partial failure")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .partialFailure)
        }
    }

    func testActualConflictHandlerWithTwoSimultaneousCommands() async throws {
        for firstStatus in DoseStatus.allCases {
            for secondStatus in DoseStatus.allCases {
                let first = confirmation(firstStatus)
                let second = confirmation(secondStatus)
                let server = RecordRaceServer(winner: try makeRecord(first))
                let firstTask = Task { try await self.execute(first, server: server) }
                let secondTask = Task { try await self.execute(second, server: server) }
                let firstResult = try await firstTask.value
                let secondResult = try await secondTask.value
                XCTAssertEqual(server.attempts, 2)
                XCTAssertEqual(server.writes, 1)
                XCTAssertEqual(firstResult.confirmation, first)
                XCTAssertEqual(secondResult.confirmation, first)
                XCTAssertFalse(firstResult.hasStatusConflict)
                XCTAssertEqual(secondResult.hasStatusConflict, firstStatus != secondStatus)
            }
        }
    }

    private func execute(_ confirmation: DoseConfirmation, server: RecordRaceServer) async throws -> ConfirmDoseResult {
        try await ConfirmDoseUseCase.execute(
            command: ConfirmDoseCommand(confirmation: confirmation, eventIdsToCheck: [confirmation.eventId]),
            fetchConfirmation: { _ in nil },
            createIfAbsent: { confirmation in
                try await CloudKitRepository.createConfirmationRecord(
                    self.makeRecord(confirmation),
                    save: { record, policy in try await server.save(record, policy: policy) },
                    fetch: { server.winner }
                )
            }
        )
    }

    private func conflict(_ server: CKRecord) -> NSError {
        NSError(domain: CKError.errorDomain, code: CKError.serverRecordChanged.rawValue,
                userInfo: [CKRecordChangedErrorServerRecordKey: server])
    }

    private func makeRecord(_ confirmation: DoseConfirmation) throws -> CKRecord {
        let record = CKRecord(recordType: RecordType.confirmation, recordID: CKRecord.ID(recordName: "confirmation-event"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        record[Field.eventId] = confirmation.eventId as NSString
        record[Field.payload] = try encoder.encode(confirmation) as NSData
        return record
    }

    private func confirmation(_ status: DoseStatus) -> DoseConfirmation {
        DoseConfirmation(
            eventId: "event", medicationId: UUID(), timeId: UUID(),
            scheduledDate: Date(timeIntervalSince1970: 1_780_000_000), amount: "1/2",
            status: status, memberId: UUID(), memberName: "Original member",
            timestamp: Date(timeIntervalSince1970: 1_780_000_100), note: UUID().uuidString
        )
    }
}

@MainActor
private final class RecordRaceServer {
    let winner: CKRecord
    var attempts = 0
    var writes = 0
    private var waiting: [(CKRecord, CheckedContinuation<[CKRecord], any Error>)] = []

    init(winner: CKRecord) { self.winner = winner }

    func save(_ record: CKRecord, policy: CKModifyRecordsOperation.RecordSavePolicy) async throws -> [CKRecord] {
        XCTAssertEqual(policy, .ifServerRecordUnchanged)
        XCTAssertNil(record.recordChangeTag)
        attempts += 1
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append((record, continuation))
            guard waiting.count == 2 else { return }
            writes += 1
            let pending = waiting
            waiting.removeAll()
            for (submitted, continuation) in pending {
                if submitted[Field.payload] as? Data == winner[Field.payload] as? Data {
                    continuation.resume(returning: [winner])
                } else {
                    let conflict = NSError(domain: CKError.errorDomain, code: CKError.serverRecordChanged.rawValue,
                                           userInfo: [CKRecordChangedErrorServerRecordKey: winner])
                    continuation.resume(throwing: conflict)
                }
            }
        }
    }
}
