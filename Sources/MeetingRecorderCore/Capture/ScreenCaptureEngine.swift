import AVFoundation
import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

protocol ScreenCaptureBackend: Sendable {
    func start() async throws
    func stop() async -> RecordingFailure?
    func updateDefaultMicrophone() async throws
}

typealias ScreenCaptureBackendFactory = @Sendable (
    @escaping @Sendable (AudioCaptureEvent) async -> Void
) -> any ScreenCaptureBackend

public actor ScreenCaptureEngine: AudioCapturing {
    private enum Lifecycle {
        case idle
        case starting(CaptureLifecycleSession)
        case running(CaptureLifecycleSession)
        case stopping(CaptureLifecycleSession)
    }

    private let backendFactory: ScreenCaptureBackendFactory
    private var lifecycle: Lifecycle = .idle

    public init() {
        backendFactory = { eventHandler in
            ScreenCaptureKitBackend(eventHandler: eventHandler)
        }
    }

    init(backendFactory: @escaping ScreenCaptureBackendFactory) {
        self.backendFactory = backendFactory
    }

    public static func makeConfiguration(
        microphoneDeviceID: String?
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = microphoneDeviceID
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        return configuration
    }

    public static func source(
        for outputType: SCStreamOutputType
    ) -> CapturedAudioSource? {
        switch outputType {
        case .audio:
            return .system
        case .microphone:
            return .microphone
        case .screen:
            return nil
        @unknown default:
            return nil
        }
    }

    public func start(
        eventHandler: @escaping @Sendable (AudioCaptureEvent) async -> Void
    ) async throws {
        guard case .idle = lifecycle else {
            throw RecordingFailure(
                code: .capture,
                message: "Audio capture is already starting, running, or stopping."
            )
        }

        let identifier = UUID()
        let delivery = AudioCaptureEventDelivery(eventHandler: eventHandler)
        let backend = backendFactory { [weak self] event in
            await self?.receive(event, from: identifier)
        }
        let session = CaptureLifecycleSession(
            identifier: identifier,
            backend: backend,
            delivery: delivery
        )
        lifecycle = .starting(session)

        do {
            try await session.startTask.value
        } catch {
            let failure = Self.failure(from: error, fallbackCode: .capture)
            if owns(session, in: lifecycle, phase: .starting) {
                lifecycle = .stopping(session)
                let cleanup = beginStopping(session)
                _ = await cleanup.value
                if owns(session, in: lifecycle, phase: .stopping) {
                    lifecycle = .idle
                    session.delivery.finish()
                }
            }
            throw failure
        }

        guard owns(session, in: lifecycle, phase: .starting) else {
            throw RecordingFailure(
                code: .capture,
                message: "Audio capture start was cancelled before it became active."
            )
        }
        lifecycle = .running(session)
    }

    public func stop() async {
        let session: CaptureLifecycleSession
        switch lifecycle {
        case .idle:
            return
        case let .starting(current), let .running(current):
            session = current
            lifecycle = .stopping(current)
        case let .stopping(current):
            session = current
        }

        let stopTask = beginStopping(session)
        let stopFailure = await stopTask.value
        completeStop(of: session, stopFailure: stopFailure)
    }

    public func updateDefaultMicrophone() async throws {
        guard case let .running(session) = lifecycle else {
            throw RecordingFailure(
                code: .microphone,
                message: "Cannot update the microphone while capture is not running."
            )
        }

        try await session.backend.updateDefaultMicrophone()
        guard owns(session, in: lifecycle, phase: .running) else {
            throw RecordingFailure(
                code: .microphone,
                message: "Capture stopped while the microphone was being updated."
            )
        }
    }

    private func receive(_ event: AudioCaptureEvent, from identifier: UUID) async {
        guard let session = currentSession(with: identifier) else { return }

        switch event {
        case let .stopped(failure):
            if session.terminalFailure == nil, let failure {
                session.terminalFailure = failure
            }
            switch lifecycle {
            case .starting, .running:
                lifecycle = .stopping(session)
            case .stopping:
                break
            case .idle:
                return
            }

            let stopTask = beginStopping(session)
            Task { [weak self] in
                let stopFailure = await stopTask.value
                await self?.completeStop(
                    of: session,
                    stopFailure: stopFailure
                )
            }
        default:
            guard
                owns(session, in: lifecycle, phase: .starting)
                    || owns(session, in: lifecycle, phase: .running)
            else {
                return
            }
            session.delivery.emit(event)
        }
    }

    private func beginStopping(
        _ session: CaptureLifecycleSession
    ) -> Task<RecordingFailure?, Never> {
        if let stopTask = session.stopTask {
            return stopTask
        }

        session.startTask.cancel()
        let startTask = session.startTask
        let backend = session.backend
        let stopTask = Task {
            _ = await startTask.result
            return await backend.stop()
        }
        session.stopTask = stopTask
        return stopTask
    }

    private func completeStop(
        of session: CaptureLifecycleSession,
        stopFailure: RecordingFailure?
    ) {
        guard owns(session, in: lifecycle, phase: .stopping) else { return }
        lifecycle = .idle
        guard !session.didSendStoppedEvent else { return }

        session.didSendStoppedEvent = true
        session.delivery.emit(.stopped(session.terminalFailure ?? stopFailure))
        session.delivery.finish()
    }

    private enum LifecyclePhase {
        case starting
        case running
        case stopping
    }

    private func owns(
        _ session: CaptureLifecycleSession,
        in lifecycle: Lifecycle,
        phase: LifecyclePhase
    ) -> Bool {
        switch (lifecycle, phase) {
        case let (.starting(current), .starting),
             let (.running(current), .running),
             let (.stopping(current), .stopping):
            return current.identifier == session.identifier
        default:
            return false
        }
    }

    private func currentSession(with identifier: UUID) -> CaptureLifecycleSession? {
        let session: CaptureLifecycleSession
        switch lifecycle {
        case .idle:
            return nil
        case let .starting(current), let .running(current), let .stopping(current):
            session = current
        }
        return session.identifier == identifier ? session : nil
    }

    fileprivate static func failure(
        from error: Error,
        fallbackCode: RecordingFailure.Code
    ) -> RecordingFailure {
        if let failure = error as? RecordingFailure {
            return failure
        }
        return RecordingFailure(
            code: fallbackCode,
            message: error.localizedDescription
        )
    }
}

