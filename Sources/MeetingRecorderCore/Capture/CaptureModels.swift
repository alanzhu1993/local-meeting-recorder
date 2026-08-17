import CoreMedia
import Foundation

public enum CapturedAudioSource: Equatable, Sendable {
    case system
    case microphone
}

public struct CapturedAudioSample: @unchecked Sendable {
    public let source: CapturedAudioSource
    public let buffer: CMSampleBuffer
    public let presentationTime: CMTime

    public init(
        source: CapturedAudioSource,
        buffer: CMSampleBuffer,
        presentationTime: CMTime
    ) {
        self.source = source
        self.buffer = buffer
        self.presentationTime = presentationTime
    }
}

public enum AudioCaptureEvent: @unchecked Sendable {
    case sample(CapturedAudioSample)
    case microphoneChanged(String)
    case warning(RecordingFailure)
    case stopped(RecordingFailure?)
}

public protocol AudioCapturing: Sendable {
    func start(
        eventHandler: @escaping @Sendable (AudioCaptureEvent) async -> Void
    ) async throws
    func stop() async
    func updateDefaultMicrophone() async throws
}
