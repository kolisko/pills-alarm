import XCTest
@testable import PillCore

@MainActor
final class ConfirmDoseUseCaseTests: XCTestCase {
    func testFirstConfirmationIsCreated() async throws {
        let requested = confirmation(.confirmed)
        var saves = 0
        let result = try await ConfirmDoseUseCase.execute(
            command: command(requested),
            fetchConfirmation: { _ in nil },
            createIfAbsent: { saves += 1; return $0 }
        )
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(result.confirmation, requested)
        XCTAssertFalse(result.hasStatusConflict)
    }

    func testExistingSameStatusIsSilentAndPreservesAllMetadata() async throws {
        for status in DoseStatus.allCases {
            let existing = confirmation(status)
            let requested = confirmation(status)
            let result = try await ConfirmDoseUseCase.execute(
                command: command(requested),
                fetchConfirmation: { _ in existing },
                createIfAbsent: { _ in XCTFail("Must not write an existing confirmation"); return requested }
            )
            XCTAssertEqual(result.confirmation, existing)
            XCTAssertFalse(result.hasStatusConflict)
        }
    }

    func testExistingOppositeStatusRequiresDialogInBothDirections() async throws {
        for status in DoseStatus.allCases {
            let existing = confirmation(status)
            let requested = confirmation(status == .confirmed ? .skipped : .confirmed)
            let result = try await ConfirmDoseUseCase.execute(
                command: command(requested),
                fetchConfirmation: { _ in existing },
                createIfAbsent: { _ in XCTFail("Must not overwrite the first status"); return requested }
            )
            XCTAssertEqual(result.confirmation, existing)
            XCTAssertEqual(result.requestedStatus, requested.status)
            XCTAssertTrue(result.hasStatusConflict)
        }
    }

    func testLegacyEventIDIsRecognizedWithoutCreatingDuplicate() async throws {
        var existing = confirmation(.confirmed)
        existing.eventId = "workspace|event"
        var checked: [String] = []
        let requested = confirmation(.confirmed)
        let result = try await ConfirmDoseUseCase.execute(
            command: ConfirmDoseCommand(confirmation: requested, eventIdsToCheck: ["event", "workspace|event"]),
            fetchConfirmation: { eventId in
                checked.append(eventId)
                return eventId == existing.eventId ? existing : nil
            },
            createIfAbsent: { _ in XCTFail("Must preserve legacy history"); return requested }
        )
        XCTAssertEqual(checked, ["event", "workspace|event"])
        XCTAssertEqual(result.confirmation, existing)
        XCTAssertFalse(result.hasStatusConflict)
    }

    func testSimultaneousRequestsKeepFirstWriteForEveryStatusCombination() async throws {
        for firstStatus in DoseStatus.allCases {
            for secondStatus in DoseStatus.allCases {
                let first = confirmation(firstStatus)
                let second = confirmation(secondStatus)
                let server = RacingConfirmationServer(winner: first)
                let firstTask = Task { try await self.execute(first, on: server) }
                let secondTask = Task { try await self.execute(second, on: server) }
                let firstResult = try await firstTask.value
                let secondResult = try await secondTask.value
                XCTAssertEqual(server.createAttempts, 2, "Both clients must reach the write after an empty read")
                XCTAssertEqual(server.writes, 1)
                XCTAssertEqual(firstResult.confirmation, first)
                XCTAssertEqual(secondResult.confirmation, first)
                XCTAssertFalse(firstResult.hasStatusConflict)
                XCTAssertEqual(secondResult.hasStatusConflict, firstStatus != secondStatus)
            }
        }
    }

    func testFetchFailureDoesNotAttemptWrite() async {
        do {
            _ = try await ConfirmDoseUseCase.execute(
                command: command(confirmation(.confirmed)),
                fetchConfirmation: { _ in throw TestError.offline },
                createIfAbsent: { XCTFail("Read failure must not be treated as absence"); return $0 }
            )
            XCTFail("Expected network error")
        } catch {
            XCTAssertEqual(error as? TestError, .offline)
        }
    }

    func testSaveFailureIsNotReportedAsSuccess() async {
        do {
            _ = try await ConfirmDoseUseCase.execute(
                command: command(confirmation(.confirmed)),
                fetchConfirmation: { _ in nil },
                createIfAbsent: { _ in throw TestError.offline }
            )
            XCTFail("Expected network error")
        } catch {
            XCTAssertEqual(error as? TestError, .offline)
        }
    }

    func testRetryAfterLostResponsePreservesOriginalWrite() async throws {
        let requested = confirmation(.confirmed)
        var stored: DoseConfirmation?
        var writes = 0
        do {
            _ = try await ConfirmDoseUseCase.execute(
                command: command(requested),
                fetchConfirmation: { _ in stored },
                createIfAbsent: { stored = $0; writes += 1; throw TestError.offline }
            )
            XCTFail("Expected lost response")
        } catch {
            XCTAssertEqual(error as? TestError, .offline)
        }
        let result = try await ConfirmDoseUseCase.execute(
            command: command(confirmation(.confirmed)),
            fetchConfirmation: { _ in stored },
            createIfAbsent: { writes += 1; return $0 }
        )
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(result.confirmation, requested)
        XCTAssertFalse(result.hasStatusConflict)
    }

    private func execute(_ requested: DoseConfirmation, on server: RacingConfirmationServer) async throws -> ConfirmDoseResult {
        try await ConfirmDoseUseCase.execute(
            command: command(requested),
            fetchConfirmation: { _ in server.stored },
            createIfAbsent: { try await server.create($0) }
        )
    }

    private func command(_ confirmation: DoseConfirmation) -> ConfirmDoseCommand {
        ConfirmDoseCommand(confirmation: confirmation, eventIdsToCheck: [confirmation.eventId])
    }

    private func confirmation(_ status: DoseStatus) -> DoseConfirmation {
        DoseConfirmation(
            eventId: "event", medicationId: UUID(), timeId: UUID(),
            scheduledDate: Date(timeIntervalSince1970: 1_780_000_000), amount: "1/2",
            status: status, memberId: UUID(), memberName: "Original member",
            timestamp: Date(), note: UUID().uuidString
        )
    }

    private enum TestError: Error { case offline }
}

@MainActor
private final class RacingConfirmationServer {
    let winner: DoseConfirmation
    var stored: DoseConfirmation?
    var createAttempts = 0
    var writes = 0
    private var waiting: [CheckedContinuation<DoseConfirmation, any Error>] = []

    init(winner: DoseConfirmation) { self.winner = winner }

    func create(_ confirmation: DoseConfirmation) async throws -> DoseConfirmation {
        createAttempts += 1
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count == 2 else { return }
            stored = winner
            writes += 1
            let pending = waiting
            waiting.removeAll()
            pending.forEach { $0.resume(returning: winner) }
        }
    }
}
