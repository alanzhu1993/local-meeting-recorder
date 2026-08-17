import CoreMedia
import Foundation

protocol RecordingSessionStoring: Sendable {
    func prepare(startedAt: Date) async throws -> RecordingPaths
    func releaseReservation(for outputURL: URL) async
}

extension RecordingStore: RecordingSessionStoring {}

protocol AudioSampleConverting: Sendable {
    func convert(
        _ sample: CapturedAudioSample,
        sessionStartPTS: CMTime
    ) throws -> PCMChunk
    func drain(source: CapturedAudioSource) throws -> [PCMChunk]
}

extension SampleBufferConverter: AudioSampleConverting {}

protocol AudioMixing: Sendable {
    var warnings: [RecordingFailure] { get }
    mutating func ingest(_ chunk: PCMChunk) -> [MixedAudioChunk]
    mutating func flush() -> [MixedAudioChunk]
}

extension AudioTimelineMixer: AudioMixing {}

typealias SessionWriterFactory = @Sendable (URL) throws -> any RecoverableAudioWriting
typealias SessionConverterFactory = @Sendable () -> any AudioSampleConverting
typealias SessionMixerFactory = @Sendable () -> any AudioMixing

public actor RecordingActivityGate {
    enum Kind: Sendable {
        case recording
        case recovering
    }

    struct Lease: Sendable {
        let identifier: UUID
        let kind: Kind
    }

    private enum Activity {
        case idle
        case recording(UUID)
        case recovering(UUID)
    }

    private var activity: Activity = .idle

    public init() {}

    func acquireRecording() throws -> Lease {
        switch activity {
        case .idle:
            let lease = Lease(identifier: UUID(), kind: .recording)
            activity = .recording(lease.identifier)
            return lease
        case .recording:
            throw RecordingFailure(code: .capture, message: "已有录音正在进行，请先停止当前录音。")
        case .recovering:
            throw RecordingFailure(code: .capture, message: "正在恢复上次中断的录音，请恢复完成后再开始。")
        }
    }

    func acquireRecovery() throws -> Lease {
        switch activity {
        case .idle:
            let lease = Lease(identifier: UUID(), kind: .recovering)
            activity = .recovering(lease.identifier)
            return lease
        case .recording:
            throw RecordingFailure(code: .capture, message: "录音正在进行，停止录音后才能恢复中断文件。")
        case .recovering:
            throw RecordingFailure(code: .capture, message: "已有录音恢复任务正在进行。")
        }
    }

    func release(_ lease: Lease) {
        switch (activity, lease.kind) {
        case let (.recording(identifier), .recording) where identifier == lease.identifier:
            activity = .idle
        case let (.recovering(identifier), .recovering) where identifier == lease.identifier:
            activity = .idle
        default:
            return
        }
    }
}

