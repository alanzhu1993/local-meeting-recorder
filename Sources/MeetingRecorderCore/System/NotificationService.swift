import AppKit
import Foundation
import UserNotifications

public protocol RecordingNotifying: Sendable {
    func saved(_ recording: SavedRecording) async
    func failed(_ failure: RecordingFailure) async
}

public struct RecordingNotification: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String
    public let fileURL: URL?
    public let playsSound: Bool

    public init(identifier: String, title: String, body: String, fileURL: URL?, playsSound: Bool) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.fileURL = fileURL
        self.playsSound = playsSound
    }
}

public protocol RecordingNotificationBacking: Sendable {
    func deliver(_ notification: RecordingNotification) async
}

public final class NotificationService: RecordingNotifying, @unchecked Sendable {
    private let backend: any RecordingNotificationBacking

    public init() {
        backend = UserNotificationBackend()
    }

    public init(backend: any RecordingNotificationBacking) {
        self.backend = backend
    }

    public func saved(_ recording: SavedRecording) async {
        let filename = recording.fileURL.lastPathComponent
        await backend.deliver(RecordingNotification(
            identifier: "saved-\(recording.fileURL.path)-\(recording.startedAt.timeIntervalSince1970)",
            title: "录音已保存",
            body: "已保存到 \(filename)",
            fileURL: recording.fileURL,
            playsSound: false
        ))
    }

    public func failed(_ failure: RecordingFailure) async {
        await backend.deliver(RecordingNotification(
            identifier: "failed-\(UUID().uuidString)",
            title: "录音失败",
            body: failure.message,
            fileURL: nil,
            playsSound: false
        ))
    }
}

private final class UserNotificationBackend: NSObject, RecordingNotificationBacking, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    private let savedFiles = SavedFileStore()

    override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func deliver(_ notification: RecordingNotification) async {
        if let fileURL = notification.fileURL {
            savedFiles.store(fileURL, for: notification.identifier)
        }

        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = nil
        let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
        try? await center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let fileURL = savedFiles.take(for: response.notification.request.identifier)
        if let fileURL {
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
    }
}

private final class SavedFileStore: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: URL] = [:]

    func store(_ fileURL: URL, for identifier: String) {
        lock.withLock {
            files[identifier] = fileURL
        }
    }

    func take(for identifier: String) -> URL? {
        lock.withLock {
            files.removeValue(forKey: identifier)
        }
    }
}
