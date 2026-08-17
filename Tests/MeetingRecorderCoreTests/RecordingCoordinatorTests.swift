import Foundation
import XCTest
@testable import MeetingRecorderCore

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