public actor LiveRecordingSessionManager: RecordingSessionManaging {
    private enum State {
        case idle
        case starting(SessionContext)
        case recording(SessionContext)
        case stopping(SessionContext, UUID, Task<Result<SavedRecording, RecordingFailure>, Never>)
    }

    private enum StartStage {
        case checking
        case preparing
        case startingWriter
        case startingCapture

        var fallbackCode: RecordingFailure.Code {
            switch self {
            case .checking: .permission
            case .preparing, .startingWriter: .write
            case .startingCapture: .capture
            }
        }
    }

    private let store: any RecordingSessionStoring
    private let capture: any AudioCapturing
    private let permissions: any PermissionChecking
    private let sleep: any SleepPreventing
    private let notifications: any RecordingNotifying
    private let writerFactory: SessionWriterFactory
    private let converterFactory: SessionConverterFactory
    private let mixerFactory: SessionMixerFactory
    private let now: @Sendable () -> Date
    private let sampleQueueCapacity: Int
    private let activityGate: RecordingActivityGate
    private let eventsBroadcaster = RecordingSessionEventBroadcaster()
    private var state: State = .idle

    public init(
        activityGate: RecordingActivityGate,
        store: RecordingStore = RecordingStore(),
        capture: any AudioCapturing = ScreenCaptureEngine(),
        permissions: any PermissionChecking = PermissionService(),
        sleep: any SleepPreventing = SleepPreventionService(),
        notifications: any RecordingNotifying = NotificationService()
    ) {
        self.store = store
        self.capture = capture
        self.permissions = permissions
        self.sleep = sleep
        self.notifications = notifications
        writerFactory = { RecoverableAudioWriterFactory.make(workingURL: $0) }
        converterFactory = { SampleBufferConverter() }
        mixerFactory = {
            AudioTimelineMixer(sampleRate: 48_000, channels: 2, chunkFrames: 960)
        }
        now = Date.init
        sampleQueueCapacity = 64
        self.activityGate = activityGate
    }

    init(
        activityGate: RecordingActivityGate,
        store: any RecordingSessionStoring,
        capture: any AudioCapturing,
        permissions: any PermissionChecking,
        sleep: any SleepPreventing,
        notifications: any RecordingNotifying,
        writerFactory: @escaping SessionWriterFactory,
        converterFactory: @escaping SessionConverterFactory,
        mixerFactory: @escaping SessionMixerFactory,
        now: @escaping @Sendable () -> Date,
        sampleQueueCapacity: Int
    ) {
        self.store = store
        self.capture = capture
        self.permissions = permissions
        self.sleep = sleep
        self.notifications = notifications
        self.writerFactory = writerFactory
        self.converterFactory = converterFactory
        self.mixerFactory = mixerFactory
        self.now = now
        self.sampleQueueCapacity = max(1, sampleQueueCapacity)
        self.activityGate = activityGate
    }

    public func events() async -> AsyncStream<RecordingSessionEvent> {
        eventsBroadcaster.stream()
    }

    public func start(at date: Date) async throws -> ActiveRecording {
        guard case .idle = state else {
            throw RecordingFailure(code: .capture, message: "已有录音正在启动、录制或停止。")
        }

        let context = SessionContext(
            startedAt: date,
            activityGate: activityGate,
            store: store,
            capture: capture,
            sleep: sleep
        )
        state = .starting(context)
        var stage = StartStage.checking

        do {
            let lease = try await activityGate.acquireRecording()
            context.holdActivityLease(lease)
            try ensureStarting(context)

            let permission = await permissions.currentStatus()
            try ensureStarting(context)
            guard permission.isGranted else {
                throw RecordingFailure(code: .permission, message: permission.userMessage)
            }

            stage = .preparing
            let paths = try await store.prepare(startedAt: date)
            context.paths = paths
            await context.resources.setPaths(paths)
            try ensureStarting(context)

            let writer = try writerFactory(paths.workingURL)
            await context.resources.setWriter(writer)
            try ensureStarting(context)
            await context.resources.beginSleep()
            try ensureStarting(context)

            stage = .startingWriter
            try await context.resources.startWriter()
            try ensureStarting(context)
            guard FileManager.default.fileExists(atPath: paths.workingURL.path) else {
                throw RecordingFailure(
                    code: .write,
                    message: "录音写入器启动后未创建可恢复的工作文件。"
                )
            }
            await context.resources.releaseReservationIfNeeded()
            try ensureStarting(context)

            let pipeline = SessionAudioPipeline(
                converter: converterFactory(),
                mixer: mixerFactory(),
                writer: writer,
                capacity: sampleQueueCapacity,
                emit: { [eventsBroadcaster] event in eventsBroadcaster.emit(event) },
                terminal: { [weak self] failure in
                    Task { await self?.pipelineFailed(contextID: context.identifier, failure: failure) }
                }
            )
            context.pipeline = pipeline

            stage = .startingCapture
            try await context.resources.startCapture { event in
                pipeline.offer(event)
            }
            try ensureStarting(context)

            let active = ActiveRecording(startedAt: date, workingURL: paths.workingURL)
            state = .recording(context)
            await context.startCompletion.finish()
            return active
        } catch {
            let failure = Self.failure(from: error, fallbackCode: stage.fallbackCode)
            context.cancelled = true
            await rollbackStarting(context)
            if owns(context, in: state, allowed: [.starting]) {
                state = .idle
            }
            await context.startCompletion.finish()
            await notifications.failed(failure)
            throw failure
        }
    }

    public func stop() async throws -> SavedRecording {
        switch state {
        case .idle:
            throw RecordingFailure(code: .capture, message: "当前没有正在进行的录音。")
        case let .starting(context):
            context.cancelled = true
            await rollbackStarting(context)
            await context.startCompletion.wait()
            throw RecordingFailure(code: .capture, message: "录音启动已取消。")
        case let .recording(context):
            let (_, task) = beginStopping(context, failure: nil)
            return try await result(of: task, for: context)
        case let .stopping(context, _, task):
            return try await result(of: task, for: context)
        }
    }

    private func ensureStarting(_ context: SessionContext) throws {
        try Task.checkCancellation()
        guard !context.cancelled, owns(context, in: state, allowed: [.starting]) else {
            throw CancellationError()
        }
    }

    private func rollbackStarting(_ context: SessionContext) async {
        context.pipeline?.stopAccepting()
        await context.resources.stopCaptureIfNeeded()
        await context.resources.abortWriterIfNeeded()
        if let pipeline = context.pipeline {
            await pipeline.finishAndWait()
        }
        await context.resources.endSleepIfNeeded()
        await context.resources.releaseReservationIfNeeded()
        await context.releaseActivityLeaseIfNeeded()
    }

    private func pipelineFailed(contextID: UUID, failure: RecordingFailure) {
        let context: SessionContext
        switch state {
        case let .starting(current) where current.identifier == contextID:
            current.cancelled = true
            context = current
            Task { [weak self] in
                guard let self else { return }
                await self.rollbackAfterPipelineStartFailure(context)
            }
        case let .recording(current) where current.identifier == contextID:
            context = current
            _ = beginStopping(context, failure: failure)
        case .idle, .starting, .recording, .stopping:
            return
        }
    }

    private func rollbackAfterPipelineStartFailure(_ context: SessionContext) async {
        await rollbackStarting(context)
    }

    @discardableResult
    private func beginStopping(
        _ context: SessionContext,
        failure: RecordingFailure?
    ) -> (UUID, Task<Result<SavedRecording, RecordingFailure>, Never>) {
        if case let .stopping(current, operation, task) = state,
           current.identifier == context.identifier {
            return (operation, task)
        }

        let operation = UUID()
        let notifications = self.notifications
        let eventsBroadcaster = self.eventsBroadcaster
        let now = self.now
        let task = Task {
            await Self.performStop(
                context,
                initialFailure: failure,
                notifications: notifications,
                eventsBroadcaster: eventsBroadcaster,
                now: now
            )
        }
        state = .stopping(context, operation, task)
        Task { [weak self] in
            let result = await task.value
            await self?.completeAutomaticStop(
                contextID: context.identifier,
                operation: operation,
                result: result
            )
        }
        return (operation, task)
    }

    private static func performStop(
        _ context: SessionContext,
        initialFailure: RecordingFailure?,
        notifications: any RecordingNotifying,
        eventsBroadcaster: RecordingSessionEventBroadcaster,
        now: @Sendable () -> Date
    ) async -> Result<SavedRecording, RecordingFailure> {
        guard let paths = context.paths, let pipeline = context.pipeline else {
            let failure = initialFailure ?? RecordingFailure(
                code: .capture,
                message: "录音会话尚未完成启动。"
            )
            await context.resources.abortWriterIfNeeded()
            await context.resources.endSleepIfNeeded()
            await notifications.failed(failure)
            eventsBroadcaster.emit(.failed(failure))
            await context.releaseActivityLeaseIfNeeded()
            return .failure(failure)
        }

        pipeline.stopAccepting()
        await context.resources.stopCaptureIfNeeded()
        await pipeline.finishAndWait()

        let pipelineFailure = await pipeline.terminalFailure()
        var failure = initialFailure ?? pipelineFailure
        if failure == nil {
            failure = await pipeline.drainAndFlush()
        }

        let result: Result<SavedRecording, RecordingFailure>
        if let failure {
            await context.resources.abortWriterIfNeeded()
            result = .failure(failure)
        } else {
            do {
                let output = try await context.resources.finishWriter(finalURL: paths.finalURL)
                let saved = SavedRecording(
                    startedAt: context.startedAt,
                    duration: max(0, now().timeIntervalSince(context.startedAt)),
                    fileURL: output,
                    recovered: false
                )
                result = .success(saved)
            } catch {
                let writeFailure = Self.failure(from: error, fallbackCode: .finalize)
                await context.resources.abortWriterIfNeeded()
                result = .failure(writeFailure)
            }
        }

        await context.resources.endSleepIfNeeded()
        switch result {
        case let .success(saved):
            await notifications.saved(saved)
        case let .failure(failure):
            await notifications.failed(failure)
            eventsBroadcaster.emit(.failed(failure))
        }
        await context.releaseActivityLeaseIfNeeded()
        return result
    }

    private func result(
        of task: Task<Result<SavedRecording, RecordingFailure>, Never>,
        for context: SessionContext
    ) async throws -> SavedRecording {
        let result = await task.value
        if case let .stopping(current, _, currentTask) = state,
           current.identifier == context.identifier {
            _ = currentTask
            state = .idle
        }
        return try result.get()
    }

    private func completeAutomaticStop(
        contextID: UUID,
        operation: UUID,
        result: Result<SavedRecording, RecordingFailure>
    ) {
        _ = result
        guard case let .stopping(context, currentOperation, _) = state,
              context.identifier == contextID,
              currentOperation == operation else {
            return
        }
        state = .idle
    }

    private enum AllowedState {
        case starting
    }

    private func owns(
        _ context: SessionContext,
        in state: State,
        allowed: Set<AllowedState>
    ) -> Bool {
        switch state {
        case let .starting(current):
            allowed.contains(.starting) && current.identifier == context.identifier
        case .idle, .recording, .stopping:
            false
        }
    }

    private nonisolated static func failure(
        from error: Error,
        fallbackCode: RecordingFailure.Code
    ) -> RecordingFailure {
        if let failure = error as? RecordingFailure { return failure }
        if error is CancellationError {
            return RecordingFailure(code: .capture, message: "录音操作已取消。")
        }
        return RecordingFailure(code: fallbackCode, message: error.localizedDescription)
    }
}