private final class CaptureLifecycleSession: @unchecked Sendable {
    let identifier: UUID
    let backend: any ScreenCaptureBackend
    let delivery: AudioCaptureEventDelivery
    let startTask: Task<Void, any Error>
    var stopTask: Task<RecordingFailure?, Never>?
    var terminalFailure: RecordingFailure?
    var didSendStoppedEvent = false

    init(
        identifier: UUID,
        backend: any ScreenCaptureBackend,
        delivery: AudioCaptureEventDelivery
    ) {
        self.identifier = identifier
        self.backend = backend
        self.delivery = delivery
        startTask = Task {
            try await backend.start()
        }
    }
}

private final class AudioCaptureEventDelivery: @unchecked Sendable {
    private let continuation: AsyncStream<AudioCaptureEvent>.Continuation
    private let deliveryTask: Task<Void, Never>

    init(eventHandler: @escaping @Sendable (AudioCaptureEvent) async -> Void) {
        let events = AsyncStream<AudioCaptureEvent>.makeStream()
        continuation = events.continuation
        deliveryTask = Task {
            for await event in events.stream {
                await eventHandler(event)
            }
        }
    }

    func emit(_ event: AudioCaptureEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}

private actor ScreenCaptureKitBackend: ScreenCaptureBackend {
    private let eventRelay: BackendEventRelay
    private var stream: SCStream?
    private var outputBridge: StreamOutputBridge?
    private var defaultInputListener: DefaultInputDeviceListener?

    init(eventHandler: @escaping @Sendable (AudioCaptureEvent) async -> Void) {
        eventRelay = BackendEventRelay(eventHandler: eventHandler)
    }

    func start() async throws {
        let microphoneDeviceID = try Self.defaultMicrophoneDeviceID()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            let code: RecordingFailure.Code = CGPreflightScreenCaptureAccess()
                ? .capture
                : .permission
            throw ScreenCaptureEngine.failure(from: error, fallbackCode: code)
        }
        try Task.checkCancellation()

        guard let display = content.displays.first(where: {
            $0.displayID == CGMainDisplayID()
        }) ?? content.displays.first else {
            throw RecordingFailure(
                code: .capture,
                message: "No display is available for system audio capture."
            )
        }

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let currentApplication = content.applications.filter {
            $0.processID == currentProcessID
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: currentApplication,
            exceptingWindows: []
        )
        let configuration = ScreenCaptureEngine.makeConfiguration(
            microphoneDeviceID: microphoneDeviceID
        )
        let bridge = StreamOutputBridge(eventRelay: eventRelay)
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: bridge
        )

        do {
            try stream.addStreamOutput(
                bridge,
                type: .audio,
                sampleHandlerQueue: bridge.systemAudioQueue
            )
            try stream.addStreamOutput(
                bridge,
                type: .microphone,
                sampleHandlerQueue: bridge.microphoneQueue
            )
            self.outputBridge = bridge
            self.stream = stream
            try Task.checkCancellation()
            try await stream.startCapture()
            try Task.checkCancellation()
        } catch {
            self.outputBridge = bridge
            self.stream = stream
            _ = await stop()
            throw ScreenCaptureEngine.failure(from: error, fallbackCode: .capture)
        }

