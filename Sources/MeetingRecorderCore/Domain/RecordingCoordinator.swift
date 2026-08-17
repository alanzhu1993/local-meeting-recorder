import Combine
import Foundation

@MainActor
public final class RecordingCoordinator: ObservableObject {
    @Published public private(set) var phase: RecordingPhase = .idle
    @Published public private(set) var audioLevels: AudioLevels = .silent

    private let session: any RecordingSessionManaging
    private let now: @Sendable () -> Date
    private var eventTask: Task<Void, Never>?

    public init(
        session: any RecordingSessionManaging,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.now = now
        eventTask = Task { [weak self, session] in
            let events = await session.events()
            for await event in events {
                self?.consume(event)
            }
        }
    }

    public func toggleRecording() async {
        switch phase {
        case .idle, .failed:
            phase = .preparing
            do {
                phase = .recording(try await session.start(at: now()), warning: nil)
            } catch {
                phase = .failed(Self.failure(from: error))
            }
        case let .recording(active, _):
            phase = .stopping(active)
            do {
                _ = try await session.stop()
                phase = .idle
            } catch {
                phase = .failed(Self.failure(from: error))
            }
        case .preparing, .stopping:
            return
        }
    }

    private static func failure(from error: Error) -> RecordingFailure {
        if let failure = error as? RecordingFailure {
            return failure
        }
        return RecordingFailure(code: .capture, message: error.localizedDescription)
    }

    private func consume(_ event: RecordingSessionEvent) {
        switch event {
        case let .levels(levels):
            audioLevels = levels
        case let .warning(warning):
            if case let .recording(active, _) = phase {
                phase = .recording(active, warning: warning)
            }
        case let .failed(failure):
            phase = .failed(failure)
        }
    }
}