private final class SessionContext: @unchecked Sendable {
    let identifier = UUID()
    let startedAt: Date
    let resources: SessionResources
    let startCompletion = SessionCompletion()
    var cancelled = false
    var paths: RecordingPaths?
    var pipeline: SessionAudioPipeline?
    private let activityLock = NSLock()
    private let activityGate: RecordingActivityGate
    private var activityLease: RecordingActivityGate.Lease?

    init(
        startedAt: Date,
        activityGate: RecordingActivityGate,
        store: any RecordingSessionStoring,
        capture: any AudioCapturing,
        sleep: any SleepPreventing
    ) {
        self.startedAt = startedAt
        self.activityGate = activityGate
        resources = SessionResources(store: store, capture: capture, sleep: sleep)
    }

    func holdActivityLease(_ lease: RecordingActivityGate.Lease) {
        activityLock.withLock { activityLease = lease }
    }

    func releaseActivityLeaseIfNeeded() async {
        let lease = activityLock.withLock {
            let held = activityLease
            activityLease = nil
            return held
        }
        guard let lease else { return }
        await activityGate.release(lease)
    }
}

private actor SessionResources {
    private let store: any RecordingSessionStoring
    private let capture: any AudioCapturing
    private let sleep: any SleepPreventing
    private var paths: RecordingPaths?
    private var writer: (any RecoverableAudioWriting)?
    private var reservationHeld = false
    private var sleepBegan = false
    private var captureStartInvoked = false
    private var captureStopped = false
    private var writerStartInvoked = false
    private var writerAborted = false
    private var writerFinished = false

    init(
        store: any RecordingSessionStoring,
        capture: any AudioCapturing,
        sleep: any SleepPreventing
    ) {
        self.store = store
        self.capture = capture
        self.sleep = sleep
    }

    func setPaths(_ paths: RecordingPaths) {
        self.paths = paths
        reservationHeld = true
    }

    func setWriter(_ writer: any RecoverableAudioWriting) {
        self.writer = writer
    }

    func beginSleep() {
        guard !sleepBegan else { return }
        sleepBegan = true
        sleep.begin()
    }

    func startWriter() async throws {
        guard let writer else {
            throw RecordingFailure(code: .write, message: "录音写入器未创建。")
        }
        writerStartInvoked = true
        try await writer.start()
    }

    func startCapture(
        eventHandler: @escaping @Sendable (AudioCaptureEvent) async -> Void
    ) async throws {
        captureStartInvoked = true
        try await capture.start(eventHandler: eventHandler)
    }

    func stopCaptureIfNeeded() async {
        guard captureStartInvoked, !captureStopped else { return }
        captureStopped = true
        await capture.stop()
    }

    func releaseReservationIfNeeded() async {
        guard reservationHeld, let paths else { return }
        reservationHeld = false
        await store.releaseReservation(for: paths.finalURL)
    }

    func abortWriterIfNeeded() async {
        guard writerStartInvoked, !writerAborted, !writerFinished, let writer else { return }
        writerAborted = true
        await writer.abort()
    }

    func finishWriter(finalURL: URL) async throws -> URL {
        guard !writerAborted, !writerFinished, let writer else {
            throw RecordingFailure(code: .finalize, message: "录音写入器无法完成保存。")
        }
        let output = try await writer.finish(finalURL: finalURL)
        writerFinished = true
        return output
    }

    func endSleepIfNeeded() {
        guard sleepBegan else { return }
        sleepBegan = false
        sleep.end()
    }
}