        do {
            defaultInputListener = try DefaultInputDeviceListener { [weak self] in
                Task {
                    await self?.defaultInputDeviceDidChange()
                }
            }
        } catch {
            eventRelay.emit(.warning(ScreenCaptureEngine.failure(
                from: error,
                fallbackCode: .microphone
            )))
        }
    }

    func stop() async -> RecordingFailure? {
        defaultInputListener?.invalidate()
        defaultInputListener = nil

        let failure: RecordingFailure?
        if let stream {
            do {
                try await stream.stopCapture()
                failure = nil
            } catch {
                failure = ScreenCaptureEngine.failure(
                    from: error,
                    fallbackCode: .capture
                )
            }
        } else {
            failure = nil
        }

        stream = nil
        outputBridge = nil
        await eventRelay.finish()
        return failure
    }

    func updateDefaultMicrophone() async throws {
        guard let stream else {
            throw RecordingFailure(
                code: .microphone,
                message: "Cannot update the microphone while capture is stopped."
            )
        }

        let microphoneDeviceID = try Self.defaultMicrophoneDeviceID()
        let configuration = ScreenCaptureEngine.makeConfiguration(
            microphoneDeviceID: microphoneDeviceID
        )
        do {
            try await stream.updateConfiguration(configuration)
            eventRelay.emit(.microphoneChanged(microphoneDeviceID))
        } catch {
            throw ScreenCaptureEngine.failure(from: error, fallbackCode: .microphone)
        }
    }

    private func defaultInputDeviceDidChange() async {
        do {
            try await updateDefaultMicrophone()
        } catch {
            eventRelay.emit(.warning(ScreenCaptureEngine.failure(
                from: error,
                fallbackCode: .microphone
            )))
        }
    }

    private static func defaultMicrophoneDeviceID() throws -> String {
        guard let identifier = AVCaptureDevice.default(for: .audio)?.uniqueID else {
            throw RecordingFailure(
                code: .microphone,
                message: "No default microphone input device is available."
            )
        }
        return identifier
    }
}

private final class BackendEventRelay: @unchecked Sendable {
    private let continuation: AsyncStream<AudioCaptureEvent>.Continuation
    private let deliveryTask: Task<Void, Never>

    init(eventHandler: @escaping @Sendable (AudioCaptureEvent) async -> Void) {
        let events = AsyncStream<AudioCaptureEvent>.makeStream()
        continuation = events.continuation
        deliveryTask = Task {
            for await event in events.stream {
                await eventHandler(event)
            }
        }
    }

    func emit(_ event: AudioCaptureEvent) {
        continuation.yield(event)
    }

    func finish() async {
        continuation.finish()
        await deliveryTask.value
    }
}

private final class StreamOutputBridge: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    let systemAudioQueue = DispatchQueue(
        label: "com.coohom.meeting-recorder.capture.system-audio"
    )
    let microphoneQueue = DispatchQueue(
        label: "com.coohom.meeting-recorder.capture.microphone"
    )

    private let eventRelay: BackendEventRelay

    init(eventRelay: BackendEventRelay) {
        self.eventRelay = eventRelay
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard
            sampleBuffer.isValid,
            CMSampleBufferDataIsReady(sampleBuffer),
            CMSampleBufferGetNumSamples(sampleBuffer) > 0,
            let source = ScreenCaptureEngine.source(for: outputType)
        else {
            return
        }

        eventRelay.emit(.sample(CapturedAudioSample(
            source: source,
            buffer: sampleBuffer,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        eventRelay.emit(.stopped(RecordingFailure(
            code: .capture,
            message: error.localizedDescription
        )))
    }
}

private final class DefaultInputDeviceListener: @unchecked Sendable {
    private let objectID = AudioObjectID(kAudioObjectSystemObject)
    private let queue = DispatchQueue(
        label: "com.coohom.meeting-recorder.capture.default-input"
    )
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let listener: AudioObjectPropertyListenerBlock
    private var isInstalled = false

    init(onChange: @escaping @Sendable () -> Void) throws {
        listener = { _, _ in
            onChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            objectID,
            &address,
            queue,
            listener
        )
        guard status == noErr else {
            throw RecordingFailure(
                code: .microphone,
                message: "Could not observe default microphone changes (OSStatus \(status))."
            )
        }
        isInstalled = true
    }

    func invalidate() {
        guard isInstalled else { return }
        AudioObjectRemovePropertyListenerBlock(
            objectID,
            &address,
            queue,
            listener
        )
        isInstalled = false
    }

    deinit {
        invalidate()
    }
}
