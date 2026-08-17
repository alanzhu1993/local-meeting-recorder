import XCTest
@testable import MeetingRecorderCore

final class SystemServiceTests: XCTestCase {
    func testSleepPreventionIsIdempotent() {
        let backend = SleepBackendStub()
        let service = SleepPreventionService(backend: backend)

        service.begin()
        service.begin()
        service.end()
        service.end()

        XCTAssertEqual(backend.beginCount, 1)
        XCTAssertEqual(backend.endCount, 1)
    }

    func testSavedNotificationIsSilentAndTargetsSavedFile() async {
        let backend = NotificationBackendStub()
        let service = NotificationService(backend: backend)
        let fileURL = URL(fileURLWithPath: "/tmp/会议录音-2026-08-17-10-00-00.m4a")

        await service.saved(SavedRecording(
            startedAt: .now,
            duration: 30,
            fileURL: fileURL,
            recovered: false
        ))

        XCTAssertEqual(backend.notifications.count, 1)
        XCTAssertEqual(backend.notifications[0].fileURL, fileURL)
        XCTAssertFalse(backend.notifications[0].playsSound)
        XCTAssertEqual(backend.notifications[0].title, "录音已保存")
    }

    func testLoginItemMapsRequiresApprovalToActionableError() {
        let backend = LoginItemBackendStub(status: .requiresApproval)
        let service = LoginItemService(backend: backend)

        XCTAssertFalse(service.isEnabled)
        XCTAssertThrowsError(try service.setEnabled(true)) { error in
            XCTAssertEqual(error as? LoginItemServiceError, .requiresApproval)
        }
        XCTAssertEqual(backend.registerCount, 0)
    }
}

private final class SleepBackendStub: SleepActivityBacking, @unchecked Sendable {
    var beginCount = 0
    var endCount = 0

    func beginActivity() -> SleepActivityToken {
        beginCount += 1
        return SleepActivityToken()
    }

    func endActivity(_ token: SleepActivityToken) {
        endCount += 1
    }
}

private final class NotificationBackendStub: RecordingNotificationBacking, @unchecked Sendable {
    var notifications: [RecordingNotification] = []

    func deliver(_ notification: RecordingNotification) async {
        notifications.append(notification)
    }
}

private final class LoginItemBackendStub: LoginItemBacking, @unchecked Sendable {
    let currentStatus: LoginItemStatus
    var registerCount = 0

    init(status: LoginItemStatus) {
        currentStatus = status
    }

    func status() -> LoginItemStatus { currentStatus }
    func register() throws { registerCount += 1 }
    func unregister() throws {}
}
