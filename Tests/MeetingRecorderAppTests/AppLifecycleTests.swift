import AppKit
import MeetingRecorderCore
import XCTest
@testable import MeetingRecorderApp

@MainActor
final class AppLifecycleTests: XCTestCase {
    func testLaunchRecoversBeforeEnablingHotkey() async {
        let harness = AppLifecycleHarness()

        await harness.lifecycle.launch()

        XCTAssertEqual(
            Array(harness.calls.prefix(3)),
            ["menu.show", "recovery.run", "hotkey.register"]
        )
        XCTAssertEqual(harness.recoveryStates, [true, false])
        XCTAssertEqual(harness.calls.last, "login.apply")
    }

    func testLaunchReportsEveryRecoveryResultBeforeRegisteringHotkey() async {
        let recoveredURL = URL(fileURLWithPath: "/tmp/recovered.m4a")
        let failedURL = URL(fileURLWithPath: "/tmp/failed.inprogress.mov")
        let harness = AppLifecycleHarness(recoveryResults: [
            RecoveryResult(outcome: .recovered(recoveredURL)),
            RecoveryResult(outcome: .failed(failedURL, "cannot finalize")),
        ])

        await harness.lifecycle.launch()

        XCTAssertEqual(
            harness.calls,
            [
                "menu.show",
                "recovery.run",
                "notification.saved",
                "notification.failed",
                "hotkey.register",
                "login.apply",
            ]
        )
        XCTAssertTrue(harness.recoveryMessages.contains { $0?.contains("recovered.m4a") == true })
        XCTAssertTrue(harness.recoveryMessages.contains { $0?.contains("failed.inprogress.mov") == true })
    }

    func testStartupServiceErrorsRemainVisibleWithoutStoppingLaterSteps() async {
        let harness = AppLifecycleHarness(
            hotkeyError: HotkeyServiceError.conflict,
            loginError: LoginItemServiceError.requiresApproval
        )

        await harness.lifecycle.launch()

        XCTAssertEqual(
            harness.calls,
            ["menu.show", "recovery.run", "hotkey.register", "login.apply"]
        )
        XCTAssertEqual(harness.startupErrors.count, 2)
        XCTAssertTrue(harness.startupErrors[0].contains("快捷键"))
        XCTAssertTrue(harness.startupErrors[1].contains("系统设置"))
    }

    func testTerminationStopsActiveRecordingAndRepliesExactlyOnce() async {
        let harness = AppLifecycleHarness(phase: .recording(AppLifecycleHarness.active, warning: nil))
        await harness.lifecycle.launch()

        let first = harness.lifecycle.prepareForTermination(reply: harness.terminationReply)
        let repeated = harness.lifecycle.prepareForTermination(reply: harness.terminationReply)
        await harness.lifecycle.waitForTermination()

        XCTAssertEqual(first, .terminateLater)
        XCTAssertEqual(repeated, .terminateLater)
        XCTAssertEqual(
            Array(harness.calls.suffix(2)),
            ["recording.stop", "termination.reply"]
        )
        XCTAssertEqual(harness.calls.filter { $0 == "recording.stop" }.count, 1)
        XCTAssertEqual(harness.calls.filter { $0 == "termination.reply" }.count, 1)
    }

    func testTerminationCancelsPreparingAndAwaitsStoppingSession() async {
        for phase in [
            RecordingPhase.preparing,
            RecordingPhase.stopping(AppLifecycleHarness.active),
        ] {
            let harness = AppLifecycleHarness(phase: phase)
            await harness.lifecycle.launch()

            let disposition = harness.lifecycle.prepareForTermination(reply: harness.terminationReply)
            await harness.lifecycle.waitForTermination()

            XCTAssertEqual(disposition, .terminateLater)
            XCTAssertEqual(
                Array(harness.calls.suffix(2)),
                ["recording.await", "termination.reply"]
            )
        }
    }

    func testTerminationAllowsExitAfterSessionStopFailure() async {
        let harness = AppLifecycleHarness(
            phase: .stopping(AppLifecycleHarness.active),
            sessionStopError: RecordingFailure(code: .finalize, message: "finish failed")
        )
        await harness.lifecycle.launch()

        let disposition = harness.lifecycle.prepareForTermination(reply: harness.terminationReply)
        await harness.lifecycle.waitForTermination()

        XCTAssertEqual(disposition, .terminateLater)
        XCTAssertEqual(harness.calls.filter { $0 == "termination.reply" }.count, 1)
    }

    func testTerminationWaitsForInFlightRecoveryAndStartupRegistration() async {
        let harness = AppLifecycleHarness(suspendRecovery: true)
        harness.lifecycle.start()
        await harness.recovery.waitUntilEntered()

        let disposition = harness.lifecycle.prepareForTermination(reply: harness.terminationReply)
        harness.recovery.finish()
        await harness.lifecycle.waitForTermination()

        XCTAssertEqual(disposition, .terminateLater)
        XCTAssertEqual(
            Array(harness.calls.suffix(3)),
            ["hotkey.register", "login.apply", "termination.reply"]
        )
    }

