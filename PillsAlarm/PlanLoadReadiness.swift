import Foundation

// Observes existing reloads without changing which reload is allowed to apply its data.
@MainActor
final class PlanLoadReadiness {
    private(set) var activeReloadCount = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func beginReload() {
        activeReloadCount += 1
    }

    func endReload() {
        precondition(activeReloadCount > 0)
        activeReloadCount -= 1
        let completed = Array(waiters.values)
        waiters.removeAll()
        completed.forEach { $0.resume() }
    }

    func ensureReady(
        isReady: () -> Bool,
        reload: () async -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !isReady() else { return }
        if activeReloadCount == 0 {
            await reload()
        }
        while !isReady(), activeReloadCount > 0 {
            AlarmControlDiagnostics.record(.plansWait, fields: ["activeReloads": "\(activeReloadCount)"])
            try await waitForReloadCompletion()
        }
        try Task.checkCancellation()
        guard isReady() else { throw AlarmControlError.plansUnavailable }
    }

    private func waitForReloadCompletion() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }
}
