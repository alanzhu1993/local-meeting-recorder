import Combine
import Foundation

protocol RecordingCoordinatorLevelClock: Sendable {
    var now: Duration { get }
    func sleep(until deadline: Duration) async throws
}

private struct ContinuousRecordingCoordinatorLevelClock: RecordingCoordinatorLevelClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    init() {
        origin = clock.now
    }

    var now: Duration {
        origin.duration(to: clock.now)
    }

    func sleep(until deadline: Duration) async throws {
        try await clock.sleep(until: origin.advanced(by: deadline))
    }
}

@MainActor
public final class RecordingCoordinator: ObservableObject {
    private static let audioLevelPublicationInterval = Duration.milliseconds(100)

    @Published public private(set) var phase: RecordingPhase = .idle
    @Published public private(set) var audioLevels: AudioLevels = .silent

    private let session: any RecordingSessionManaging
    private let now: @Sendable () -> Date
    private let levelClock: any RecordingCoordinatorLevelClock
    private var eventTask: Task<Void, Never>?
    private var lastAudioLevelPublicationTime: Duration?
    private var pendingAudioLevels: AudioLevels?
    private var pendingAudioLevelTask: Task<Void, Never>?
    private var audioLevelThrottleEpoch = 0
    private var operationID = 0

    public convenience init(
        session: any RecordingSessionManaging,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            session: session,
            now: now,
            levelClock: ContinuousRecordingCoordinatorLevelClock()
        )
    }

    init(
        session: any RecordingSessionManaging,
        now: @escaping @Sendable () -> Date,
        levelClock: any RecordingCoordinatorLevelClock
    ) {
        self.session = session
        self.now = now
        self.levelClock = levelClock
        eventTask = Task { [weak self, session] in
            let events = await session.events()
            for await event in events {
                self?.consume(event)
            }
        }
    }

    public func toggleRecording() async {
        switch phase {
        case .idle, .failed:
            let operation = nextOperationID()
            resetAudioLevelThrottle()
            phase = .preparing
            do {
                let active = try await session.start(at: now())
                if operationID == operation, phase == .preparing {
                    phase = .recording(active, warning: nil)
                }
            } catch {
                resetAudioLevelThrottle()
                if operationID == operation, phase == .preparing {
                    phase = .failed(Self.failure(from: error))
                }
            }
        case let .recording(active, _):
            let operation = nextOperationID()
            resetAudioLevelThrottle()
            phase = .stopping(active)
            do {
                _ = try await session.stop()
                resetAudioLevelThrottle()
                if operationID == operation, phase == .stopping(active) {
                    phase = .idle
                }
            } catch {
                resetAudioLevelThrottle()
                if operationID == operation, phase == .stopping(active) {
                    phase = .failed(Self.failure(from: error))
                }
            }
        case .preparing, .stopping:
            return
        }
    }

    private func nextOperationID() -> Int {
        operationID += 1
        return operationID
    }

    private static func failure(from error: Error) -> RecordingFailure {
        if let failure = error as? RecordingFailure {
            return failure
        }
        return RecordingFailure(code: .capture, message: error.localizedDescription)
    }

    private func consume(_ event: RecordingSessionEvent) {
        switch event {
        case let .levels(levels):
            publishAudioLevelsIfDue(levels)
        case let .warning(warning):
            if case let .recording(active, _) = phase {
                phase = .recording(active, warning: warning)
            }
        case let .failed(failure):
            resetAudioLevelThrottle()
            phase = .failed(failure)
        }
    }

    private func publishAudioLevelsIfDue(_ levels: AudioLevels) {
        let publicationTime = levelClock.now
        guard let lastAudioLevelPublicationTime else {
            publishAudioLevels(levels, at: publicationTime)
            return
        }

        let elapsed = publicationTime - lastAudioLevelPublicationTime
        guard elapsed >= .zero, elapsed < Self.audioLevelPublicationInterval else {
            publishAudioLevels(levels, at: publicationTime)
            return
        }

        pendingAudioLevels = levels
        guard pendingAudioLevelTask == nil else { return }
        let deadline = lastAudioLevelPublicationTime + Self.audioLevelPublicationInterval
        let epoch = audioLevelThrottleEpoch
        let levelClock = levelClock
        pendingAudioLevelTask = Task { [weak self] in
            do {
                try await levelClock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.publishPendingAudioLevels(epoch: epoch)
        }
    }

    private func publishAudioLevels(_ levels: AudioLevels, at publicationTime: Duration) {
        cancelPendingAudioLevelPublication()
        lastAudioLevelPublicationTime = publicationTime
        audioLevels = levels
    }

    private func publishPendingAudioLevels(epoch: Int) {
        guard epoch == audioLevelThrottleEpoch else { return }
        pendingAudioLevelTask = nil
        guard let pendingAudioLevels else { return }
        self.pendingAudioLevels = nil
        lastAudioLevelPublicationTime = levelClock.now
        audioLevels = pendingAudioLevels
    }

    private func cancelPendingAudioLevelPublication() {
        audioLevelThrottleEpoch &+= 1
        pendingAudioLevelTask?.cancel()
        pendingAudioLevelTask = nil
        pendingAudioLevels = nil
    }

    private func resetAudioLevelThrottle() {
        cancelPendingAudioLevelPublication()
        lastAudioLevelPublicationTime = nil
    }
}
