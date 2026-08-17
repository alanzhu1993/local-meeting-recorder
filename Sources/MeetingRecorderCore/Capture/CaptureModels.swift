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

public struct AudioSourceProbeMetrics: Equatable, Sendable {
    public private(set) var sampleCount = 0
    public private(set) var invalidPresentationTimeCount = 0
    public private(set) var presentationTimesAreStrictlyIncreasing = true
    public private(set) var lastPresentationTime: CMTime?

    public init() {}

    public mutating func record(_ presentationTime: CMTime) {
        sampleCount += 1
        guard presentationTime.isValid, presentationTime.isNumeric else {
            invalidPresentationTimeCount += 1
            presentationTimesAreStrictlyIncreasing = false
            return
        }

        if let lastPresentationTime,
           CMTimeCompare(presentationTime, lastPresentationTime) <= 0 {
            presentationTimesAreStrictlyIncreasing = false
        }
        lastPresentationTime = presentationTime
    }
}

public struct AudioCaptureProbeSnapshot: Sendable {
    public let system: AudioSourceProbeMetrics
    public let microphone: AudioSourceProbeMetrics
    public let microphoneChanges: [String]
    public let warnings: [RecordingFailure]
    public let stoppedEventCount: Int
    public let stoppedFailure: RecordingFailure?

    public var passedCaptureChecks: Bool {
        system.sampleCount > 0
            && microphone.sampleCount > 0
            && system.invalidPresentationTimeCount == 0
            && microphone.invalidPresentationTimeCount == 0
            && system.presentationTimesAreStrictlyIncreasing
            && microphone.presentationTimesAreStrictlyIncreasing
            && stoppedEventCount == 1
            && stoppedFailure == nil
    }
}

public struct AudioCaptureProbeMetrics: Sendable {
    private var system = AudioSourceProbeMetrics()
    private var microphone = AudioSourceProbeMetrics()
    private var microphoneChanges: [String] = []
    private var warnings: [RecordingFailure] = []
    private var stoppedEventCount = 0
    private var stoppedFailure: RecordingFailure?

    public init() {}

    public mutating func consume(_ event: AudioCaptureEvent) {
        switch event {
        case let .sample(sample):
            switch sample.source {
            case .system:
                system.record(sample.presentationTime)
            case .microphone:
                microphone.record(sample.presentationTime)
            }
        case let .microphoneChanged(identifier):
            microphoneChanges.append(identifier)
        case let .warning(failure):
            warnings.append(failure)
        case let .stopped(failure):
            stoppedEventCount += 1
            if stoppedFailure == nil, let failure {
                stoppedFailure = failure
            }
        }
    }

    public var snapshot: AudioCaptureProbeSnapshot {
        AudioCaptureProbeSnapshot(
            system: system,
            microphone: microphone,
            microphoneChanges: microphoneChanges,
            warnings: warnings,
            stoppedEventCount: stoppedEventCount,
            stoppedFailure: stoppedFailure
        )
    }
}
