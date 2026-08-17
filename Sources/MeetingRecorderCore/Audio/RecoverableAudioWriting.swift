import Foundation

public protocol RecoverableAudioWriting: Sendable {
    func start() async throws
    func append(_ chunk: MixedAudioChunk) async throws
    func finish(finalURL: URL) async throws -> URL
    func abort() async
}

public enum RecoverableAudioWriterStrategy: Equatable, Sendable {
    case fragmentedMOV
    case segmentedM4A
}

public enum RecoverableAudioWriterFactory {
    public static let strategy: RecoverableAudioWriterStrategy = .fragmentedMOV

    public static func make(workingURL: URL) -> any RecoverableAudioWriting {
        FragmentedMOVWriter(workingURL: workingURL)
    }
}