    func testIdleAndFailedWithoutRecoveryTerminateImmediately() async {
        for phase in [
            RecordingPhase.idle,
            RecordingPhase.failed(.init(code: .capture, message: "failed")),
        ] {
            let harness = AppLifecycleHarness(phase: phase)
            await harness.lifecycle.launch()

            XCTAssertEqual(
                harness.lifecycle.prepareForTermination(reply: harness.terminationReply),
                .terminateNow
            )
        }
    }
}

@MainActor
private final class AppLifecycleHarness {
    static let active = ActiveRecording(
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        workingURL: URL(fileURLWithPath: "/tmp/meeting.inprogress.mov")
    )

    private let callLog: LifecycleCallLog
    let recovery: RecoveryServiceSpy
    private let hotkey: HotkeyServiceSpy
    private let coordinator: RecordingCoordinatorSpy
    private let termination: TerminationReplySpy
    private let startup: StartupErrorSpy
    let lifecycle: AppLifecycle

    var calls: [String] { callLog.calls }
    var recoveryStates: [Bool] { recovery.states }
    var recoveryMessages: [String?] { recovery.messages }
    var startupErrors: [String] { startup.messages }

    init(
        phase: RecordingPhase = .idle,
        recoveryResults: [RecoveryResult] = [],
        hotkeyError: Error? = nil,
        loginError: Error? = nil,
        sessionStopError: Error? = nil,
        suspendRecovery: Bool = false
    ) {
        let callLog = LifecycleCallLog()
        let recovery = RecoveryServiceSpy(
            calls: callLog,
            results: recoveryResults,
            suspend: suspendRecovery
        )
        let hotkey = HotkeyServiceSpy(calls: callLog, error: hotkeyError)
        let coordinator = RecordingCoordinatorSpy(
            calls: callLog,
            phase: phase,
            sessionStopError: sessionStopError
        )
        let termination = TerminationReplySpy(calls: callLog)
        let startup = StartupErrorSpy()
        self.callLog = callLog
        self.recovery = recovery
        self.hotkey = hotkey
        self.coordinator = coordinator
        self.termination = termination
        self.startup = startup

        lifecycle = AppLifecycle(
            showMenu: { callLog.calls.append("menu.show") },
            setRecoveryStatus: recovery.setStatus,
            recover: recovery.run,
            notifyRecoveryResult: { result in
                switch result.outcome {
                case .recovered:
                    callLog.calls.append("notification.saved")
                case .failed:
                    callLog.calls.append("notification.failed")
                }
            },
            registerHotkey: hotkey.register,
            applyLoginItemSetting: {
                callLog.calls.append("login.apply")
                if let loginError { throw loginError }
            },
            startupError: startup.record,
            phase: { coordinator.phase },
            stopRecording: coordinator.stopRecording,
            awaitSessionStop: coordinator.awaitSessionStop
        )
    }

    var terminationReply: @MainActor () -> Void {
        termination.reply
    }
}

@MainActor
private final class LifecycleCallLog {
    var calls: [String] = []
}

@MainActor
private final class RecoveryServiceSpy {
    private let calls: LifecycleCallLog
    private let results: [RecoveryResult]
    private let suspend: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var states: [Bool] = []
    private(set) var messages: [String?] = []

    init(calls: LifecycleCallLog, results: [RecoveryResult], suspend: Bool) {
        self.calls = calls
        self.results = results
        self.suspend = suspend
    }

    func setStatus(_ isRecovering: Bool, _ message: String?) {
        states.append(isRecovering)
        messages.append(message)
    }

    func run() async -> [RecoveryResult] {
        calls.calls.append("recovery.run")
        entered = true
        if suspend {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return results
    }

    func waitUntilEntered() async {
        for _ in 0..<100 where !entered {
            await Task.yield()
        }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class HotkeyServiceSpy {
    private let calls: LifecycleCallLog
    private let error: Error?

    init(calls: LifecycleCallLog, error: Error?) {
        self.calls = calls
        self.error = error
    }

    func register() throws {
        calls.calls.append("hotkey.register")
        if let error { throw error }
    }
}

@MainActor
private final class RecordingCoordinatorSpy {
    private let calls: LifecycleCallLog
    private let sessionStopError: Error?
    var phase: RecordingPhase

    init(calls: LifecycleCallLog, phase: RecordingPhase, sessionStopError: Error?) {
        self.calls = calls
        self.phase = phase
        self.sessionStopError = sessionStopError
    }

    func stopRecording() async {
        calls.calls.append("recording.stop")
        phase = .idle
    }

    func awaitSessionStop() async throws {
        calls.calls.append("recording.await")
        if let sessionStopError { throw sessionStopError }
        phase = .idle
    }
}

@MainActor
private final class TerminationReplySpy {
    private let calls: LifecycleCallLog

    init(calls: LifecycleCallLog) {
        self.calls = calls
    }

    func reply() {
        calls.calls.append("termination.reply")
    }
}

@MainActor
private final class StartupErrorSpy {
    private(set) var messages: [String] = []

    func record(_ message: String) {
        messages.append(message)
    }
}
