import XCTest
import UserNotifications
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
        XCTAssertEqual(
            RecordingNotification.fileURL(from: backend.notifications[0].userInfo),
            fileURL
        )
    }

    func testSerializedNotificationFileURLCanBeOpenedByANewServiceInstance() async {
        let backend = NotificationBackendStub()
        let firstService = NotificationService(backend: backend)
        let fileURL = URL(fileURLWithPath: "/tmp/会议录音-2026-08-17-11-00-00.m4a")
        await firstService.saved(SavedRecording(startedAt: .now, duration: 30, fileURL: fileURL, recovered: false))

        let secondService = NotificationService(backend: NotificationBackendStub())
        _ = secondService
        XCTAssertEqual(RecordingNotification.fileURL(from: backend.notifications[0].userInfo), fileURL)
    }

    func testForegroundPresentationShowsBannerAndListWithoutSound() {
        let options = NotificationService.foregroundPresentationOptions
        XCTAssertTrue(options.contains(.banner))
        XCTAssertTrue(options.contains(.list))
        XCTAssertFalse(options.contains(.sound))
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

    func testConcurrentSameLoginItemRequestIsLinearized() {
        let backend = ConcurrentLoginItemBackend()
        let service = LoginItemService(backend: backend)

        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            try? service.setEnabled(true)
        }

        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(backend.registerCount, 1)
    }

    func testFailedLoginItemActionSucceedsWhenTheTargetStateWasReached() throws {
        let backend = ConcurrentLoginItemBackend(registerErrorAfterChangingState: true)
        let service = LoginItemService(backend: backend)

        try service.setEnabled(true)

        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(backend.registerCount, 1)
    }

    func testOppositeLoginItemRequestsHaveLastCompletedCallSemantics() throws {
        let backend = ConcurrentLoginItemBackend()
        let service = LoginItemService(backend: backend)

        try service.setEnabled(true)
        try service.setEnabled(false)

        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(backend.registerCount, 1)
        XCTAssertEqual(backend.unregisterCount, 1)
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

private final class ConcurrentLoginItemBackend: LoginItemBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var currentStatus: LoginItemStatus = .disabled
    private let registerErrorAfterChangingState: Bool
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(registerErrorAfterChangingState: Bool = false) {
        self.registerErrorAfterChangingState = registerErrorAfterChangingState
    }

    func status() -> LoginItemStatus {
        lock.withLock { currentStatus }
    }

    func register() throws {
        try lock.withLock {
            registerCount += 1
            currentStatus = .enabled
            if registerErrorAfterChangingState {
                throw TestLoginError.changedState
            }
        }
    }

    func unregister() throws {
        lock.withLock {
            unregisterCount += 1
            currentStatus = .disabled
        }
    }
}

private enum TestLoginError: LocalizedError {
    case changedState

    var errorDescription: String? { "系统已处理请求，但未返回确认。" }
}