private final class SessionAudioPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<CapturedAudioSample>.Continuation
    private let processor: SessionAudioProcessor
    private let worker: Task<Void, Never>
    private let emit: @Sendable (RecordingSessionEvent) -> Void
    private let terminalRelay: SessionTerminalRelay
    private var accepting = true

    init(
        converter: any AudioSampleConverting,
        mixer: any AudioMixing,
        writer: any RecoverableAudioWriting,
        capacity: Int,
        emit: @escaping @Sendable (RecordingSessionEvent) -> Void,
        terminal: @escaping @Sendable (RecordingFailure) -> Void
    ) {
        self.emit = emit
        terminalRelay = SessionTerminalRelay(terminal: terminal)
        let samples = AsyncStream<CapturedAudioSample>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, capacity))
        )
        continuation = samples.continuation
        processor = SessionAudioProcessor(
            converter: converter,
            mixer: mixer,
            writer: writer,
            emit: emit,
            terminalRelay: terminalRelay
        )
        let processor = self.processor
        worker = Task {
            for await sample in samples.stream {
                await processor.process(sample)
            }
        }
        terminalRelay.setCloseSamples { [weak self] in
            self?.closeForFatalEvent()
        }
    }

    func offer(_ event: AudioCaptureEvent) {
        switch event {
        case let .sample(sample):
            let result = lock.withLock {
                guard accepting else {
                    return AsyncStream<CapturedAudioSample>.Continuation.YieldResult.terminated
                }
                return continuation.yield(sample)
            }
            if case .dropped = result {
                emit(.warning(RecordingFailure(
                    code: .write,
                    message: "音频处理速度跟不上输入，已丢弃一小段样本。"
                )))
            }
        case let .warning(failure):
            guard isAccepting else { return }
            if failure.code == .microphone {
                emit(.warning(failure))
            } else {
                terminalRelay.report(failure)
            }
        case let .microphoneChanged(identifier):
            guard isAccepting else { return }
            emit(.warning(RecordingFailure(
                code: .microphone,
                message: "麦克风已切换为：\(identifier)。"
            )))
        case let .stopped(failure):
            guard isAccepting else { return }
            terminalRelay.report(failure ?? RecordingFailure(
                code: .capture,
                message: "系统音频捕获意外停止。"
            ))
        }
    }

    private var isAccepting: Bool {
        lock.withLock { accepting }
    }

    private func closeForFatalEvent() {
        lock.withLock {
            accepting = false
            continuation.finish()
        }
    }

    func stopAccepting() {
        lock.withLock { accepting = false }
    }

    func finishAndWait() async {
        lock.withLock {
            accepting = false
            continuation.finish()
        }
        await worker.value
    }

    func drainAndFlush() async -> RecordingFailure? {
        await processor.drainAndFlush()
    }

    func terminalFailure() async -> RecordingFailure? {
        terminalRelay.currentFailure
    }

    deinit {
        continuation.finish()
        worker.cancel()
    }
}

