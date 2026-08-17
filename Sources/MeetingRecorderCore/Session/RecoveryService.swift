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

public struct RecoveryBatchResult: Equatable, Sendable {
    public let results: [RecoveryResult]
    public let batchFailure: RecordingFailure?
    fileprivate let failureOrigin: RecoveryBatchFailureOrigin

    public init(results: [RecoveryResult], batchFailure: RecordingFailure?) {
        self.results = results
        self.batchFailure = batchFailure
        failureOrigin = .batch
    }

    fileprivate init(
        results: [RecoveryResult],
        batchFailure: RecordingFailure?,
        failureOrigin: RecoveryBatchFailureOrigin
    ) {
        self.results = results
        self.batchFailure = batchFailure
        self.failureOrigin = failureOrigin
    }

    public static func == (lhs: RecoveryBatchResult, rhs: RecoveryBatchResult) -> Bool {
        lhs.results == rhs.results && lhs.batchFailure == rhs.batchFailure
    }
}

private enum RecoveryBatchFailureOrigin: Equatable, Sendable {
    case none
    case activityGate
    case batch
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
    public private(set) var lastBatchFailure: RecordingFailure?

    private let activityGate: RecordingActivityGate
    private let store: any InterruptedRecordingStoring
    private let finalizer: any InterruptedRecordingFinalizing
    private let afterLeaseAcquired: @Sendable () async -> Void
    private let beforeCreatorCompletion: @Sendable () async -> Void
    private let onJoin: @Sendable () -> Void
    private var inFlight: (
        identifier: UUID,
        task: Task<RecoveryBatchResult, Never>
    )?

    public init(
        activityGate: RecordingActivityGate,
        store: RecordingStore = RecordingStore(),
        finalizer: M4AFinalizer = M4AFinalizer()
    ) {
        self.activityGate = activityGate
        self.store = store
        self.finalizer = finalizer
        afterLeaseAcquired = {}
        beforeCreatorCompletion = {}
        onJoin = {}
    }

    init(
        activityGate: RecordingActivityGate,
        store: any InterruptedRecordingStoring,
        finalizer: any InterruptedRecordingFinalizing,
        afterLeaseAcquired: @escaping @Sendable () async -> Void = {},
        beforeCreatorCompletion: @escaping @Sendable () async -> Void = {},
        onJoin: @escaping @Sendable () -> Void = {}
    ) {
        self.activityGate = activityGate
        self.store = store
        self.finalizer = finalizer
        self.afterLeaseAcquired = afterLeaseAcquired
        self.beforeCreatorCompletion = beforeCreatorCompletion
        self.onJoin = onJoin
    }

    public func recoverInterruptedRecordings() async -> [RecoveryResult] {
        await recoverInterruptedRecordingsBatch().results
    }

    public func recoverInterruptedRecordingsBatch() async -> RecoveryBatchResult {
        if let inFlight {
            onJoin()
            let batch = await inFlight.task.value
            completeRecovery(identifier: inFlight.identifier, batch: batch)
            return batch
        }

        let identifier = UUID()
        let activityGate = self.activityGate
        let store = self.store
        let finalizer = self.finalizer
        let afterLeaseAcquired = self.afterLeaseAcquired
        let task = Task {
            do {
                let lease = try await activityGate.acquireRecovery()
                await afterLeaseAcquired()
                let batch = await Self.performRecovery(store: store, finalizer: finalizer)
                await activityGate.release(lease)
                return batch
            } catch {
                let failure = Self.failure(from: error)
                return RecoveryBatchResult(
                    results: [],
                    batchFailure: failure,
                    failureOrigin: .activityGate
                )
            }
        }
        inFlight = (identifier, task)
        isRecovering = true
        lastFailure = nil
        lastBatchFailure = nil

        let batch = await task.value
        await beforeCreatorCompletion()
        completeRecovery(identifier: identifier, batch: batch)
        return batch
    }

    private func completeRecovery(identifier: UUID, batch: RecoveryBatchResult) {
        guard inFlight?.identifier == identifier else { return }
        inFlight = nil
        isRecovering = false
        switch batch.failureOrigin {
        case .activityGate:
            lastFailure = batch.batchFailure
            lastBatchFailure = nil
        case .batch:
            lastFailure = nil
            lastBatchFailure = batch.batchFailure
        case .none:
            lastFailure = nil
            lastBatchFailure = nil
        }
    }

    private nonisolated static func performRecovery(
        store: any InterruptedRecordingStoring,
        finalizer: any InterruptedRecordingFinalizing
    ) async -> RecoveryBatchResult {
        let interrupted: [URL]
        do {
            interrupted = try await store.listInterruptedRecordings()
        } catch {
            return RecoveryBatchResult(
                results: [],
                batchFailure: recoveryFailure(from: error),
                failureOrigin: .batch
            )
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
        return RecoveryBatchResult(
            results: results,
            batchFailure: nil,
            failureOrigin: .none
        )
    }

    private nonisolated static func failureMessage(_ error: Error) -> String {
        if let failure = error as? RecordingFailure { return failure.message }
        return error.localizedDescription
    }

    private nonisolated static func failure(from error: Error) -> RecordingFailure {
        if let failure = error as? RecordingFailure { return failure }
        return RecordingFailure(code: .capture, message: error.localizedDescription)
    }

    private nonisolated static func recoveryFailure(from error: Error) -> RecordingFailure {
        if let failure = error as? RecordingFailure { return failure }
        return RecordingFailure(code: .write, message: error.localizedDescription)
    }
}
