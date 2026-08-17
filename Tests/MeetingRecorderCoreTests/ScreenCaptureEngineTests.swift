import Foundation
import ScreenCaptureKit
import XCTest
@testable import MeetingRecorderCore

final class ScreenCaptureEngineTests: XCTestCase {
    func testConfigurationCapturesBothSources() {
        let configuration = ScreenCaptureEngine.makeConfiguration(
            microphoneDeviceID: "mic-1"
        )

        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertTrue(configuration.captureMicrophone)
        XCTAssertEqual(configuration.microphoneCaptureDeviceID, "mic-1")
        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.channelCount, 2)
        XCTAssertTrue(configuration.excludesCurrentProcessAudio)
        XCTAssertEqual(configuration.width, 2)
        XCTAssertEqual(configuration.height, 2)
        XCTAssertEqual(
            configuration.minimumFrameInterval,
            CMTime(value: 1, timescale: 1)
        )
    }

    func testOutputTypesRouteOnlyAudioSamples() {
        XCTAssertEqual(ScreenCaptureEngine.source(for: .audio), .system)
        XCTAssertEqual(ScreenCaptureEngine.source(for: .microphone), .microphone)
        XCTAssertNil(ScreenCaptureEngine.source(for: .screen))
    }

    func testConcurrentStartIsRejectedBeforeFirstStartResumes() async throws {
        let first = TestBackendControl(suspendsStart: true)
        let unexpectedSecond = TestBackendControl()
        let factory = TestBackendFactory([first, unexpectedSecond])
        let engine = ScreenCaptureEngine(backendFactory: factory.make)

        let firstStart = Task {
            try await engine.start { _ in }
        }
        await first.waitUntilStartEntered()

        do {
            try await engine.start { _ in }
            XCTFail("A concurrent start must be rejected.")
        } catch {}

        first.openStartGate()
        try await firstStart.value
        await engine.stop()

        XCTAssertEqual(first.startCallCount, 1)
        XCTAssertEqual(unexpectedSecond.startCallCount, 0)
    }

    func testStopWhileStartingCancelsThatSessionAndAllowsRestart() async throws {
        let first = TestBackendControl(suspendsStart: true)
        let second = TestBackendControl()
        let factory = TestBackendFactory([first, second])
        let engine = ScreenCaptureEngine(backendFactory: factory.make)

        let firstStart = Task {
            try await engine.start { _ in }
        }
        await first.waitUntilStartEntered()

        let stop = Task {
            await engine.stop()
        }
        await first.waitUntilStartWasCancelled()
        first.openStartGate()
        await stop.value

        do {
            try await firstStart.value
            XCTFail("A stopped in-flight start must not become running.")
        } catch {}

        try await engine.start { _ in }
        await engine.stop()

        XCTAssertEqual(first.stopCallCount, 1)
        XCTAssertEqual(second.startCallCount, 1)
    }

    func testCancellingStartCallerCleansSessionAndAllowsRestart() async throws {
        let first = TestBackendControl(suspendsStart: true)
        let second = TestBackendControl()
        let factory = TestBackendFactory([first, second])
        let engine = ScreenCaptureEngine(backendFactory: factory.make)
        let cancelledSessionEvents = TestEventRecorder()

        let cancelledStart = Task {
            try await engine.start { event in
                await cancelledSessionEvents.record(event)
            }
        }
        await first.waitUntilStartEntered()

        cancelledStart.cancel()
        first.openStartGate()
        let result = await cancelledStart.result
        if case .success = result {
            XCTFail("A cancelled start caller must not leave capture running.")
            await engine.stop()
        }
        if case let .failure(error) = result {
            XCTAssertTrue(error is CancellationError)
        }

        try await engine.start { _ in }
        await engine.stop()

        let cancelledStoppedEvents = await cancelledSessionEvents.stoppedEventCount
        XCTAssertEqual(first.startCancellationCount, 1)
        XCTAssertEqual(first.stopCallCount, 1)
        XCTAssertEqual(second.startCallCount, 1)
        XCTAssertEqual(cancelledStoppedEvents, 0)
    }

    func testUnexpectedStopCleansUpOnceAndAllowsRestart() async throws {
        let first = TestBackendControl()
        let second = TestBackendControl()
        let factory = TestBackendFactory([first, second])
        let engine = ScreenCaptureEngine(backendFactory: factory.make)
        let events = TestEventRecorder()

        try await engine.start { event in
            await events.record(event)
        }
        let failure = RecordingFailure(code: .capture, message: "stream lost")
        await first.emit(.stopped(failure))
        await events.waitForStoppedEvent()

        try await engine.start { _ in }
        await first.emit(.stopped(failure))
        await engine.stop()

        let stoppedEventCount = await events.stoppedEventCount
        let firstStoppedFailure = await events.firstStoppedFailure
        XCTAssertEqual(first.stopCallCount, 1)
        XCTAssertEqual(stoppedEventCount, 1)
        XCTAssertEqual(firstStoppedFailure, failure)
        XCTAssertEqual(second.startCallCount, 1)
    }

    func testEventHandlerCanStopEngineWithoutDeliveryTaskDeadlock() async throws {
        let backend = TestBackendControl()
        let factory = TestBackendFactory([backend])
        let engine = ScreenCaptureEngine(backendFactory: factory.make)
        let stopReturned = expectation(description: "stop returned from event handler")
        let stoppedDelivered = expectation(description: "stopped event delivered")

        try await engine.start { event in
            switch event {
            case .warning:
                await engine.stop()
                stopReturned.fulfill()
            case .stopped:
                stoppedDelivered.fulfill()
            default:
                break
            }
        }

        await backend.emit(.warning(RecordingFailure(
            code: .microphone,
            message: "test warning"
        )))

        await fulfillment(of: [stopReturned, stoppedDelivered], timeout: 1)
        XCTAssertEqual(backend.stopCallCount, 1)
    }

    func testConcurrentStopSharesCleanupAndDeliversStoppedOnce() async throws {
        let backend = TestBackendControl(suspendsStop: true)
        let factory = TestBackendFactory([backend])
        let engine = ScreenCaptureEngine(backendFactory: factory.make)
        let events = TestEventRecorder()

        try await engine.start { event in
            await events.record(event)
        }
        let firstStop = Task { await engine.stop() }
        await backend.waitUntilStopEntered()
        let secondStop = Task { await engine.stop() }
        backend.openStopGate()

        await firstStop.value
        await secondStop.value
        await events.waitForStoppedEvent()

        let stoppedEventCount = await events.stoppedEventCount
        XCTAssertEqual(backend.stopCallCount, 1)
        XCTAssertEqual(stoppedEventCount, 1)
    }

    func testProbeMetricsPreserveFirstStoppingFailure() {
        var metrics = AudioCaptureProbeMetrics()
        let failure = RecordingFailure(code: .capture, message: "stream failed")

        metrics.consume(.stopped(failure))
        metrics.consume(.stopped(nil))
        let snapshot = metrics.snapshot

        XCTAssertEqual(snapshot.stoppedEventCount, 2)
        XCTAssertEqual(snapshot.stoppedFailure, failure)
        XCTAssertFalse(snapshot.passedCaptureChecks)
    }

    func testProbeMetricsRejectInvalidAndNonNumericPresentationTimes() {
        var source = AudioSourceProbeMetrics()

        source.record(.invalid)
        source.record(.indefinite)
        source.record(.positiveInfinity)
        source.record(CMTime(value: 1, timescale: 48_000))
        source.record(CMTime(value: 2, timescale: 48_000))

        XCTAssertEqual(source.sampleCount, 5)
        XCTAssertEqual(source.invalidPresentationTimeCount, 3)
        XCTAssertFalse(source.presentationTimesAreStrictlyIncreasing)
    }
}