private final class SessionTerminalRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let terminal: @Sendable (RecordingFailure) -> Void
    private var closeSamples: (@Sendable () -> Void)?
    private var failure: RecordingFailure?

    init(terminal: @escaping @Sendable (RecordingFailure) -> Void) {
        self.terminal = terminal
    }

    var currentFailure: RecordingFailure? {
        lock.withLock { failure }
    }

    func setCloseSamples(_ closeSamples: @escaping @Sendable () -> Void) {
        lock.withLock { self.closeSamples = closeSamples }
    }

    func report(_ failure: RecordingFailure) {
        let close = lock.withLock { () -> (@Sendable () -> Void)? in
            guard self.failure == nil else { return nil }
            self.failure = failure
            return closeSamples
        }
        guard let close else { return }
        close()
        terminal(failure)
    }
}

private actor SessionAudioProcessor {
    private let converter: any AudioSampleConverting
    private var mixer: any AudioMixing
    private let writer: any RecoverableAudioWriting
    private let emit: @Sendable (RecordingSessionEvent) -> Void
    private let terminalRelay: SessionTerminalRelay
    private var origin: CMTime?
    private var levels = AudioLevels.silent
    private var emittedMixerWarningCount = 0
    private var drained = false

    init(
        converter: any AudioSampleConverting,
        mixer: any AudioMixing,
        writer: any RecoverableAudioWriting,
        emit: @escaping @Sendable (RecordingSessionEvent) -> Void,
        terminalRelay: SessionTerminalRelay
    ) {
        self.converter = converter
        self.mixer = mixer
        self.writer = writer
        self.emit = emit
        self.terminalRelay = terminalRelay
    }

    func process(_ sample: CapturedAudioSample) async {
        guard terminalRelay.currentFailure == nil else { return }
        do {
            let sessionOrigin = origin ?? sample.presentationTime
            origin = sessionOrigin
            let converted = try converter.convert(sample, sessionStartPTS: sessionOrigin)
            guard let chunk = Self.trimmingFramesBeforeSessionStart(converted) else {
                return
            }
            updateLevel(from: chunk)
            try await append(mixer.ingest(chunk))
            emitNewMixerWarnings()
        } catch {
            fail(Self.failure(from: error, fallbackCode: .write))
        }
    }

    func drainAndFlush() async -> RecordingFailure? {
        guard !drained else { return terminalRelay.currentFailure }
        drained = true
        guard terminalRelay.currentFailure == nil else { return terminalRelay.currentFailure }
        do {
            for source in [CapturedAudioSource.system, .microphone] {
                for converted in try converter.drain(source: source) {
                    guard let chunk = Self.trimmingFramesBeforeSessionStart(converted) else {
                        continue
                    }
                    try await append(mixer.ingest(chunk))
                    emitNewMixerWarnings()
                }
            }
            try await append(mixer.flush())
            emitNewMixerWarnings()
        } catch {
            fail(Self.failure(from: error, fallbackCode: .write))
        }
        return terminalRelay.currentFailure
    }

    private func append(_ chunks: [MixedAudioChunk]) async throws {
        for chunk in chunks {
            try await writer.append(chunk)
        }
    }

    private func updateLevel(from chunk: PCMChunk) {
        let rms: Float
        if chunk.samples.isEmpty {
            rms = 0
        } else {
            let meanSquare = chunk.samples.reduce(Float.zero) { $0 + $1 * $1 }
                / Float(chunk.samples.count)
            rms = min(1, sqrt(meanSquare))
        }
        switch chunk.source {
        case .system:
            levels = AudioLevels(system: rms, microphone: levels.microphone)
        case .microphone:
            levels = AudioLevels(system: levels.system, microphone: rms)
        }
        emit(.levels(levels))
    }

    private func emitNewMixerWarnings() {
        let warnings = mixer.warnings
        guard warnings.count > emittedMixerWarningCount else { return }
        for warning in warnings.dropFirst(emittedMixerWarningCount) {
            emit(.warning(warning))
        }
        emittedMixerWarningCount = warnings.count
    }

    private func fail(_ failure: RecordingFailure) {
        terminalRelay.report(failure)
    }

    private nonisolated static func failure(
        from error: Error,
        fallbackCode: RecordingFailure.Code
    ) -> RecordingFailure {
        if let failure = error as? RecordingFailure { return failure }
        return RecordingFailure(code: fallbackCode, message: error.localizedDescription)
    }

    private nonisolated static func trimmingFramesBeforeSessionStart(
        _ chunk: PCMChunk
    ) -> PCMChunk? {
        guard chunk.startFrame < 0 else { return chunk }
        let framesBeforeStart = chunk.startFrame == .min
            ? Int64.max
            : -chunk.startFrame
        let framesToTrim = min(Int64(chunk.frameCount), framesBeforeStart)
        guard framesToTrim < Int64(chunk.frameCount) else { return nil }
        let remainingFrameCount = chunk.frameCount - Int(framesToTrim)
        let sampleOffset = Int(framesToTrim) * 2
        return PCMChunk(
            source: chunk.source,
            startFrame: 0,
            frameCount: remainingFrameCount,
            samples: Array(chunk.samples.dropFirst(sampleOffset))
        )
    }
}

private actor SessionCompletion {
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !completed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        guard !completed else { return }
        completed = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private final class RecordingSessionEventBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RecordingSessionEvent>.Continuation] = [:]

    func stream() -> AsyncStream<RecordingSessionEvent> {
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            lock.withLock { continuations[identifier] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.remove(identifier)
            }
        }
    }

    func emit(_ event: RecordingSessionEvent) {
        let current = lock.withLock { Array(continuations.values) }
        current.forEach { $0.yield(event) }
    }

    private func remove(_ identifier: UUID) {
        _ = lock.withLock { continuations.removeValue(forKey: identifier) }
    }

    deinit {
        let current = lock.withLock {
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        current.forEach { $0.finish() }
    }
}
