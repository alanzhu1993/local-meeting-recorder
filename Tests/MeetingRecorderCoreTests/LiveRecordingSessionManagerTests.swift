import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import MeetingRecorderCore

final class LiveRecordingSessionManagerTests: XCTestCase {
    func testStartRollsBackInReverseOrderWhenCaptureFailsAndReleasesReservationOnce() async throws {
        let harness = try SessionHarness(captureStartError: SessionTestError.capture)

        do {
            _ = try await harness.manager.start(at: harness.startDate)
            XCTFail("Expected start to fail.")
        } catch {}

        let abortCallCount = await harness.writer.abortCallCount
        let stopCallCount = await harness.capture.stopCallCount
        let releasedURLs = await harness.store.releasedURLs
        XCTAssertEqual(abortCallCount, 1)
        XCTAssertEqual(stopCallCount, 1)
        XCTAssertEqual(harness.sleep.endCallCount, 1)
        XCTAssertEqual(releasedURLs, [harness.paths.finalURL])
        XCTAssertEqual(
            harness.calls.values,
            [
                "permission.status", "store.prepare", "sleep.begin",
                "writer.start", "store.release", "capture.start",
                "capture.stop", "writer.abort", "sleep.end", "notification.failed",
            ]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.paths.workingURL.path))
    }

    func testWriterStartFailureAbortsAndReleasesPreparationReservation() async throws {
        let harness = try SessionHarness(writerStartError: SessionTestError.write)

        await XCTAssertThrowsErrorAsync {
            _ = try await harness.manager.start(at: harness.startDate)
        }

        let abortCallCount = await harness.writer.abortCallCount
        let captureStartCallCount = await harness.capture.startCallCount
        let releasedURLs = await harness.store.releasedURLs
        XCTAssertEqual(abortCallCount, 1)
        XCTAssertEqual(captureStartCallCount, 0)
        XCTAssertEqual(releasedURLs, [harness.paths.finalURL])
        XCTAssertEqual(harness.sleep.endCallCount, 1)
    }

    func testDeniedPermissionStopsBeforePreparingStorage() async throws {
        let harness = try SessionHarness(permissionGranted: false)

        do {
            _ = try await harness.manager.start(at: harness.startDate)
            XCTFail("Expected permission failure.")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .permission)
        }

        let prepareCallCount = await harness.store.prepareCallCount
        let writerStartCallCount = await harness.writer.startCallCount
        XCTAssertEqual(prepareCallCount, 0)
        XCTAssertEqual(harness.sleep.beginCallCount, 0)
        XCTAssertEqual(writerStartCallCount, 0)
    }

    func testRecoveryInProgressRejectsStartBeforeCheckingPermissionsOrStorage() async throws {
        let harness = try SessionHarness(recoveryInProgress: true)

        do {
            _ = try await harness.manager.start(at: harness.startDate)
            XCTFail("Expected recovery coordination failure.")
        } catch let failure as RecordingFailure {
            XCTAssertTrue(failure.message.contains("正在恢复"))
        }

        let prepareCallCount = await harness.store.prepareCallCount
        XCTAssertEqual(prepareCallCount, 0)
        XCTAssertEqual(harness.sleep.beginCallCount, 0)
        XCTAssertEqual(harness.calls.values.first, "notification.failed")
    }

    func testConcurrentStopDuringStartingInterruptsAndCleansUpExactlyOnce() async throws {
        let startGate = SessionAsyncGate()
        let harness = try SessionHarness(captureStartGate: startGate)
        let start = Task { try await harness.manager.start(at: harness.startDate) }
        await harness.capture.waitUntilStartEntered()

        let stop = Task { try await harness.manager.stop() }
        _ = await start.result
        _ = await stop.result

        let stopCallCount = await harness.capture.stopCallCount
        let abortCallCount = await harness.writer.abortCallCount
        let releasedURLs = await harness.store.releasedURLs
        XCTAssertEqual(stopCallCount, 1)
        XCTAssertEqual(abortCallCount, 1)
        XCTAssertEqual(harness.sleep.endCallCount, 1)
        XCTAssertEqual(releasedURLs, [harness.paths.finalURL])
    }

    func testStopRejectsNewSamplesDrainsAcceptedWorkAndUsesRequiredOrder() async throws {
        let appendGate = SessionAsyncGate()
        let harness = try SessionHarness(writerAppendGate: appendGate)
        _ = try await harness.manager.start(at: harness.startDate)
        await harness.capture.emit(try harness.sampleEvent(source: .system, amplitude: 0.5))
        await harness.writer.waitUntilAppendEntered()

        let stop = Task { try await harness.manager.stop() }
        await harness.capture.waitUntilStopCalled()
        await harness.capture.emit(try harness.sampleEvent(source: .microphone, amplitude: 0.25))
        let appendCountWhileStopped = await harness.writer.appendCallCount
        XCTAssertEqual(appendCountWhileStopped, 1)

        await appendGate.open()
        let saved = try await stop.value

        XCTAssertEqual(saved.fileURL, harness.paths.finalURL)
        XCTAssertEqual(
            Array(harness.calls.values.filter {
                ["capture.stop", "mixer.flush", "writer.finish", "sleep.end"].contains($0)
            }.suffix(4)),
            ["capture.stop", "mixer.flush", "writer.finish", "sleep.end"]
        )
        let finalAppendCallCount = await harness.writer.appendCallCount
        let savedCallCount = await harness.notifications.savedCallCount
        XCTAssertEqual(finalAppendCallCount, 1)
        XCTAssertEqual(savedCallCount, 1)
    }

    func testMicrophoneWarningAndChangeContinueRecording() async throws {
        let harness = try SessionHarness()
        let events = await harness.manager.events()
        let recorder = SessionEventRecorder(events: events)
        _ = try await harness.manager.start(at: harness.startDate)

        let microphoneWarning = RecordingFailure(code: .microphone, message: "mic temporarily unavailable")
        await harness.capture.emit(.warning(microphoneWarning))
        await harness.capture.emit(.microphoneChanged("USB microphone"))
        await harness.capture.emit(try harness.sampleEvent(source: .system, amplitude: 0.5))
        await harness.writer.waitUntilAppendCount(1)

        let stopCallCount = await harness.capture.stopCallCount
        let appendCallCount = await harness.writer.appendCallCount
        XCTAssertEqual(stopCallCount, 0)
        XCTAssertEqual(appendCallCount, 1)
        let warnings = await recorder.waitForWarningCount(2)
        XCTAssertEqual(warnings.first, microphoneWarning)

        _ = try await harness.manager.stop()
        await recorder.cancel()
    }

    func testLevelsReportIndependentSystemAndMicrophoneRMS() async throws {
        let harness = try SessionHarness()
        let events = await harness.manager.events()
        let recorder = SessionEventRecorder(events: events)
        _ = try await harness.manager.start(at: harness.startDate)

        await harness.capture.emit(try harness.sampleEvent(source: .system, amplitude: 0.5))
        await harness.capture.emit(try harness.sampleEvent(source: .microphone, amplitude: 0.25))
        let levels = await recorder.waitForLevelCount(2)

        XCTAssertEqual(levels.last?.system ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(levels.last?.microphone ?? 0, 0.25, accuracy: 0.0001)

        _ = try await harness.manager.stop()
        await recorder.cancel()
    }

    func testEarlierInitialSampleFromSecondSourceIsTrimmedInsteadOfFailingWriter() async throws {
        let harness = try SessionHarness()
        harness.converter.forceStartFrames([0, -2])
        _ = try await harness.manager.start(at: harness.startDate)

        await harness.capture.emit(try harness.sampleEvent(source: .system, amplitude: 0.5))
        await harness.capture.emit(try harness.sampleEvent(source: .microphone, amplitude: 0.25))
        await harness.writer.waitUntilAppendCount(2)

        let saved = try await harness.manager.stop()
        let appendedStartFrames = await harness.writer.appendedStartFrames
        XCTAssertEqual(saved.fileURL, harness.paths.finalURL)
        XCTAssertEqual(appendedStartFrames, [0, 0])
    }

    func testWriterFailureAndRepeatedCaptureStopTriggerOneTerminalCleanup() async throws {
        let appendFailure = RecordingFailure(code: .write, message: "encoder failed")
        let harness = try SessionHarness(writerAppendError: appendFailure)
        let events = await harness.manager.events()
        let recorder = SessionEventRecorder(events: events)
        _ = try await harness.manager.start(at: harness.startDate)

        await harness.capture.emit(try harness.sampleEvent(source: .system, amplitude: 0.5))
        await harness.capture.emit(.stopped(RecordingFailure(code: .capture, message: "stream stopped")))
        await harness.capture.emit(.stopped(nil))
        let failures = await recorder.waitForFailureCount(1)
        await harness.waitUntilIdleCleanup()

        XCTAssertEqual(failures, [appendFailure])
        let stopCallCount = await harness.capture.stopCallCount
        let abortCallCount = await harness.writer.abortCallCount
        let failedCallCount = await harness.notifications.failedCallCount
        XCTAssertEqual(stopCallCount, 1)
        XCTAssertEqual(abortCallCount, 1)
        XCTAssertEqual(harness.sleep.endCallCount, 1)
        XCTAssertEqual(failedCallCount, 1)
        await recorder.cancel()
    }

    func testUnexpectedSystemCaptureStopIsFatalAndCleansUpOnce() async throws {
        let harness = try SessionHarness()
        let events = await harness.manager.events()
        let recorder = SessionEventRecorder(events: events)
        _ = try await harness.manager.start(at: harness.startDate)
        let captureFailure = RecordingFailure(code: .capture, message: "system stream lost")

        await harness.capture.emit(.stopped(captureFailure))
        await harness.capture.emit(.stopped(nil))
        let failures = await recorder.waitForFailureCount(1)
        await harness.waitUntilIdleCleanup()

        let stopCallCount = await harness.capture.stopCallCount
        let abortCallCount = await harness.writer.abortCallCount
        XCTAssertEqual(failures, [captureFailure])
        XCTAssertEqual(stopCallCount, 1)
        XCTAssertEqual(abortCallCount, 1)
        XCTAssertEqual(harness.sleep.endCallCount, 1)
        await recorder.cancel()
    }

    func testBoundedSampleQueueDropsUnderWriterBackpressureAndEmitsWarning() async throws {
        let appendGate = SessionAsyncGate()
        let harness = try SessionHarness(writerAppendGate: appendGate, sampleQueueCapacity: 3)
        let events = await harness.manager.events()
        let recorder = SessionEventRecorder(events: events)
        _ = try await harness.manager.start(at: harness.startDate)

        await harness.capture.emit(try harness.sampleEvent(source: .system, amplitude: 0.5))
        await harness.writer.waitUntilAppendEntered()
        for _ in 0..<20 {
            await harness.capture.emit(try harness.sampleEvent(source: .system, amplitude: 0.5))
        }
        let warnings = await recorder.waitForWarningCount(1)

        XCTAssertTrue(warnings.contains { $0.message.contains("处理速度") })
        await appendGate.open()
        _ = try await harness.manager.stop()
        let appendCallCount = await harness.writer.appendCallCount
        XCTAssertLessThanOrEqual(appendCallCount, 5)
        await recorder.cancel()
    }

    func testRealConverterMixerAndFragmentedWriterCommitPlayableM4A() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = SessionCallLog()
        let capture = SessionCaptureSpy(startError: nil, startGate: nil, calls: calls)
        let permissions = SessionPermissionSpy(granted: true, calls: calls)
        let sleep = SessionSleepSpy(calls: calls)
        let notifications = SessionNotificationSpy(calls: calls)
        let store = RecordingStore(
            root: root,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            availableCapacity: { 2_000_000_000 }
        )
        let startedAt = Date(timeIntervalSince1970: 1_777_777_777)
        let manager = LiveRecordingSessionManager(
            store: store,
            capture: capture,
            permissions: permissions,
            sleep: sleep,
            notifications: notifications,
            writerFactory: { RecoverableAudioWriterFactory.make(workingURL: $0) },
            converterFactory: { SampleBufferConverter() },
            mixerFactory: {
                AudioTimelineMixer(sampleRate: 48_000, channels: 2, chunkFrames: 960)
            },
            now: { startedAt.addingTimeInterval(1) },
            sampleQueueCapacity: 64,
            recoveryInProgress: { false }
        )
        _ = try await manager.start(at: startedAt)

        let inputSampleRate = 48_000.0
        for index in 0..<20 {
            let presentationTime = CMTime(value: Int64(index * 960), timescale: 48_000)
            let values = (0..<960).flatMap { sample -> [Float] in
                let value = Float(0.1 * sin(
                    2 * Double.pi * 440 * Double(index * 960 + sample) / inputSampleRate
                ))
                return [value, value]
            }
            for source in [CapturedAudioSource.system, .microphone] {
                let buffer = try AudioTestFactory.float32InterleavedSampleBuffer(
                    sampleRate: inputSampleRate,
                    channels: 2,
                    values: values,
                    presentationTime: presentationTime
                )
                await capture.emit(.sample(CapturedAudioSample(
                    source: source,
                    buffer: buffer,
                    presentationTime: presentationTime
                )))
            }
        }

        let saved = try await manager.stop()
        let asset = AVURLAsset(url: saved.fileURL)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let savedCallCount = await notifications.savedCallCount

        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.fileURL.path))
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.3)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(savedCallCount, 1)
        XCTAssertEqual(sleep.endCallCount, 1)
    }
}

