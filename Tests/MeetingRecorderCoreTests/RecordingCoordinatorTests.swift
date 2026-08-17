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

    let eventStream: AsyncStream<RecordingSessionEvent>
    private let eventContinuation: AsyncStream<RecordingSessionEvent>.Continuation

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
        return ActiveRecording(
            startedAt: date,
            workingURL: URL(fileURLWithPath: "/tmp/meeting-recording-working.m4a")
        )
    }

    func stop() async throws -> SavedRecording {
        stopCallCount += 1
        if let stopError {
            throw stopError
        }
        return SavedRecording(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1,
            fileURL: URL(fileURLWithPath: "/tmp/meeting-recording.m4a"),
            recovered: false
        )
    }

    func yield(_ event: RecordingSessionEvent) {
        eventContinuation.yield(event)
    }
}

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    private func waitForEventSubscription(_ session: SessionManagerSpy) async {
        for _ in 0..<100 where session.eventsCallCount == 0 {
            await Task.yield()
        }
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

    func testToggleIsIgnoredWhilePreparingOrStopping() async {
        let session = SessionManagerSpy()
        let coordinator = RecordingCoordinator(session: session)
        await coordinator.toggleRecording()
        await coordinator.toggleRecording()

        XCTAssertEqual(session.startCallCount, 1)
        XCTAssertEqual(session.stopCallCount, 1)
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
