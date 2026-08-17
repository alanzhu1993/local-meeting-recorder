import XCTest
@testable import MeetingRecorderCore

final class PermissionServiceTests: XCTestCase {
    func testNamesEveryMissingPermissionInStableOrder() async {
        let service = PermissionService(
            screenAccess: { false },
            requestScreenAccess: {},
            microphoneStatus: { .denied },
            requestMicrophoneAccess: {}
        )

        let status = await service.currentStatus()

        XCTAssertEqual(status.missing, [.systemAudio, .microphone])
        XCTAssertEqual(status.userMessage, "请在系统设置 > 隐私与安全性中开启：屏幕与系统音频录制、麦克风。")
    }

    func testRequestQueriesActualStatusAgainInsteadOfTrustingRequestReturnValue() async {
        let state = PermissionState(screenGranted: false, microphone: .notDetermined)
        let service = PermissionService(
            screenAccess: { state.screenGranted },
            requestScreenAccess: { state.screenRequestCount += 1 },
            microphoneStatus: { state.microphone },
            requestMicrophoneAccess: { state.microphoneRequestCount += 1 }
        )

        let status = await service.requestMissingPermissions()

        XCTAssertEqual(state.screenRequestCount, 1)
        XCTAssertEqual(state.microphoneRequestCount, 1)
        XCTAssertEqual(status.missing, [.systemAudio, .microphone])
    }

    func testRequestSkipsAlreadyGrantedPermissions() async {
        let state = PermissionState(screenGranted: true, microphone: .authorized)
        let service = PermissionService(
            screenAccess: { state.screenGranted },
            requestScreenAccess: { state.screenRequestCount += 1 },
            microphoneStatus: { state.microphone },
            requestMicrophoneAccess: { state.microphoneRequestCount += 1 }
        )

        let status = await service.requestMissingPermissions()
        XCTAssertTrue(status.isGranted)
        XCTAssertEqual(state.screenRequestCount, 0)
        XCTAssertEqual(state.microphoneRequestCount, 0)
    }
}

private final class PermissionState: @unchecked Sendable {
    var screenGranted: Bool
    var microphone: MicrophoneAuthorizationStatus
    var screenRequestCount = 0
    var microphoneRequestCount = 0

    init(screenGranted: Bool, microphone: MicrophoneAuthorizationStatus) {
        self.screenGranted = screenGranted
        self.microphone = microphone
    }
}