private final class TestBackendFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var controls: [TestBackendControl]

    init(_ controls: [TestBackendControl]) {
        self.controls = controls
    }

    func make(
        eventHandler: @escaping @Sendable (AudioCaptureEvent) async -> Void
    ) -> any ScreenCaptureBackend {
        lock.lock()
        defer { lock.unlock() }
        precondition(!controls.isEmpty, "No test backend remains")
        return TestScreenCaptureBackend(
            control: controls.removeFirst(),
            eventHandler: eventHandler
        )
    }
}

private final class TestBackendControl: @unchecked Sendable {
    private let lock = NSLock()
    private let suspendsStart: Bool
    private let suspendsStop: Bool
    private let startEntered = AsyncStream<Void>.makeStream()
    private let startCancelled = AsyncStream<Void>.makeStream()
    private let stopEntered = AsyncStream<Void>.makeStream()
    private let startGate = TestAsyncGate()
    private let stopGate = TestAsyncGate()
    private var eventHandler: (@Sendable (AudioCaptureEvent) async -> Void)?
    private var _startCallCount = 0
    private var _startCancellationCount = 0
    private var _stopCallCount = 0

    init(suspendsStart: Bool = false, suspendsStop: Bool = false) {
        self.suspendsStart = suspendsStart
        self.suspendsStop = suspendsStop
    }

