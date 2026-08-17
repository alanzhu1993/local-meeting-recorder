import Foundation

public struct RecoveryResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case recovered(URL)
        case failed(URL, String)
    }

    public let outcome: Outcome

    public init(outcome: Outcome) {
        self.outcome = outcome
    }
}

protocol InterruptedRecordingStoring: Sendable {
    func listInterruptedRecordings() async throws -> [URL]
    func recoveredURL(for workingURL: URL) async throws -> URL
    func releaseReservation(for outputURL: URL) async
}

extension RecordingStore: InterruptedRecordingStoring {}

protocol InterruptedRecordingFinalizing: Sendable {
    func recover(workingURL: URL, recoveredURL: URL) async throws -> URL
}

extension M4AFinalizer: InterruptedRecordingFinalizing {}

public actor RecoveryService {
    public private(set) var isRecovering = false
    public private(set) var lastFailure: RecordingFailure?

    private let activityGate: RecordingActivityGate
    private let store: any InterruptedRecordingStoring
    private let finalizer: any InterruptedRecordingFinalizing
    private let beforeCreatorCompletion: @Sendable () async -> Void
    private let onJoin: @Sendable () -> Void
    private var inFlight: (
        identifier: UUID,
        task: Task<RecoveryOperationOutcome, Never>
    )?

    public init(
        activityGate: RecordingActivityGate,
        store: RecordingStore = RecordingStore(),
        finalizer: M4AFinalizer = M4AFinalizer()
    ) {
        self.activityGate = activityGate
        self.store = store
        self.finalizer = finalizer
        beforeCreatorCompletion = {}
        onJoin = {}
    }

    init(
        activityGate: RecordingActivityGate,
        store: any InterruptedRecordingStoring,
        finalizer: any InterruptedRecordingFinalizing,
        beforeCreatorCompletion: @escaping @Sendable () async -> Void = {},
        onJoin: @escaping @Sendable () -> Void = {}
    ) {
        self.activityGate = activityGate
        self.store = store
        self.finalizer = finalizer
        self.beforeCreatorCompletion = beforeCreatorCompletion
        self.onJoin = onJoin
    }

    public func recoverInterruptedRecordings() async -> [RecoveryResult] {
        if let inFlight {
            onJoin()
            let outcome = await inFlight.task.value
            completeRecovery(identifier: inFlight.identifier, outcome: outcome)
            return outcome.results
        }

        let identifier = UUID()
        let activityGate = self.activityGate
        let store = self.store
        let finalizer = self.finalizer
        let task = Task {
            do {
                let lease = try await activityGate.acquireRecovery()
                let results = await Self.performRecovery(store: store, finalizer: finalizer)
                await activityGate.release(lease)
                return RecoveryOperationOutcome(results: results, failure: nil)
            } catch {
                let failure = Self.failure(from: error)
                return RecoveryOperationOutcome(results: [], failure: failure)
            }
        }
        inFlight = (identifier, task)
        isRecovering = true
        lastFailure = nil

        let outcome = await task.value
        await beforeCreatorCompletion()
        completeRecovery(identifier: identifier, outcome: outcome)
        return outcome.results
    }

    private func completeRecovery(identifier: UUID, outcome: RecoveryOperationOutcome) {
        guard inFlight?.identifier == identifier else { return }
        inFlight = nil
        isRecovering = false
        lastFailure = outcome.failure
    }

    private nonisolated static func performRecovery(
        store: any InterruptedRecordingStoring,
        finalizer: any InterruptedRecordingFinalizing
    ) async -> [RecoveryResult] {
        let interrupted: [URL]
        do {
            interrupted = try await store.listInterruptedRecordings()
        } catch {
            return []
        }

        var seen = Set<String>()
        let uniqueWorkingURLs = interrupted.filter { workingURL in
            seen.insert(workingURL.standardizedFileURL.path).inserted
        }
        var results: [RecoveryResult] = []
        results.reserveCapacity(uniqueWorkingURLs.count)

        for workingURL in uniqueWorkingURLs {
            let recoveredURL: URL
            do {
                recoveredURL = try await store.recoveredURL(for: workingURL)
            } catch {
                results.append(RecoveryResult(outcome: .failed(
                    workingURL,
                    failureMessage(error)
                )))
                continue
            }

            do {
                let output = try await finalizer.recover(
                    workingURL: workingURL,
                    recoveredURL: recoveredURL
                )
                await store.releaseReservation(for: recoveredURL)
                results.append(RecoveryResult(outcome: .recovered(output)))
            } catch {
                await store.releaseReservation(for: recoveredURL)
                results.append(RecoveryResult(outcome: .failed(
                    workingURL,
                    failureMessage(error)
                )))
            }
        }
        return results
    }

    private nonisolated static func failureMessage(_ error: Error) -> String {
        if let failure = error as? RecordingFailure { return failure.message }
        return error.localizedDescription
    }

    private nonisolated static func failure(from error: Error) -> RecordingFailure {
        if let failure = error as? RecordingFailure { return failure }
        return RecordingFailure(code: .capture, message: error.localizedDescription)
    }
}

private struct RecoveryOperationOutcome: Sendable {
    let results: [RecoveryResult]
    let failure: RecordingFailure?
}
