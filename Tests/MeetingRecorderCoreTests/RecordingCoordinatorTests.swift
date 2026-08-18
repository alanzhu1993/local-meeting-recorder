import Combine
import Foundation
import XCTest
@testable import MeetingRecorderCore

private final class LockedCoordinatorTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(current: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.current = current
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func advance(milliseconds: Int) {
        lock.withLock {
            current = current.addingTimeInterval(Double(milliseconds) / 1_000)
        }
    }
}

private final class ManualCoordinatorLevelClock: RecordingCoordinatorLevelClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Duration.zero
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var completed: Set<UUID> = []

    var now: Duration {
        lock.withLock { current }
    }

    var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    func sleep(until deadline: Duration) async throws {
        let id = UUID()
        defer {
            lock.withLock {
                cancelledBeforeRegistration.remove(id)
                completed.remove(id)
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var resumeImmediately = false
                var resumeCancellation = false
                lock.withLock {
                    if cancelledBeforeRegistration.remove(id) != nil {
                        completed.insert(id)
                        resumeCancellation = true
                    } else if current >= deadline {
                        completed.insert(id)
                        resumeImmediately = true
                    } else {
                        sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    }
                }
                if resumeCancellation {
                    continuation.resume(throwing: CancellationError())
                } else if resumeImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
                if let sleeper = sleepers.removeValue(forKey: id) {
                    completed.insert(id)
                    return sleeper.continuation
                }
                if !completed.contains(id) {
                    cancelledBeforeRegistration.insert(id)
                }
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(milliseconds: Int) {
        precondition(milliseconds >= 0)
        let continuations = lock.withLock {
            current += .milliseconds(milliseconds)
            let due = sleepers.filter { $0.value.deadline <= current }
            for id in due.keys {
                sleepers.removeValue(forKey: id)
                completed.insert(id)
            }
            return due.values.map(\.continuation)
        }
        for continuation in continuations {
            continuation.resume()
        }
    }
}

@MainActor
private final class AudioLevelPublicationRecorder {
    private(set) var values: [AudioLevels] = []
    private var cancellable: AnyCancellable?

    init(coordinator: RecordingCoordinator) {
        cancellable = coordinator.$audioLevels
            .dropFirst()
            .sink { [weak self] value in self?.values.append(value) }
    }
}

@MainActor
final class SessionManagerSpy: RecordingSessionManaging {
    private(set) var eventsCallCount = 0
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    var startError: Error?
    var stopError: Error?
    var suspendStart = false
    var suspendStop = false

    let eventStream: AsyncStream<RecordingSessionEvent>
    private let eventContinuation: AsyncStream<RecordingSessionEvent>.Continuation
    private var pendingStart: CheckedContinuation<ActiveRecording, Error>?
    private var pendingStop: CheckedContinuation<SavedRecording, Error>?

    init() {
        let stream = AsyncStream<RecordingSessionEvent>.makeStream()
        eventStream = stream.stream
        eventContinuation = stream.continuation
    }

    func events() async -> AsyncStream<RecordingSessionEvent> {
        eventsCallCount += 1
        return eventStream
    }

    func start(at date: Date) async throws -> ActiveRecording {
        startCallCount += 1
        if let startError {
            throw startError
        }
        let recording = ActiveRecording(
            startedAt: date,
            workingURL: URL(fileURLWithPath: "/tmp/meeting-recording-working.m4a")
        )
        if suspendStart {
            return try await withCheckedThrowingContinuation { continuation in
                pendingStart = continuation
            }
        }
        return recording
    }

    func stop() async throws -> SavedRecording {
        stopCallCount += 1
        if let stopError {
            throw stopError
        }
        let recording = SavedRecording(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1,
            fileURL: URL(fileURLWithPath: "/tmp/meeting-recording.m4a"),
            recovered: false
        )
        if suspendStop {
            return try await withCheckedThrowingContinuation { continuation in
                pendingStop = continuation
            }
        }
        return recording
    }

    func yield(_ event: RecordingSessionEvent) {
        eventContinuation.yield(event)
    }

    var isStartSuspended: Bool { pendingStart != nil }
    var isStopSuspended: Bool { pendingStop != nil }

    func finishStart(returning recording: ActiveRecording? = nil) {
        pendingStart?.resume(returning: recording ?? ActiveRecording(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            workingURL: URL(fileURLWithPath: "/tmp/meeting-recording-working.m4a")
        ))
        pendingStart = nil
    }

    func finishStart(throwing error: any Error) {
        pendingStart?.resume(throwing: error)
        pendingStart = nil
    }

    func finishStop(returning recording: SavedRecording? = nil) {
        pendingStop?.resume(returning: recording ?? SavedRecording(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1,
            fileURL: URL(fileURLWithPath: "/tmp/meeting-recording.m4a"),
            recovered: false
        ))
        pendingStop = nil
    }
}

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    private func waitForEventSubscription(_ session: SessionManagerSpy) async {
        for _ in 0..<100 where session.eventsCallCount == 0 {
            await Task.yield()
        }
    }

    private func waitForPhase(
        _ expected: RecordingPhase,
        coordinator: RecordingCoordinator
    ) async {
        for _ in 0..<100 where coordinator.phase != expected {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.phase, expected)
    }

    private func waitForAudioPublicationCount(
        _ expected: Int,
        recorder: AudioLevelPublicationRecorder
    ) async {
        for _ in 0..<100 where recorder.values.count < expected {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(recorder.values.count, expected)
    }

    private func waitForLevelSleeper(
        _ levelClock: ManualCoordinatorLevelClock
    ) async {
        for _ in 0..<100 where levelClock.sleeperCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(levelClock.sleeperCount, 1)
    }

    private func waitForStartSuspension(
        _ session: SessionManagerSpy,
        _ coordinator: RecordingCoordinator
    ) async -> Bool {
        for _ in 0..<100 {
            if coordinator.phase == .preparing, session.isStartSuspended {
                return true
            }
            await Task.yield()
        }
        XCTFail("expected start to be suspended while preparing")
        return false
    }

    private func waitForStopSuspension(
        _ session: SessionManagerSpy,
        _ coordinator: RecordingCoordinator
    ) async -> Bool {
        for _ in 0..<100 {
            if case .stopping = coordinator.phase, session.isStopSuspended {
                return true
            }
            await Task.yield()
        }
        XCTFail("expected stop to be suspended while stopping")
        return false
    }

    func testToggleStartsThenStopsExactlyOnce() async {
        let session = SessionManagerSpy()
        let coordinator = RecordingCoordinator(
            session: session,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        await coordinator.toggleRecording()
        XCTAssertEqual(session.startCallCount, 1)
        guard case .recording = coordinator.phase else {
            return XCTFail("expected recording")
        }

        await coordinator.toggleRecording()
        XCTAssertEqual(session.stopCallCount, 1)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testSessionEventsUpdateWarningAndAudioLevels() async {
        let session = SessionManagerSpy()
        let coordinator = RecordingCoordinator(session: session)
        await coordinator.toggleRecording()
        await waitForEventSubscription(session)

        let warning = RecordingFailure(code: .microphone, message: "microphone unavailable")
        session.yield(.warning(warning))
        session.yield(.levels(AudioLevels(system: 0.25, microphone: 0.75)))
        for _ in 0..<100 {
            await Task.yield()
            if coordinator.audioLevels == AudioLevels(system: 0.25, microphone: 0.75) {
                break
            }
        }

        guard case let .recording(_, currentWarning) = coordinator.phase else {
            return XCTFail("expected recording")
        }
        XCTAssertEqual(currentWarning, warning)
        XCTAssertEqual(coordinator.audioLevels, AudioLevels(system: 0.25, microphone: 0.75))
    }

    func testLevelEventsPublishLatestValueAtMostOncePer100Milliseconds() async {
        let wallClock = LockedCoordinatorTestClock()
        let levelClock = ManualCoordinatorLevelClock()
        let session = SessionManagerSpy()
        let coordinator = RecordingCoordinator(
            session: session,
            now: wallClock.now,
            levelClock: levelClock
        )
        let recorder = AudioLevelPublicationRecorder(coordinator: coordinator)
        await coordinator.toggleRecording()
        await waitForEventSubscription(session)

        let first = AudioLevels(system: 0.1, microphone: 0.2)
        session.yield(.levels(first))
        await waitForAudioPublicationCount(1, recorder: recorder)

        levelClock.advance(milliseconds: 20)
        let withinFirstWindow = AudioLevels(system: 0.3, microphone: 0.4)
        let firstBarrier = RecordingFailure(code: .microphone, message: "barrier at 20ms")
        session.yield(.levels(withinFirstWindow))
        session.yield(.warning(firstBarrier))
        await waitForPhase(
            .recording(
                ActiveRecording(
                    startedAt: Date(timeIntervalSinceReferenceDate: 0),
                    workingURL: URL(fileURLWithPath: "/tmp/meeting-recording-working.m4a")
                ),
                warning: firstBarrier
            ),
            coordinator: coordinator
        )
        XCTAssertEqual(recorder.values, [first])

        levelClock.advance(milliseconds: 30)
        let latestInsideWindow = AudioLevels(system: 0.5, microphone: 0.6)
        let secondBarrier = RecordingFailure(code: .microphone, message: "barrier at 50ms")
        session.yield(.levels(latestInsideWindow))
        session.yield(.warning(secondBarrier))
        await waitForPhase(
            .recording(
                ActiveRecording(
                    startedAt: Date(timeIntervalSinceReferenceDate: 0),
                    workingURL: URL(fileURLWithPath: "/tmp/meeting-recording-working.m4a")
                ),
                warning: secondBarrier
            ),
            coordinator: coordinator
        )
        XCTAssertEqual(recorder.values, [first])

        levelClock.advance(milliseconds: 50)
        await waitForAudioPublicationCount(2, recorder: recorder)
        XCTAssertEqual(recorder.values, [first, latestInsideWindow])

        levelClock.advance(milliseconds: 50)
        let latestInsideSecondWindow = AudioLevels(system: 0.7, microphone: 0.8)
        let secondWindowBarrier = RecordingFailure(
            code: .microphone,
            message: "barrier at 150ms"
        )
        session.yield(.levels(latestInsideSecondWindow))
        session.yield(.warning(secondWindowBarrier))
        await waitForPhase(
            .recording(
                ActiveRecording(
                    startedAt: Date(timeIntervalSinceReferenceDate: 0),
                    workingURL: URL(fileURLWithPath: "/tmp/meeting-recording-working.m4a")
                ),
                warning: secondWindowBarrier
            ),
            coordinator: coordinator
        )
        XCTAssertEqual(recorder.values, [first, latestInsideWindow])

        levelClock.advance(milliseconds: 50)
        await waitForAudioPublicationCount(3, recorder: recorder)
        XCTAssertEqual(recorder.values, [first, latestInsideWindow, latestInsideSecondWindow])
    }

    func testLatestLevelInsideWindowPublishesAtBoundaryWithoutAnotherEvent() async {
        let wallClock = LockedCoordinatorTestClock()
        let levelClock = ManualCoordinatorLevelClock()
        let session = SessionManagerSpy()
        let coordinator = RecordingCoordinator(
            session: session,
            now: wallClock.now,
            levelClock: levelClock
        )
        let recorder = AudioLevelPublicationRecorder(coordinator: coordinator)
        await coordinator.toggleRecording()
        await waitForEventSubscription(session)

        let leading = AudioLevels(system: 0.1, microphone: 0.2)
        session.yield(.levels(leading))
        await waitForAudioPublicationCount(1, recorder: recorder)

        levelClock.advance(milliseconds: 50)
        let trailing = AudioLevels(system: 0.7, microphone: 0.8)
        let barrier = RecordingFailure(code: .microphone, message: "trailing level barrier")
        session.yield(.levels(trailing))
        session.yield(.warning(barrier))
        await waitForPhase(
            .recording(
                ActiveRecording(
                    startedAt: Date(timeIntervalSinceReferenceDate: 0),
                    workingURL: URL(fileURLWithPath: "/tmp/meeting-recording-working.m4a")
                ),
                warning: barrier
            ),
            coordinator: coordinator
        )
        XCTAssertEqual(recorder.values, [leading])

        levelClock.advance(milliseconds: 50)
        await waitForAudioPublicationCount(2, recorder: recorder)

        XCTAssertEqual(recorder.values, [leading, trailing])
    }

    func testFailureEventIsNotDelayedByActiveLevelThrottleWindow() async {
        let wallClock = LockedCoordinatorTestClock()
        let levelClock = ManualCoordinatorLevelClock()
        let session = SessionManagerSpy()
        let coordinator = RecordingCoordinator(
            session: session,
            now: wallClock.now,
            levelClock: levelClock
        )
        let recorder = AudioLevelPublicationRecorder(coordinator: coordinator)
        await coordinator.toggleRecording()
        await waitForEventSubscription(session)

        let leading = AudioLevels(system: 0.1, microphone: 0.2)
        session.yield(.levels(leading))
        await waitForAudioPublicationCount(1, recorder: recorder)
        levelClock.advance(milliseconds: 20)
        session.yield(.levels(AudioLevels(system: 0.3, microphone: 0.4)))
        let failure = RecordingFailure(code: .write, message: "terminal write failure")
        session.yield(.failed(failure))

        await waitForPhase(.failed(failure), coordinator: coordinator)
        levelClock.advance(milliseconds: 80)
        await Task.yield()
        XCTAssertEqual(recorder.values, [leading])
    }

    func testFirstLevelOfNewRecordingIsNotSuppressedByPreviousThrottleWindow() async {
        let wallClock = LockedCoordinatorTestClock()
        let levelClock = ManualCoordinatorLevelClock()
        let session = SessionManagerSpy()
        let coordinator = RecordingCoordinator(
            session: session,
            now: wallClock.now,
            levelClock: levelClock
        )
        let recorder = AudioLevelPublicationRecorder(coordinator: coordinator)
        await coordinator.toggleRecording()
        await waitForEventSubscription(session)

        let firstRecordingLevel = AudioLevels(system: 0.1, microphone: 0.2)
        session.yield(.levels(firstRecordingLevel))
        await waitForAudioPublicationCount(1, recorder: recorder)
        levelClock.advance(milliseconds: 20)
        session.yield(.levels(AudioLevels(system: 0.3, microphone: 0.4)))
        let barrier = RecordingFailure(code: .microphone, message: "old pending barrier")
        session.yield(.warning(barrier))
        await waitForPhase(
            .recording(
                ActiveRecording(
                    startedAt: Date(timeIntervalSinceReferenceDate: 0),
                    workingURL: URL(fileURLWithPath: "/tmp/meeting-recording-working.m4a")
                ),
                warning: barrier
            ),
            coordinator: coordinator
        )
        await coordinator.toggleRecording()

        wallClock.advance(milliseconds: 40)
        levelClock.advance(milliseconds: 20)
        await coordinator.toggleRecording()
        let secondRecordingLevel = AudioLevels(system: 0.7, microphone: 0.8)
        let secondBarrier = RecordingFailure(code: .microphone, message: "second recording barrier")
        session.yield(.levels(secondRecordingLevel))
        session.yield(.warning(secondBarrier))
        await waitForPhase(
            .recording(
                ActiveRecording(
                    startedAt: Date(timeIntervalSinceReferenceDate: 0.04),
                    workingURL: URL(fileURLWithPath: "/tmp/meeting-recording-working.m4a")
                ),
                warning: secondBarrier
            ),
            coordinator: coordinator
        )

        XCTAssertEqual(recorder.values, [firstRecordingLevel, secondRecordingLevel])
        levelClock.advance(milliseconds: 60)
        await Task.yield()
        XCTAssertEqual(recorder.values, [firstRecordingLevel, secondRecordingLevel])
    }

    func testWallClockAdvanceDoesNotBypassMonotonicLevelThrottle() async {
        let wallClock = LockedCoordinatorTestClock()
        let levelClock = ManualCoordinatorLevelClock()
        let session = SessionManagerSpy()
        let coordinator = RecordingCoordinator(
            session: session,
            now: wallClock.now,
            levelClock: levelClock
        )
        let recorder = AudioLevelPublicationRecorder(coordinator: coordinator)
        await coordinator.toggleRecording()
        await waitForEventSubscription(session)

        let beforeClockChange = AudioLevels(system: 0.1, microphone: 0.2)
        session.yield(.levels(beforeClockChange))
        await waitForAudioPublicationCount(1, recorder: recorder)

        wallClock.advance(milliseconds: 1_000)
        levelClock.advance(milliseconds: 20)
        let afterClockChange = AudioLevels(system: 0.7, microphone: 0.8)
        let barrier = RecordingFailure(code: .microphone, message: "clock advance barrier")
        session.yield(.levels(afterClockChange))
        session.yield(.warning(barrier))
        await waitForPhase(
            .recording(
                ActiveRecording(
                    startedAt: Date(timeIntervalSinceReferenceDate: 0),
                    workingURL: URL(fileURLWithPath: "/tmp/meeting-recording-working.m4a")
                ),
                warning: barrier
            ),
            coordinator: coordinator
        )

        XCTAssertEqual(recorder.values, [beforeClockChange])

        levelClock.advance(milliseconds: 80)
        await waitForAudioPublicationCount(2, recorder: recorder)
        XCTAssertEqual(recorder.values, [beforeClockChange, afterClockChange])
    }

    func testWallClockRegressionDoesNotBypassMonotonicLevelThrottle() async {
        let wallClock = LockedCoordinatorTestClock()
        let levelClock = ManualCoordinatorLevelClock()
        let session = SessionManagerSpy()
        let coordinator = RecordingCoordinator(
            session: session,
            now: wallClock.now,
            levelClock: levelClock
        )
        let recorder = AudioLevelPublicationRecorder(coordinator: coordinator)
        await coordinator.toggleRecording()
        await waitForEventSubscription(session)

        let beforeClockChange = AudioLevels(system: 0.1, microphone: 0.2)
        session.yield(.levels(beforeClockChange))
        await waitForAudioPublicationCount(1, recorder: recorder)

        wallClock.advance(milliseconds: -1_000)
        levelClock.advance(milliseconds: 20)
        let afterClockChange = AudioLevels(system: 0.7, microphone: 0.8)
        let barrier = RecordingFailure(code: .microphone, message: "clock regression barrier")
        session.yield(.levels(afterClockChange))
        session.yield(.warning(barrier))
        await waitForPhase(
            .recording(
                ActiveRecording(
                    startedAt: Date(timeIntervalSinceReferenceDate: 0),
                    workingURL: URL(fileURLWithPath: "/tmp/meeting-recording-working.m4a")
                ),
                warning: barrier
            ),
            coordinator: coordinator
        )

        XCTAssertEqual(recorder.values, [beforeClockChange])

        levelClock.advance(milliseconds: 80)
        await waitForAudioPublicationCount(2, recorder: recorder)
        XCTAssertEqual(recorder.values, [beforeClockChange, afterClockChange])
    }

    func testStopControlIsNotDelayedByActiveLevelThrottleWindow() async {
        let wallClock = LockedCoordinatorTestClock()
        let levelClock = ManualCoordinatorLevelClock()
        let session = SessionManagerSpy()
        let coordinator = RecordingCoordinator(
            session: session,
            now: wallClock.now,
            levelClock: levelClock
        )
        let recorder = AudioLevelPublicationRecorder(coordinator: coordinator)
        await coordinator.toggleRecording()
        await waitForEventSubscription(session)

        let leading = AudioLevels(system: 0.1, microphone: 0.2)
        session.yield(.levels(leading))
        await waitForAudioPublicationCount(1, recorder: recorder)
        levelClock.advance(milliseconds: 20)
        session.yield(.levels(AudioLevels(system: 0.3, microphone: 0.4)))
        let barrier = RecordingFailure(code: .microphone, message: "stop control barrier")
        session.yield(.warning(barrier))
        await waitForPhase(
            .recording(
                ActiveRecording(
                    startedAt: Date(timeIntervalSinceReferenceDate: 0),
                    workingURL: URL(fileURLWithPath: "/tmp/meeting-recording-working.m4a")
                ),
                warning: barrier
            ),
            coordinator: coordinator
        )
        await coordinator.toggleRecording()

        XCTAssertEqual(session.stopCallCount, 1)
        XCTAssertEqual(coordinator.phase, .idle)
        levelClock.advance(milliseconds: 80)
        await Task.yield()
        XCTAssertEqual(recorder.values, [leading])
    }

    func testToggleIsIgnoredWhilePreparing() async {
        let session = SessionManagerSpy()
        session.suspendStart = true
        let coordinator = RecordingCoordinator(session: session)

        let startTask = Task { await coordinator.toggleRecording() }
        guard await waitForStartSuspension(session, coordinator) else {
            return
        }
        await coordinator.toggleRecording()

        XCTAssertEqual(session.startCallCount, 1)
        XCTAssertEqual(coordinator.phase, .preparing)
        session.finishStart()
        await startTask.value
        XCTAssertEqual(coordinator.phase, .recording(
            ActiveRecording(
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                workingURL: URL(fileURLWithPath: "/tmp/meeting-recording-working.m4a")
            ),
            warning: nil
        ))
    }

    func testToggleIsIgnoredWhileStopping() async {
        let session = SessionManagerSpy()
        let coordinator = RecordingCoordinator(session: session)
        await coordinator.toggleRecording()
        session.suspendStop = true

        let stopTask = Task { await coordinator.toggleRecording() }
        guard await waitForStopSuspension(session, coordinator) else {
            return
        }
        await coordinator.toggleRecording()

        XCTAssertEqual(session.stopCallCount, 1)
        if case .stopping = coordinator.phase {
            // Expected: the repeated toggle must not start another operation.
        } else {
            XCTFail("expected stopping")
        }
        session.finishStop()
        await stopTask.value
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testStartSuccessDoesNotOverwriteEventFailureWhileSuspended() async {
        let session = SessionManagerSpy()
        session.suspendStart = true
        let coordinator = RecordingCoordinator(session: session)
        await waitForEventSubscription(session)

        let startTask = Task { await coordinator.toggleRecording() }
        guard await waitForStartSuspension(session, coordinator) else {
            return
        }

        let expected = RecordingFailure(code: .capture, message: "session failed")
        session.yield(.failed(expected))
        for _ in 0..<100 {
            await Task.yield()
            if coordinator.phase == .failed(expected) {
                break
            }
        }
        XCTAssertEqual(coordinator.phase, .failed(expected))

        session.finishStart()
        await startTask.value
        XCTAssertEqual(coordinator.phase, .failed(expected))
    }

    func testStopSuccessDoesNotOverwriteEventFailureWhileSuspended() async {
        let session = SessionManagerSpy()
        let coordinator = RecordingCoordinator(session: session)
        await coordinator.toggleRecording()
        await waitForEventSubscription(session)
        session.suspendStop = true

        let stopTask = Task { await coordinator.toggleRecording() }
        guard await waitForStopSuspension(session, coordinator) else {
            return
        }

        let expected = RecordingFailure(code: .write, message: "write failed")
        session.yield(.failed(expected))
        for _ in 0..<100 {
            await Task.yield()
            if coordinator.phase == .failed(expected) {
                break
            }
        }
        XCTAssertEqual(coordinator.phase, .failed(expected))

        session.finishStop()
        await stopTask.value
        XCTAssertEqual(coordinator.phase, .failed(expected))
    }

    func testStartFailurePreservesRecordingFailure() async {
        let expected = RecordingFailure(code: .permission, message: "permission denied")
        let session = SessionManagerSpy()
        session.startError = expected
        let coordinator = RecordingCoordinator(session: session)

        await coordinator.toggleRecording()

        XCTAssertEqual(coordinator.phase, .failed(expected))
    }

    func testStartFailureCancelsPendingLevelPublication() async {
        let wallClock = LockedCoordinatorTestClock()
        let levelClock = ManualCoordinatorLevelClock()
        let session = SessionManagerSpy()
        session.suspendStart = true
        let coordinator = RecordingCoordinator(
            session: session,
            now: wallClock.now,
            levelClock: levelClock
        )
        let recorder = AudioLevelPublicationRecorder(coordinator: coordinator)
        await waitForEventSubscription(session)

        let startTask = Task { await coordinator.toggleRecording() }
        guard await waitForStartSuspension(session, coordinator) else {
            return
        }

        let leading = AudioLevels(system: 0.1, microphone: 0.2)
        session.yield(.levels(leading))
        await waitForAudioPublicationCount(1, recorder: recorder)
        levelClock.advance(milliseconds: 20)
        session.yield(.levels(AudioLevels(system: 0.3, microphone: 0.4)))
        await waitForLevelSleeper(levelClock)

        let expected = RecordingFailure(code: .capture, message: "start failed after capture")
        session.finishStart(throwing: expected)
        await startTask.value
        XCTAssertEqual(coordinator.phase, .failed(expected))

        levelClock.advance(milliseconds: 80)
        await Task.yield()
        XCTAssertEqual(recorder.values, [leading])
    }

    func testUnknownFailureMapsToCapture() async {
        struct UnknownError: LocalizedError {
            var errorDescription: String? { "unknown failure" }
        }

        let session = SessionManagerSpy()
        session.startError = UnknownError()
        let coordinator = RecordingCoordinator(session: session)

        await coordinator.toggleRecording()

        XCTAssertEqual(
            coordinator.phase,
            .failed(RecordingFailure(code: .capture, message: "unknown failure"))
        )
    }
}
