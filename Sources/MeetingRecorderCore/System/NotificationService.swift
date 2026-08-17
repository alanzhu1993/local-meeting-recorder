import AppKit
import Foundation
import UserNotifications

public protocol RecordingNotifying: Sendable {
    func saved(_ recording: SavedRecording) async
    func failed(_ failure: RecordingFailure) async
}

public struct RecordingNotification: Equatable, Sendable {
    public static let fileURLUserInfoKey = "MeetingRecorder.recordingFileURL"

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

    public var userInfo: [String: String] {
        guard let fileURL else { return [:] }
        return [Self.fileURLUserInfoKey: fileURL.absoluteString]
    }

    public static func fileURL(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let value = userInfo[fileURLUserInfoKey] as? String,
              let fileURL = URL(string: value),
              fileURL.isFileURL else {
            return nil
        }
        return fileURL
    }
}

public protocol RecordingNotificationBacking: Sendable {
    func deliver(_ notification: RecordingNotification) async
}

public final class NotificationService: RecordingNotifying, @unchecked Sendable {
    private let backend: any RecordingNotificationBacking

    public static var foregroundPresentationOptions: UNNotificationPresentationOptions {
        [.banner, .list]
    }

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

    override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func deliver(_ notification: RecordingNotification) async {
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = nil
        content.userInfo = notification.userInfo
        let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
        try? await center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let fileURL = RecordingNotification.fileURL(from: response.notification.request.content.userInfo)
        if let fileURL {
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        NotificationService.foregroundPresentationOptions
    }
}