private enum SessionTestError: Error {
    case capture
    case write
}

private final class SessionHarness: @unchecked Sendable {
    let startDate = Date(timeIntervalSince1970: 1_777_777_777)
    let directory: URL
    let paths: RecordingPaths
    let calls: SessionCallLog
    let store: SessionStoreSpy
    let permissions: SessionPermissionSpy
    let capture: SessionCaptureSpy
    let writer: SessionWriterSpy
    let sleep: SessionSleepSpy
    let notifications: SessionNotificationSpy
    let converter: SessionConverterSpy
    let manager: LiveRecordingSessionManager

    init(
        permissionGranted: Bool = true,
        captureStartError: Error? = nil,
        captureStartGate: SessionAsyncGate? = nil,
        writerStartError: Error? = nil,
        writerAppendError: RecordingFailure? = nil,
        writerAppendGate: SessionAsyncGate? = nil,
        sampleQueueCapacity: Int = 16,
        recoveryInProgress: Bool = false
    ) throws {
        let callLog = SessionCallLog()
        calls = callLog
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let finalURL = directory.appendingPathComponent("meeting.m4a")
        paths = RecordingPaths(
            startedAt: startDate,
            directoryURL: directory,
            workingURL: directory.appendingPathComponent(".meeting.inprogress.mov"),
            finalURL: finalURL,
            recoveredURL: directory.appendingPathComponent("meeting-recovered.m4a")
        )
        store = SessionStoreSpy(paths: paths, calls: callLog)
        permissions = SessionPermissionSpy(granted: permissionGranted, calls: callLog)
        capture = SessionCaptureSpy(startError: captureStartError, startGate: captureStartGate, calls: callLog)
        writer = SessionWriterSpy(
            workingURL: paths.workingURL,
            startError: writerStartError,
            appendError: writerAppendError,
            appendGate: writerAppendGate,
            calls: callLog
        )
        sleep = SessionSleepSpy(calls: callLog)
        notifications = SessionNotificationSpy(calls: callLog)
        converter = SessionConverterSpy()
        manager = LiveRecordingSessionManager(
            store: store,
            capture: capture,
            permissions: permissions,
            sleep: sleep,
            notifications: notifications,
            writerFactory: { [writer] _ in writer },
            converterFactory: { [converter] in converter },
            mixerFactory: { SessionMixerSpy(calls: callLog) },
            now: { Date(timeIntervalSince1970: 1_777_777_807) },
            sampleQueueCapacity: sampleQueueCapacity,
            recoveryInProgress: { recoveryInProgress }
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func sampleEvent(source: CapturedAudioSource, amplitude: Float) throws -> AudioCaptureEvent {
        converter.setAmplitude(amplitude, for: source)
        let buffer = try AudioTestFactory.int16MonoSampleBuffer(
            sampleRate: 48_000,
            values: [1, 1, 1, 1],
            presentationTime: CMTime(value: converter.nextTimestamp, timescale: 48_000)
        )
        return .sample(CapturedAudioSample(
            source: source,
            buffer: buffer,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(buffer)
        ))
    }

    func waitUntilIdleCleanup() async {
        for _ in 0..<200 {
            if sleep.endCallCount == 1 { return }
            await Task.yield()
        }
    }
}

private final class SessionCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private actor SessionStoreSpy: RecordingSessionStoring {
    private let paths: RecordingPaths
    private let calls: SessionCallLog
    private(set) var prepareCallCount = 0
    private(set) var releasedURLs: [URL] = []

    init(paths: RecordingPaths, calls: SessionCallLog) {
        self.paths = paths
        self.calls = calls
    }

    func prepare(startedAt: Date) async throws -> RecordingPaths {
        prepareCallCount += 1
        calls.append("store.prepare")
        return paths
    }

    func releaseReservation(for outputURL: URL) async {
        releasedURLs.append(outputURL)
        calls.append("store.release")
    }
}

private actor SessionPermissionSpy: PermissionChecking {
    let granted: Bool
    let calls: SessionCallLog

    init(granted: Bool, calls: SessionCallLog) {
        self.granted = granted
        self.calls = calls
    }

    func currentStatus() async -> CapturePermissionStatus {
        calls.append("permission.status")
        return CapturePermissionStatus(missing: granted ? [] : [.systemAudio])
    }

    func requestMissingPermissions() async -> CapturePermissionStatus {
        await currentStatus()
    }
}

private actor SessionCaptureSpy: AudioCapturing {
    private let startError: Error?
    private let startGate: SessionAsyncGate?
    private let calls: SessionCallLog
    private let startEntered = AsyncStream<Void>.makeStream()
    private let stopCalled = AsyncStream<Void>.makeStream()
    private var handler: (@Sendable (AudioCaptureEvent) async -> Void)?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private var stopped = false

    init(startError: Error?, startGate: SessionAsyncGate?, calls: SessionCallLog) {
        self.startError = startError
        self.startGate = startGate
        self.calls = calls
    }

    func start(eventHandler: @escaping @Sendable (AudioCaptureEvent) async -> Void) async throws {
        startCallCount += 1
        calls.append("capture.start")
        handler = eventHandler
        startEntered.continuation.yield()
        if let startGate {
            await startGate.wait()
            if stopped { throw CancellationError() }
        }
        if let startError { throw startError }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        stopCallCount += 1
        calls.append("capture.stop")
        stopCalled.continuation.yield()
        await startGate?.open()
    }

    func updateDefaultMicrophone() async throws {}

    func emit(_ event: AudioCaptureEvent) async {
        await handler?(event)
    }

    func waitUntilStartEntered() async {
        var iterator = startEntered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitUntilStopCalled() async {
        var iterator = stopCalled.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

private actor SessionWriterSpy: RecoverableAudioWriting {
    private let workingURL: URL
    private let startError: Error?
    private let appendError: RecordingFailure?
    private let appendGate: SessionAsyncGate?
    private let calls: SessionCallLog
    private let appendEntered = AsyncStream<Void>.makeStream()
    private(set) var startCallCount = 0
    private(set) var appendCallCount = 0
    private(set) var abortCallCount = 0
    private(set) var appendedStartFrames: [Int64] = []

    init(
        workingURL: URL,
        startError: Error?,
        appendError: RecordingFailure?,
        appendGate: SessionAsyncGate?,
        calls: SessionCallLog
    ) {
        self.workingURL = workingURL
        self.startError = startError
        self.appendError = appendError
        self.appendGate = appendGate
        self.calls = calls
    }

    func start() async throws {
        startCallCount += 1
        calls.append("writer.start")
        if let startError { throw startError }
        FileManager.default.createFile(atPath: workingURL.path, contents: Data())
    }

    func append(_ chunk: MixedAudioChunk) async throws {
        appendCallCount += 1
        appendedStartFrames.append(chunk.startFrame)
        appendEntered.continuation.yield()
        if let appendGate { await appendGate.wait() }
        if let appendError { throw appendError }
        if chunk.startFrame < 0 {
            throw RecordingFailure(code: .write, message: "negative start frame")
        }
    }

    func finish(finalURL: URL) async throws -> URL {
        calls.append("writer.finish")
        FileManager.default.createFile(atPath: finalURL.path, contents: Data())
        try? FileManager.default.removeItem(at: workingURL)
        return finalURL
    }

    func abort() async {
        guard abortCallCount == 0 else { return }
        abortCallCount += 1
        calls.append("writer.abort")
        await appendGate?.open()
    }

    func waitUntilAppendEntered() async {
        var iterator = appendEntered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitUntilAppendCount(_ count: Int) async {
        while appendCallCount < count {
            await Task.yield()
        }
    }
}

private final class SessionSleepSpy: SleepPreventing, @unchecked Sendable {
    private let lock = NSLock()
    private let calls: SessionCallLog
    private var began = false
    private var ended = false
    private var _beginCallCount = 0
    private var _endCallCount = 0

    init(calls: SessionCallLog) { self.calls = calls }

    var beginCallCount: Int { lock.withLock { _beginCallCount } }
    var endCallCount: Int { lock.withLock { _endCallCount } }

    func begin() {
        lock.withLock {
            guard !began else { return }
            began = true
            _beginCallCount += 1
            calls.append("sleep.begin")
        }
    }

    func end() {
        lock.withLock {
            guard began, !ended else { return }
            ended = true
            _endCallCount += 1
            calls.append("sleep.end")
        }
    }
}

private actor SessionNotificationSpy: RecordingNotifying {
    private let calls: SessionCallLog
    private(set) var savedCallCount = 0
    private(set) var failedCallCount = 0

    init(calls: SessionCallLog) { self.calls = calls }

    func saved(_ recording: SavedRecording) async {
        savedCallCount += 1
        calls.append("notification.saved")
    }

    func failed(_ failure: RecordingFailure) async {
        failedCallCount += 1
        calls.append("notification.failed")
    }
}

private final class SessionConverterSpy: AudioSampleConverting, @unchecked Sendable {
    private let lock = NSLock()
    private var systemAmplitude: Float = 0
    private var microphoneAmplitude: Float = 0
    private var frame: Int64 = 0
    private var forcedStartFrames: [Int64] = []

    var nextTimestamp: Int64 { lock.withLock { frame + 1 } }

    func setAmplitude(_ amplitude: Float, for source: CapturedAudioSource) {
        lock.withLock {
            switch source {
            case .system: systemAmplitude = amplitude
            case .microphone: microphoneAmplitude = amplitude
            }
        }
    }

    func forceStartFrames(_ frames: [Int64]) {
        lock.withLock { forcedStartFrames = frames }
    }

    func convert(_ sample: CapturedAudioSample, sessionStartPTS: CMTime) throws -> PCMChunk {
        lock.withLock {
            let start = forcedStartFrames.isEmpty ? frame : forcedStartFrames.removeFirst()
            frame += 4
            let amplitude = switch sample.source {
            case .system: systemAmplitude
            case .microphone: microphoneAmplitude
            }
            return PCMChunk(
                source: sample.source,
                startFrame: start,
                frameCount: 4,
                samples: Array(repeating: amplitude, count: 8)
            )
        }
    }

    func drain(source: CapturedAudioSource) throws -> [PCMChunk] { [] }
}

private struct SessionMixerSpy: AudioMixing {
    private let calls: SessionCallLog
    private(set) var warnings: [RecordingFailure] = []

    init(calls: SessionCallLog) { self.calls = calls }

    mutating func ingest(_ chunk: PCMChunk) -> [MixedAudioChunk] {
        [MixedAudioChunk(startFrame: chunk.startFrame, frameCount: chunk.frameCount, samples: chunk.samples)]
    }

    mutating func flush() -> [MixedAudioChunk] {
        calls.append("mixer.flush")
        return []
    }
}

private final class SessionEventRecorder: @unchecked Sendable {
    private let storage = SessionEventStorage()
    private let task: Task<Void, Never>

    init(events: AsyncStream<RecordingSessionEvent>) {
        let storage = self.storage
        task = Task {
            for await event in events { await storage.record(event) }
        }
    }

    func waitForWarningCount(_ count: Int) async -> [RecordingFailure] {
        await storage.waitForWarningCount(count)
    }

    func waitForLevelCount(_ count: Int) async -> [AudioLevels] {
        await storage.waitForLevelCount(count)
    }

    func waitForFailureCount(_ count: Int) async -> [RecordingFailure] {
        await storage.waitForFailureCount(count)
    }

    func cancel() async { task.cancel() }
}

private actor SessionEventStorage {
    private var warnings: [RecordingFailure] = []
    private var levels: [AudioLevels] = []
    private var failures: [RecordingFailure] = []

    func record(_ event: RecordingSessionEvent) {
        switch event {
        case let .warning(warning): if let warning { warnings.append(warning) }
        case let .levels(value): levels.append(value)
        case let .failed(failure): failures.append(failure)
        }
    }

    func waitForWarningCount(_ count: Int) async -> [RecordingFailure] {
        while warnings.count < count { await Task.yield() }
        return warnings
    }

    func waitForLevelCount(_ count: Int) async -> [AudioLevels] {
        while levels.count < count { await Task.yield() }
        return levels
    }

    func waitForFailureCount(_ count: Int) async -> [RecordingFailure] {
        while failures.count < count { await Task.yield() }
        return failures
    }
}

private actor SessionAsyncGate {
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !openState else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !openState else { return }
        openState = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {}
}
