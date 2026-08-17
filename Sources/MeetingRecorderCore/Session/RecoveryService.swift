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

    private let store: any InterruptedRecordingStoring
    private let finalizer: any InterruptedRecordingFinalizing
    private var inFlight: (
        identifier: UUID,
        task: Task<[RecoveryResult], Never>
    )?

    public init(
        store: RecordingStore = RecordingStore(),
        finalizer: M4AFinalizer = M4AFinalizer()
    ) {
        self.store = store
        self.finalizer = finalizer
    }

    init(
        store: any InterruptedRecordingStoring,
        finalizer: any InterruptedRecordingFinalizing
    ) {
        self.store = store
        self.finalizer = finalizer
    }

    public func recoverInterruptedRecordings() async -> [RecoveryResult] {
        if let inFlight {
            return await inFlight.task.value
        }

        let identifier = UUID()
        let store = self.store
        let finalizer = self.finalizer
        let task = Task {
            await Self.performRecovery(store: store, finalizer: finalizer)
        }
        inFlight = (identifier, task)
        isRecovering = true

        let results = await task.value
        if inFlight?.identifier == identifier {
            inFlight = nil
            isRecovering = false
        }
        return results
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
}