    var startCallCount: Int {
        lock.withLock { _startCallCount }
    }

    var stopCallCount: Int {
        lock.withLock { _stopCallCount }
    }

    var startCancellationCount: Int {
        lock.withLock { _startCancellationCount }
    }

    func waitUntilStartEntered() async {
        var iterator = startEntered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitUntilStartWasCancelled() async {
        var iterator = startCancelled.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitUntilStopEntered() async {
        var iterator = stopEntered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func openStartGate() {
        Task { await startGate.open() }
    }

    func openStopGate() {
        Task { await stopGate.open() }
    }

    func emit(_ event: AudioCaptureEvent) async {
        let handler = lock.withLock { eventHandler }
        await handler?(event)
    }

    fileprivate func attach(
        eventHandler: @escaping @Sendable (AudioCaptureEvent) async -> Void
    ) {
        lock.withLock {
            self.eventHandler = eventHandler
        }
    }

    fileprivate func start() async throws {
        lock.withLock { _startCallCount += 1 }
        startEntered.continuation.yield()
        guard suspendsStart else { return }

        await withTaskCancellationHandler {
            await startGate.wait()
        } onCancel: {
            self.lock.withLock { self._startCancellationCount += 1 }
            self.startCancelled.continuation.yield()
        }
        try Task.checkCancellation()
    }

    fileprivate func stop() async -> RecordingFailure? {
        lock.withLock { _stopCallCount += 1 }
        stopEntered.continuation.yield()
        if suspendsStop {
            await stopGate.wait()
        }
        return nil
    }
}

private struct TestScreenCaptureBackend: ScreenCaptureBackend {
    let control: TestBackendControl

    init(
        control: TestBackendControl,
        eventHandler: @escaping @Sendable (AudioCaptureEvent) async -> Void
    ) {
        self.control = control
        control.attach(eventHandler: eventHandler)
    }

    func start() async throws {
        try await control.start()
    }

    func stop() async -> RecordingFailure? {
        await control.stop()
    }

    func updateDefaultMicrophone() async throws {}
}

private actor TestAsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor TestEventRecorder {
    private var events: [AudioCaptureEvent] = []
    private let stopped = AsyncStream<Void>.makeStream()

    func record(_ event: AudioCaptureEvent) {
        events.append(event)
        if case .stopped = event {
            stopped.continuation.yield()
        }
    }

    func waitForStoppedEvent() async {
        if stoppedEventCount > 0 { return }
        var iterator = stopped.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    var stoppedEventCount: Int {
        events.reduce(into: 0) { count, event in
            if case .stopped = event {
                count += 1
            }
        }
    }

    var firstStoppedFailure: RecordingFailure? {
        for event in events {
            if case let .stopped(failure) = event {
                return failure
            }
        }
        return nil
    }
}
