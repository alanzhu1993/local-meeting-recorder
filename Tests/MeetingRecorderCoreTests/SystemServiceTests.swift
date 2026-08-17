import XCTest
import UserNotifications
@testable import MeetingRecorderCore

@MainActor
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

    func testConcurrentSameLoginItemRequestIsLinearizedByMainActor() async {
        let backend = ConcurrentLoginItemBackend()
        let service = LoginItemService(backend: backend)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { @MainActor in
                    try? service.setEnabled(true)
                }
            }
            await group.waitForAll()
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

    func testRegistrationErrorWithRequiresApprovalIsActionable() {
        let backend = ConcurrentLoginItemBackend(registerErrorResult: .requiresApproval)
        let service = LoginItemService(backend: backend)

        XCTAssertThrowsError(try service.setEnabled(true)) { error in
            XCTAssertEqual(error as? LoginItemServiceError, .requiresApproval)
        }
    }

    func testReentrantBackendCanReadAndSetLoginItemStateWithoutDeadlock() throws {
        let backend = ReentrantLoginItemBackend()
        let service = LoginItemService(backend: backend)
        backend.service = service

        try service.setEnabled(true)

        XCTAssertTrue(service.isEnabled)
        XCTAssertTrue(backend.didReenter)
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

@MainActor
private final class LoginItemBackendStub: LoginItemBacking {
    let currentStatus: LoginItemStatus
    var registerCount = 0

    init(status: LoginItemStatus) {
        currentStatus = status
    }

    func status() -> LoginItemStatus { currentStatus }
    func register() throws { registerCount += 1 }
    func unregister() throws {}
}

@MainActor
private final class ConcurrentLoginItemBackend: LoginItemBacking {
    private var currentStatus: LoginItemStatus = .disabled
    private let registerErrorResult: LoginItemStatus?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(registerErrorAfterChangingState: Bool = false, registerErrorResult: LoginItemStatus? = nil) {
        self.registerErrorResult = registerErrorAfterChangingState ? .enabled : registerErrorResult
    }

    func status() -> LoginItemStatus {
        currentStatus
    }

    func register() throws {
        registerCount += 1
        if let registerErrorResult {
            currentStatus = registerErrorResult
            throw TestLoginError.changedState
        }
        currentStatus = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        currentStatus = .disabled
    }
}

@MainActor
private final class ReentrantLoginItemBackend: LoginItemBacking {
    weak var service: LoginItemService?
    private var currentStatus: LoginItemStatus = .disabled
    private(set) var didReenter = false

    func status() -> LoginItemStatus { currentStatus }

    func register() throws {
        currentStatus = .enabled
        guard !didReenter else { return }
        didReenter = true
        _ = service?.isEnabled
        try service?.setEnabled(true)
    }

    func unregister() throws {
        currentStatus = .disabled
    }
}

private enum TestLoginError: LocalizedError {
    case changedState

    var errorDescription: String? { "系统已处理请求，但未返回确认。" }
}
