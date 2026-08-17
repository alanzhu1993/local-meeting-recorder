import Foundation

public struct ActiveRecording: Equatable, Sendable {
    public let startedAt: Date
    public let workingURL: URL

    public init(startedAt: Date, workingURL: URL) {
        self.startedAt = startedAt
        self.workingURL = workingURL
    }
}

public struct SavedRecording: Equatable, Sendable {
    public let startedAt: Date
    public let duration: TimeInterval
    public let fileURL: URL
    public let recovered: Bool

    public init(startedAt: Date, duration: TimeInterval, fileURL: URL, recovered: Bool) {
        self.startedAt = startedAt
        self.duration = duration
        self.fileURL = fileURL
        self.recovered = recovered
    }
}

public struct RecordingFailure: Error, Equatable, Sendable {
    public enum Code: String, Sendable {
        case permission
        case storage
        case capture
        case microphone
        case write
        case finalize
        case hotkey
    }

    public let code: Code
    public let message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}

public enum RecordingPhase: Equatable, Sendable {
    case idle
    case preparing
    case recording(ActiveRecording, warning: RecordingFailure?)
    case stopping(ActiveRecording)
    case failed(RecordingFailure)
}

public struct AudioLevels: Equatable, Sendable {
    public let system: Float
    public let microphone: Float

    public init(system: Float, microphone: Float) {
        self.system = system
        self.microphone = microphone
    }

    public static let silent = AudioLevels(system: 0, microphone: 0)
}

public enum RecordingSessionEvent: Equatable, Sendable {
    case levels(AudioLevels)
    case warning(RecordingFailure?)
    case failed(RecordingFailure)
}

public protocol RecordingSessionManaging: Sendable {
    func events() async -> AsyncStream<RecordingSessionEvent>
    func start(at date: Date) async throws -> ActiveRecording
    func stop() async throws -> SavedRecording
}
