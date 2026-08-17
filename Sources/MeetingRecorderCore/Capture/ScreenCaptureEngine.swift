import AVFoundation
import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

public actor ScreenCaptureEngine: AudioCapturing {
    private var stream: SCStream?
    private var outputBridge: StreamOutputBridge?
    private var eventDeliveryTask: Task<Void, Never>?
    private var defaultInputListener: DefaultInputDeviceListener?

    public init() {}

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
        guard stream == nil else {
            throw RecordingFailure(
                code: .capture,
                message: "Audio capture is already running."
            )
        }

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
            throw Self.failure(from: error, fallbackCode: code)
        }

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
        let configuration = Self.makeConfiguration(
            microphoneDeviceID: microphoneDeviceID
        )

        let events = AsyncStream<AudioCaptureEvent>.makeStream()
        let bridge = StreamOutputBridge(continuation: events.continuation)
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
        } catch {
            events.continuation.finish()
            throw Self.failure(from: error, fallbackCode: .capture)
        }

        self.outputBridge = bridge
        self.stream = stream
        eventDeliveryTask = Task {
            for await event in events.stream {
                await eventHandler(event)
            }
        }

        do {
            try await stream.startCapture()
        } catch {
            let failure = Self.failure(from: error, fallbackCode: .capture)
            await discardCurrentStream()
            throw failure
        }

        do {
            defaultInputListener = try DefaultInputDeviceListener { [weak self] in
                Task {
                    await self?.defaultInputDeviceDidChange()
                }
            }
        } catch {
            outputBridge?.emit(.warning(Self.failure(
                from: error,
                fallbackCode: .microphone
            )))
        }
    }

    public func stop() async {
        guard let stream else { return }

        defaultInputListener?.invalidate()
        defaultInputListener = nil

        let failure: RecordingFailure?
        do {
            try await stream.stopCapture()
            failure = nil
        } catch {
            failure = Self.failure(from: error, fallbackCode: .capture)
        }

        outputBridge?.emit(.stopped(failure))
        outputBridge?.finish()
        self.stream = nil
        outputBridge = nil

        if let eventDeliveryTask {
            await eventDeliveryTask.value
        }
        self.eventDeliveryTask = nil
    }

    public func updateDefaultMicrophone() async throws {
        guard let stream else {
            throw RecordingFailure(
                code: .microphone,
                message: "Cannot update the microphone while capture is stopped."
            )
        }

        let microphoneDeviceID = try Self.defaultMicrophoneDeviceID()
        let configuration = Self.makeConfiguration(
            microphoneDeviceID: microphoneDeviceID
        )
        do {
            try await stream.updateConfiguration(configuration)
            outputBridge?.emit(.microphoneChanged(microphoneDeviceID))
        } catch {
            throw Self.failure(from: error, fallbackCode: .microphone)
        }
    }

    private func defaultInputDeviceDidChange() async {
        do {
            try await updateDefaultMicrophone()
        } catch {
            let failure = Self.failure(from: error, fallbackCode: .microphone)
            outputBridge?.emit(.warning(failure))
        }
    }

    private func discardCurrentStream() async {
        defaultInputListener?.invalidate()
        defaultInputListener = nil
        if let stream {
            try? await stream.stopCapture()
        }
        outputBridge?.finish()
        stream = nil
        outputBridge = nil
        if let eventDeliveryTask {
            await eventDeliveryTask.value
        }
        self.eventDeliveryTask = nil
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

    private static func failure(
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

private final class StreamOutputBridge: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    let systemAudioQueue = DispatchQueue(
        label: "com.coohom.meeting-recorder.capture.system-audio"
    )
    let microphoneQueue = DispatchQueue(
        label: "com.coohom.meeting-recorder.capture.microphone"
    )

    private let continuation: AsyncStream<AudioCaptureEvent>.Continuation

    init(continuation: AsyncStream<AudioCaptureEvent>.Continuation) {
        self.continuation = continuation
    }

    func emit(_ event: AudioCaptureEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
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

        emit(.sample(CapturedAudioSample(
            source: source,
            buffer: sampleBuffer,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        emit(.stopped(RecordingFailure(
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
