import AppKit
import XCTest
@testable import MeetingRecorderCore
@testable import MeetingRecorderApp

@MainActor
final class AppLifecycleTests: XCTestCase {
    func testReleaseBuildIncludesReadableDeclaredApplicationIcon() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recorder-build-test.\(UUID().uuidString)", isDirectory: true)
        let buildPath = testRoot.appendingPathComponent("scratch", isDirectory: true)
        let appBundleURL = testRoot.appendingPathComponent("会议录音-test.app", isDirectory: true)
        try FileManager.default.createDirectory(at: buildPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/bash")
        build.arguments = ["scripts/build-app.sh"]
        build.currentDirectoryURL = projectURL
        build.environment = ProcessInfo.processInfo.environment.merging(
            [
                "MEETING_RECORDER_BUILD_TESTING": "1",
                "MEETING_RECORDER_BUILD_TEST_ROOT": testRoot.path,
                "MEETING_RECORDER_BUILD_PATH": buildPath.path,
                "MEETING_RECORDER_APP_BUNDLE_PATH": appBundleURL.path,
                "MEETING_RECORDER_BUILD_TEST_SIGNING_MODE": "adhoc",
            ]
        ) { _, replacement in replacement }
        try build.run()
        build.waitUntilExit()
        XCTAssertEqual(build.terminationStatus, 0, "The release app bundle must build successfully.")

        let infoURL = appBundleURL.appendingPathComponent("Contents/Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        )
        let iconFilename = try XCTUnwrap(info["CFBundleIconFile"] as? String)
        XCTAssertEqual(iconFilename, "AppIcon-2026-08-18.icns")

        let iconURL = appBundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent(iconFilename)
        let iconData = try Data(contentsOf: iconURL)
        XCTAssertFalse(iconData.isEmpty, "The declared icon resource must be readable from the built app bundle.")

        let iconsetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).iconset", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: iconsetURL) }
        let validateIcon = Process()
        validateIcon.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        validateIcon.arguments = ["--convert", "iconset", "--output", iconsetURL.path, iconURL.path]
        try validateIcon.run()
        validateIcon.waitUntilExit()
        XCTAssertEqual(validateIcon.terminationStatus, 0, "The bundle icon must be a readable ICNS file.")

        let expectedIconSlots = [
            "icon_16x16.png": 16,
            "icon_16x16@2x.png": 32,
            "icon_32x32.png": 32,
            "icon_32x32@2x.png": 64,
            "icon_128x128.png": 128,
            "icon_128x128@2x.png": 256,
            "icon_256x256.png": 256,
            "icon_256x256@2x.png": 512,
            "icon_512x512.png": 512,
            "icon_512x512@2x.png": 1024,
        ]
        let actualIconSlots = try FileManager.default.contentsOfDirectory(
            atPath: iconsetURL.path
        ).sorted()
        XCTAssertEqual(actualIconSlots, expectedIconSlots.keys.sorted())
        for (filename, expectedSize) in expectedIconSlots {
            let image = try XCTUnwrap(
                NSBitmapImageRep(data: Data(contentsOf: iconsetURL.appendingPathComponent(filename)))
            )
            XCTAssertEqual(image.pixelsWide, expectedSize, "Unexpected width for \(filename).")
            XCTAssertEqual(image.pixelsHigh, expectedSize, "Unexpected height for \(filename).")
        }
    }

    func testBuildScriptRejectsTestingOverridesOutsideExplicitTestingMode() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recorder-build-test.\(UUID().uuidString)", isDirectory: true)
        let buildPath = testRoot.appendingPathComponent("scratch", isDirectory: true)
        let appBundleURL = testRoot.appendingPathComponent("会议录音-test.app", isDirectory: true)
        try FileManager.default.createDirectory(at: buildPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/bash")
        build.arguments = ["scripts/build-app.sh"]
        build.currentDirectoryURL = projectURL
        build.environment = ProcessInfo.processInfo.environment.merging(
            [
                "MEETING_RECORDER_BUILD_TESTING": "0",
                "MEETING_RECORDER_BUILD_TEST_ROOT": testRoot.path,
                "MEETING_RECORDER_BUILD_PATH": buildPath.path,
                "MEETING_RECORDER_APP_BUNDLE_PATH": appBundleURL.path,
                "MEETING_RECORDER_BUILD_TEST_SIGNING_MODE": "adhoc",
            ]
        ) { _, replacement in replacement }
        try build.run()
        build.waitUntilExit()

        XCTAssertNotEqual(
            build.terminationStatus,
            0,
            "Build-only output overrides must be rejected unless testing mode is explicitly enabled."
        )
    }

    func testProductionCompositionRecordingLeaseBlocksRootRecoveryAndUsesLaunchStore() async throws {
        let environment = try makeCompositionTestEnvironment()
        defer { environment.cleanup() }
        let capture = CompositionBlockingCapture()
        let composition = ProductionCompositionRoot(
            settingsStore: environment.settingsStore,
            permissions: CompositionPermissionSpy(statuses: [.granted]),
            capture: capture,
            sleep: CompositionSleepSpy(),
            notifications: CompositionNotificationSpy(),
            sessionFactory: makeCompositionTestSession,
            recoveryFactory: { activityGate, store in
                RecoveryService(
                    activityGate: activityGate,
                    store: store,
                    finalizer: LifecycleRecoveryFinalizerSpy()
                )
            }
        )

        let start = Task { try await composition.session.start(at: Date(timeIntervalSince1970: 1_700_000_000)) }
        await capture.waitUntilStartEntered()
        let blockedRecovery = await composition.recovery.recoverInterruptedRecordingsBatch()
        let workingFiles = (FileManager.default.enumerator(
            at: environment.rootURL,
            includingPropertiesForKeys: nil
        )?.allObjects as? [URL] ?? []).filter {
            $0.lastPathComponent.contains("inprogress")
        }
        let canonicalRootPath = canonicalCompositionPath(environment.rootURL)

        XCTAssertEqual(blockedRecovery.batchFailure?.code, .capture)
        XCTAssertTrue(blockedRecovery.batchFailure?.message.contains("录音正在进行") == true)
        XCTAssertEqual(workingFiles.count, 1)
        XCTAssertTrue(
            canonicalCompositionPath(workingFiles[0]).hasPrefix(canonicalRootPath + "/")
        )

        _ = try? await composition.session.stop()
        _ = try? await start.value
        let recovery = await composition.recovery.recoverInterruptedRecordingsBatch()

        XCTAssertEqual(recovery.results.count, 1)
        let recoveredPath: String
        switch recovery.results[0].outcome {
        case let .recovered(url): recoveredPath = url.path
        case let .failed(url, _): recoveredPath = url.path
        }
        let canonicalRecoveredPath = canonicalCompositionPath(URL(fileURLWithPath: recoveredPath))
        XCTAssertTrue(
            canonicalRecoveredPath.hasPrefix(canonicalRootPath + "/"),
            "Expected \(canonicalRecoveredPath) inside \(canonicalRootPath)."
        )
    }

    func testProductionCompositionRecoveryLeaseBlocksRootSession() async throws {
        let environment = try makeCompositionTestEnvironment()
        defer { environment.cleanup() }
        let recoveryEntered = CompositionSignal()
        let releaseRecovery = LifecycleAsyncGate()
        let composition = ProductionCompositionRoot(
            settingsStore: environment.settingsStore,
            permissions: CompositionPermissionSpy(statuses: [.granted]),
            capture: CompositionBlockingCapture(),
            sleep: CompositionSleepSpy(),
            notifications: CompositionNotificationSpy(),
            sessionFactory: makeCompositionTestSession,
            recoveryFactory: { activityGate, store in
                RecoveryService(
                    activityGate: activityGate,
                    store: store,
                    finalizer: LifecycleRecoveryFinalizerSpy(),
                    afterLeaseAcquired: {
                        recoveryEntered.signal()
                        await releaseRecovery.wait()
                    }
                )
            }
        )

        let recovery = Task { await composition.recovery.recoverInterruptedRecordingsBatch() }
        await recoveryEntered.wait()
        do {
            _ = try await composition.session.start(at: Date())
            XCTFail("Expected the root session to be rejected while root recovery owns the gate.")
        } catch let failure as RecordingFailure {
            XCTAssertEqual(failure.code, .capture)
            XCTAssertTrue(failure.message.contains("正在恢复"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await releaseRecovery.open()
        _ = await recovery.value
    }

    func testProductionMenuAndHotkeyShareOneInFlightPermissionRequestAndSafelyStopSession() async throws {
        let environment = try makeCompositionTestEnvironment()
        defer { environment.cleanup() }
        let permissions = CompositionPermissionSpy(
            statuses: [.denied, .granted, .granted],
            suspendRequest: true
        )
        let capture = CompositionBlockingCapture(suspendStart: false)
        let composition = ProductionCompositionRoot(
            settingsStore: environment.settingsStore,
            permissions: permissions,
            capture: capture,
            sleep: CompositionSleepSpy(),
            notifications: CompositionNotificationSpy(),
            sessionFactory: makeCompositionTestSession,
            recoveryFactory: makeCompositionTestRecovery
        )

        composition.menuRecordingHandler()
        let menuRequestStarted = await permissions.waitForRequestCount(1)
        XCTAssertTrue(menuRequestStarted)
        composition.hotkeyRecordingHandler()
        for _ in 0..<100 { await Task.yield() }

        var snapshot = await permissions.snapshot
        XCTAssertEqual(snapshot.currentCount, 1)
        XCTAssertEqual(snapshot.requestCount, 1)

        await permissions.releaseRequest()
        let menuRequestFinished = await permissions.waitForCurrentCount(3)
        XCTAssertTrue(menuRequestFinished)
        await capture.waitUntilStartEntered()
        let recordingStarted = await waitForCompositionPhase(composition.coordinator) {
            if case .recording = $0 { return true }
            return false
        }
        XCTAssertTrue(recordingStarted)

        snapshot = await permissions.snapshot
        XCTAssertEqual(snapshot.currentCount, 3)
        XCTAssertEqual(snapshot.requestCount, 1)
        await composition.recordingEntrypoint.perform()
        guard case .idle = composition.coordinator.phase else {
            return XCTFail("The shared session must stop cleanly after the suspended request is released.")
        }
        let remainingFiles = try FileManager.default.contentsOfDirectory(
            at: environment.rootURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(remainingFiles.contains { $0.lastPathComponent.contains("inprogress") })
    }

    func testProductionSessionRechecksTheSameInjectedPermissionBeforePreparingCapture() async throws {
        let environment = try makeCompositionTestEnvironment()
        defer { environment.cleanup() }
        let permissions = CompositionPermissionSpy(
            statuses: [.denied, .granted, .denied]
        )
        let capture = CompositionBlockingCapture()
        let composition = ProductionCompositionRoot(
            settingsStore: environment.settingsStore,
            permissions: permissions,
            capture: capture,
            sleep: CompositionSleepSpy(),
            notifications: CompositionNotificationSpy(),
            sessionFactory: makeCompositionTestSession,
            recoveryFactory: makeCompositionTestRecovery
        )

        composition.menuRecordingHandler()
        let sessionCheckObserved = await permissions.waitForCurrentCount(3)
        XCTAssertTrue(sessionCheckObserved)
        for _ in 0..<10 { await Task.yield() }

        let snapshot = await permissions.snapshot
        XCTAssertEqual(snapshot.requestCount, 1)
        XCTAssertEqual(
            snapshot.events,
            [
                "current.1.denied",
                "request.1.started",
                "request.1.finished",
                "current.2.granted",
                "current.3.denied",
            ]
        )
        let captureStartCallCount = await capture.startCallCount
        XCTAssertEqual(captureStartCallCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: environment.rootURL,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

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
        XCTAssertEqual(harness.feedbacks.count, 2)
        XCTAssertTrue(harness.feedbacks.contains { $0.message.contains(failedURL.path) })
    }

    func testBatchScanFailureStaysVisibleWithRootAndErrorAfterLaunch() async {
        let root = URL(fileURLWithPath: "/tmp/recording-root", isDirectory: true)
        let harness = AppLifecycleHarness(
            recoveryRoot: root,
            recoveryError: RecordingFailure(code: .write, message: "scan denied")
        )

        await harness.lifecycle.launch()

        XCTAssertFalse(harness.recoveryStates.last ?? true)
        XCTAssertEqual(harness.feedbacks.count, 1)
        XCTAssertTrue(harness.feedbacks[0].message.contains(root.path))
        XCTAssertTrue(harness.feedbacks[0].message.contains("scan denied"))
        XCTAssertEqual(harness.feedbacks[0].revealURL, root)
        XCTAssertTrue(harness.feedbacks[0].isFailure)
    }

    func testFirstBatchFailureRemainsVisibleWhenSecondBatchSucceedsBeforeLifecycleConsumesIt() async {
        let root = URL(fileURLWithPath: "/tmp/atomic-recovery-root", isDirectory: true)
        let store = LifecycleSequencedRecoveryStore(outcomes: [
            .failure(RecordingFailure(code: .write, message: "first batch scan failed")),
            .success([]),
        ])
        let service = RecoveryService(
            activityGate: RecordingActivityGate(),
            store: store,
            finalizer: LifecycleRecoveryFinalizerSpy()
        )
        let allowFirstConsumer = LifecycleAsyncGate()
        var firstBatchReturned = false
        var feedbacks: [RecoveryFeedback] = []
        let lifecycle = AppLifecycle(
            showMenu: {},
            setRecoveryStatus: { _, _ in },
            recoveryRoot: root,
            recover: {
                let batch = await service.recoverInterruptedRecordingsBatch()
                firstBatchReturned = true
                await allowFirstConsumer.wait()
                return batch
            },
            notifyRecoveryResult: { _ in },
            publishRecoveryFeedback: { feedbacks.append($0) },
            registerHotkey: {},
            applyLoginItemSetting: {},
            startupError: { _ in },
            phase: { .idle },
            stopRecording: {},
            awaitSessionStop: {}
        )

        lifecycle.start()
        while !firstBatchReturned { await Task.yield() }
        let secondBatch = await service.recoverInterruptedRecordingsBatch()
        await allowFirstConsumer.open()
        await lifecycle.waitForLaunch()

        XCTAssertNil(secondBatch.batchFailure)
        XCTAssertEqual(feedbacks.count, 1)
        XCTAssertTrue(feedbacks[0].message.contains(root.path))
        XCTAssertTrue(feedbacks[0].message.contains("first batch scan failed"))
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

    func testTerminationCancelsRealLiveSessionPreparingAndKeepsWorkingFile() async throws {
        let harness = try LiveLifecycleHarness(suspendCaptureStart: true)
        await harness.lifecycle.launch()
        let start = Task { await harness.coordinator.toggleRecording() }
        await harness.capture.waitUntilStartEntered()
        XCTAssertEqual(harness.coordinator.phase, .preparing)

        let disposition = harness.lifecycle.prepareForTermination(reply: harness.reply)
        await harness.lifecycle.waitForTermination()
        await start.value
        let abortCallCount = await harness.writer.abortCallCount
        let stopCallCount = await harness.capture.stopCallCount

        XCTAssertEqual(disposition, .terminateLater)
        XCTAssertEqual(abortCallCount, 1)
        XCTAssertEqual(stopCallCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.workingURL.path))
        XCTAssertEqual(harness.replyCount, 1)
    }

    func testTerminationJoinsRealLiveSessionStoppingOperation() async throws {
        let finishGate = LifecycleAsyncGate()
        let harness = try LiveLifecycleHarness(finishGate: finishGate)
        await harness.lifecycle.launch()
        await harness.coordinator.toggleRecording()
        let stop = Task { await harness.coordinator.toggleRecording() }
        await harness.writer.waitUntilFinishEntered()
        guard case .stopping = harness.coordinator.phase else {
            return XCTFail("expected real coordinator to be stopping")
        }

        let disposition = harness.lifecycle.prepareForTermination(reply: harness.reply)
        await finishGate.open()
        await harness.lifecycle.waitForTermination()
        await stop.value
        let finishCallCount = await harness.writer.finishCallCount

        XCTAssertEqual(disposition, .terminateLater)
        XCTAssertEqual(finishCallCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.finalURL.path))
        XCTAssertEqual(harness.replyCount, 1)
    }

    func testTerminationAllowsExitAfterRealLiveSessionFinishFailureKeepsWorkingFile() async throws {
        let failure = RecordingFailure(code: .finalize, message: "finish failed")
        let harness = try LiveLifecycleHarness(finishError: failure)
        await harness.lifecycle.launch()
        await harness.coordinator.toggleRecording()

        let disposition = harness.lifecycle.prepareForTermination(reply: harness.reply)
        await harness.lifecycle.waitForTermination()
        let finishCallCount = await harness.writer.finishCallCount
        let abortCallCount = await harness.writer.abortCallCount

        XCTAssertEqual(disposition, .terminateLater)
        XCTAssertEqual(finishCallCount, 1)
        XCTAssertEqual(abortCallCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.workingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.finalURL.path))
        XCTAssertEqual(harness.replyCount, 1)
    }
}

private struct CompositionTestEnvironment {
    let rootURL: URL
    let suiteName: String
    let defaults: UserDefaults
    let settingsStore: AppSettingsStore

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private func makeCompositionTestEnvironment() throws -> CompositionTestEnvironment {
    let temporaryDirectory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    let rootURL = temporaryDirectory
        .appendingPathComponent("MeetingRecorderCompositionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let suiteName = "MeetingRecorderCompositionTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw CompositionTestEnvironmentError.cannotCreateDefaults
    }
    let settingsStore = AppSettingsStore(defaults: defaults)
    settingsStore.save(AppSettings(
        recordingRoot: rootURL,
        hotkey: .init(keyCode: 15, modifiers: 0x1800, displayText: "⌘R"),
        launchAtLogin: false
    ))

    let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
    let canonicalTemporaryDirectory = temporaryDirectory.standardizedFileURL
    let canonicalDefaultRoot = AppMetadata.defaultRecordingRoot
        .resolvingSymlinksInPath()
        .standardizedFileURL
    XCTAssertTrue(canonicalRoot.path.hasPrefix(canonicalTemporaryDirectory.path + "/"))
    XCTAssertNotEqual(canonicalRoot.path, canonicalDefaultRoot.path)
    XCTAssertEqual(
        settingsStore.load().recordingRoot.resolvingSymlinksInPath().standardizedFileURL.path,
        canonicalRoot.path
    )

    return CompositionTestEnvironment(
        rootURL: rootURL,
        suiteName: suiteName,
        defaults: defaults,
        settingsStore: settingsStore
    )
}

private enum CompositionTestEnvironmentError: Error {
    case cannotCreateDefaults
}

private func canonicalCompositionPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.path
    return path.hasPrefix("/var/") ? "/private\(path)" : path
}

@MainActor
private func waitForCompositionPhase(
    _ coordinator: RecordingCoordinator,
    matches: (RecordingPhase) -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while !matches(coordinator.phase) {
        guard clock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}

private func makeCompositionTestSession(
    activityGate: RecordingActivityGate,
    store: RecordingStore,
    capture: any AudioCapturing,
    permissions: any PermissionChecking,
    sleep: any SleepPreventing,
    notifications: any RecordingNotifying
) -> LiveRecordingSessionManager {
    LiveRecordingSessionManager(
        activityGate: activityGate,
        store: store,
        capture: capture,
        permissions: permissions,
        sleep: sleep,
        notifications: notifications,
        writerFactory: {
            LifecycleWriterSpy(workingURL: $0, finishGate: nil, finishError: nil)
        },
        converterFactory: { SampleBufferConverter() },
        mixerFactory: {
            AudioTimelineMixer(sampleRate: 48_000, channels: 2, chunkFrames: 960)
        },
        now: Date.init,
        sampleQueueCapacity: 8
    )
}

private func makeCompositionTestRecovery(
    activityGate: RecordingActivityGate,
    store: RecordingStore
) -> RecoveryService {
    RecoveryService(
        activityGate: activityGate,
        store: store,
        finalizer: LifecycleRecoveryFinalizerSpy()
    )
}

private extension CapturePermissionStatus {
    static let granted = CapturePermissionStatus(missing: [])
    static let denied = CapturePermissionStatus(missing: [.systemAudio])
}

final class InstallScriptIntegrationTests: XCTestCase {
    func testSignalsAfterBackupMoveExitOnceRestoreOldAppAndSkipCopyAndOpen() throws {
        let expectedStatuses: [(signal: String, status: Int32)] = [
            ("HUP", 129),
            ("INT", 130),
            ("QUIT", 131),
            ("TERM", 143),
        ]

        for expected in expectedStatuses {
            let harness = try InstallScriptHarness()
            defer { harness.cleanup() }
            try harness.installOldApp(marker: "old-\(expected.signal)")
            let outsideMarkers = try InstallScriptHarness.makeTemporaryDirectory(
                named: "meeting-recorder-install-signal-marker"
            )
            defer { try? FileManager.default.removeItem(at: outsideMarkers) }
            let tools = try harness.makeSignalStageTools(
                signal: expected.signal,
                outsideMarkers: outsideMarkers
            )
            harness.environment["MEETING_RECORDER_MV_TOOL"] = tools.move.path
            harness.environment["MEETING_RECORDER_DITTO_TOOL"] = tools.ditto.path
            harness.environment["MEETING_RECORDER_OPEN_TOOL"] = tools.open.path

            let result = try harness.runSendingSignalAfterBackupMove(
                expected.signal,
                outsideMarkers: outsideMarkers
            )

            XCTAssertEqual(result.status, expected.status, result.output)
            XCTAssertEqual(try harness.targetMarker(), "old-\(expected.signal)")
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: outsideMarkers.appendingPathComponent("ditto-called").path
                ),
                "\(expected.signal) must stop before the copy stage."
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: outsideMarkers.appendingPathComponent("open-called").path
                ),
                "\(expected.signal) must stop before the launch stage."
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: harness.backupApp.path))
        }
    }

    func testDittoPartialFailureRestoresPreviousAppAndPreservesFailedArtifact() throws {
        let harness = try InstallScriptHarness()
        defer { harness.cleanup() }
        try harness.installOldApp(marker: "old")
        harness.environment["MEETING_RECORDER_DITTO_TOOL"] = harness.dittoPartialFailure.path

        let result = try harness.run()

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try harness.targetMarker(), "old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.failedApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.failedApp.appendingPathComponent("partial").path))
    }

    func testFirstInstallVerificationFailureMovesPartialTargetToFailedArtifact() throws {
        let harness = try InstallScriptHarness()
        defer { harness.cleanup() }
        try Data().write(to: harness.failTargetVerificationFlag)

        let result = try harness.run()

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.targetApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.failedApp.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: harness.failedApp.appendingPathComponent("Contents/MacOS/MeetingRecorderApp").path
        ))
    }

    func testFirstInstallDittoPartialFailurePreservesFailedArtifactWithoutFormalTarget() throws {
        let harness = try InstallScriptHarness()
        defer { harness.cleanup() }
        harness.environment["MEETING_RECORDER_DITTO_TOOL"] = harness.dittoPartialFailure.path

        let result = try harness.run()

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.targetApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.failedApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.failedApp.appendingPathComponent("partial").path))
    }

    func testBackupNameCollisionUsesIncrementedUniqueName() throws {
        let harness = try InstallScriptHarness()
        defer { harness.cleanup() }
        try harness.installOldApp(marker: "old")
        try FileManager.default.createDirectory(at: harness.backupApp, withIntermediateDirectories: true)
        try Data("collision".utf8).write(to: harness.backupApp.appendingPathComponent("marker"))

        let result = try harness.run()

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            try String(contentsOf: harness.backupApp.appendingPathComponent("marker"), encoding: .utf8),
            "collision"
        )
        XCTAssertEqual(
            try String(contentsOf: harness.backupAppV2.appendingPathComponent("marker"), encoding: .utf8),
            "old"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.targetExecutable.path))
        XCTAssertTrue(harness.backupApp.path.hasSuffix(".app.backup"))
        XCTAssertEqual(harness.backupApp.deletingLastPathComponent(), harness.backupRoot)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: harness.installRoot.path)
                .contains { $0.hasSuffix(".app.backup") }
        )
    }

    func testWrongProcessPathIsNeverAskedToQuit() throws {
        let harness = try InstallScriptHarness()
        defer { harness.cleanup() }
        try harness.installOldApp(marker: "old")
        try harness.setProcesses(["111": "/tmp/Other.app/Contents/MacOS/MeetingRecorderApp"])

        let result = try harness.run()

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.quitCalledFlag.path))
        XCTAssertEqual(
            try String(contentsOf: harness.backupApp.appendingPathComponent("marker"), encoding: .utf8),
            "old"
        )
    }

    func testRestoreMoveFailureLeavesPartialTargetAndCompleteBackup() throws {
        let harness = try InstallScriptHarness()
        defer { harness.cleanup() }
        try harness.installOldApp(marker: "old")
        harness.environment["MEETING_RECORDER_DITTO_TOOL"] = harness.dittoPartialFailure.path
        harness.environment["MEETING_RECORDER_MV_TOOL"] = harness.mvRestoreFailure.path

        let result = try harness.run()

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.targetApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.failedApp.appendingPathComponent("partial").path))
        XCTAssertEqual(
            try String(contentsOf: harness.backupApp.appendingPathComponent("marker"), encoding: .utf8),
            "old"
        )
    }

    func testNormalQuitTimeoutAbortsBeforeMovingExistingApp() throws {
        let harness = try InstallScriptHarness()
        defer { harness.cleanup() }
        try harness.installOldApp(marker: "old")
        try harness.setProcesses(["222": harness.targetExecutable.path])

        let result = try harness.run()

        XCTAssertEqual(result.status, 68, result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.quitCalledFlag.path))
        XCTAssertEqual(try harness.targetMarker(), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.backupApp.path))
    }

    func testBackupRootOutsideInstallTestRootIsRejectedBeforeMutation() throws {
        let harness = try InstallScriptHarness()
        defer { harness.cleanup() }
        try harness.installOldApp(marker: "old")
        let outsideRoot = try InstallScriptHarness.makeTemporaryDirectory(
            named: "meeting-recorder-install-backup-escape"
        )
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        harness.environment["MEETING_RECORDER_BACKUP_ROOT"] = outsideRoot.path

        let result = try harness.run()

        XCTAssertEqual(result.status, 70, result.output)
        XCTAssertEqual(try harness.targetMarker(), "old")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outsideRoot.path).isEmpty)
    }

    func testInstallOverridesRequireExplicitTestingMode() throws {
        let harness = try InstallScriptHarness()
        defer { harness.cleanup() }
        harness.environment["MEETING_RECORDER_INSTALL_TESTING"] = "0"

        let result = try harness.run()

        XCTAssertEqual(result.status, 70, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.targetApp.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: harness.backupRoot.path).isEmpty)
    }

    func testSymlinkBackupRootIsRejectedBeforeMutation() throws {
        let harness = try InstallScriptHarness()
        defer { harness.cleanup() }
        try harness.installOldApp(marker: "old")
        let realBackupRoot = harness.root.appendingPathComponent("real-backups", isDirectory: true)
        let linkedBackupRoot = harness.root.appendingPathComponent("linked-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: realBackupRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: linkedBackupRoot.path,
            withDestinationPath: realBackupRoot.path
        )
        harness.environment["MEETING_RECORDER_BACKUP_ROOT"] = linkedBackupRoot.path

        let result = try harness.run()

        XCTAssertEqual(result.status, 70, result.output)
        XCTAssertEqual(try harness.targetMarker(), "old")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: realBackupRoot.path).isEmpty)
    }

    func testFinalTargetSymlinkOutsideInstallRootIsRejectedBeforeMutation() throws {
        let harness = try InstallScriptHarness()
        defer { harness.cleanup() }
        try harness.installOldApp(marker: "outside-old")
        let outsideRoot = try InstallScriptHarness.makeTemporaryDirectory(
            named: "meeting-recorder-install-target-symlink"
        )
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        let outsideApp = outsideRoot.appendingPathComponent("outside.app", isDirectory: true)
        try FileManager.default.moveItem(at: harness.targetApp, to: outsideApp)
        try FileManager.default.createSymbolicLink(
            atPath: harness.targetApp.path,
            withDestinationPath: outsideApp.path
        )

        let result = try harness.run()

        XCTAssertEqual(result.status, 70, result.output)
        XCTAssertEqual(
            try String(contentsOf: outsideApp.appendingPathComponent("marker"), encoding: .utf8),
            "outside-old"
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: harness.backupRoot.path).isEmpty
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.openCalledFlag.path))
    }

    func testFinalSourceSymlinkOutsideSourceRootIsRejectedBeforeMutation() throws {
        let harness = try InstallScriptHarness()
        defer { harness.cleanup() }
        try harness.installOldApp(marker: "old")
        let outsideRoot = try InstallScriptHarness.makeTemporaryDirectory(
            named: "meeting-recorder-install-source-symlink"
        )
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        let outsideApp = outsideRoot.appendingPathComponent("source.app", isDirectory: true)
        try FileManager.default.moveItem(at: harness.sourceApp, to: outsideApp)
        try FileManager.default.createSymbolicLink(
            atPath: harness.sourceApp.path,
            withDestinationPath: outsideApp.path
        )

        let result = try harness.run()

        XCTAssertEqual(result.status, 70, result.output)
        XCTAssertEqual(
            try String(contentsOf: outsideApp.appendingPathComponent("marker"), encoding: .utf8),
            "new"
        )
        XCTAssertEqual(try harness.targetMarker(), "old")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: harness.backupRoot.path).isEmpty
        )
    }
}

private final class InstallScriptHarness {
    static let stamp = "2026-08-18-010101"
    let root: URL
    let sourceRoot: URL
    let installRoot: URL
    let backupRoot: URL
    let toolsRoot: URL
    let stateRoot: URL
    let sourceApp: URL
    let targetApp: URL
    let targetExecutable: URL
    let backupApp: URL
    let backupAppV2: URL
    let failedApp: URL
    let failTargetVerificationFlag: URL
    let quitCalledFlag: URL
    let openCalledFlag: URL
    let dittoPartialFailure: URL
    let mvRestoreFailure: URL
    let installScript: URL
    var environment: [String: String]

    init() throws {
        let makeTemp = Process()
        let output = Pipe()
        makeTemp.executableURL = URL(fileURLWithPath: "/usr/bin/mktemp")
        let template = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recorder-install-test.XXXXXX").path
        makeTemp.arguments = ["-d", template]
        makeTemp.standardOutput = output
        try makeTemp.run()
        makeTemp.waitUntilExit()
        guard makeTemp.terminationStatus == 0,
              let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            throw InstallHarnessError.setup
        }

        let canonicalPath = path.hasPrefix("/var/") ? "/private\(path)" : path
        root = URL(fileURLWithPath: canonicalPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        installRoot = root.appendingPathComponent("install", isDirectory: true)
        backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        toolsRoot = root.appendingPathComponent("tools", isDirectory: true)
        stateRoot = root.appendingPathComponent("state", isDirectory: true)
        sourceApp = sourceRoot.appendingPathComponent("会议录音-2026-08-18.app", isDirectory: true)
        targetApp = installRoot.appendingPathComponent("会议录音.app", isDirectory: true)
        targetExecutable = targetApp.appendingPathComponent("Contents/MacOS/MeetingRecorderApp")
        backupApp = backupRoot.appendingPathComponent("会议录音-backup-\(Self.stamp).app.backup")
        backupAppV2 = backupRoot.appendingPathComponent("会议录音-backup-\(Self.stamp)-v2.app.backup")
        failedApp = backupRoot.appendingPathComponent("会议录音-failed-\(Self.stamp).app.backup")
        failTargetVerificationFlag = stateRoot.appendingPathComponent("fail-target-verification")
        quitCalledFlag = stateRoot.appendingPathComponent("quit-called")
        openCalledFlag = stateRoot.appendingPathComponent("open-called")
        let testFile = URL(fileURLWithPath: #filePath)
        installScript = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/install-local.sh")

        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: toolsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        try Self.makeApp(at: sourceApp, marker: "new")

        let codesign = toolsRoot.appendingPathComponent("codesign")
        try Self.writeTool(codesign, """
            #!/bin/zsh
            app="${@: -1}"
            if [[ -f '\(failTargetVerificationFlag.path)' && "${app:t}" == '会议录音.app' ]]; then exit 1; fi
            exit 0
            """)
        let open = toolsRoot.appendingPathComponent("open")
        try Self.writeTool(open, "#!/bin/zsh\nprint -r -- \"$1\" > '\(openCalledFlag.path)'\n")
        let quit = toolsRoot.appendingPathComponent("quit")
        try Self.writeTool(quit, "#!/bin/zsh\n: > '\(quitCalledFlag.path)'\n")
        let pgrep = toolsRoot.appendingPathComponent("pgrep")
        try Self.writeTool(pgrep, "#!/bin/zsh\n[[ -f '\(stateRoot.appendingPathComponent("pids").path)' ]] && /bin/cat '\(stateRoot.appendingPathComponent("pids").path)'\nexit 0\n")
        let ps = toolsRoot.appendingPathComponent("ps")
        try Self.writeTool(ps, """
            #!/bin/zsh
            pid=""
            for argument in "$@"; do
                [[ "$argument" == <-> ]] && pid="$argument"
            done
            path='\(stateRoot.path)/path-'"$pid"
            [[ -f "$path" ]] && /bin/cat "$path"
            exit 0
            """)
        let sleep = toolsRoot.appendingPathComponent("sleep")
        try Self.writeTool(sleep, "#!/bin/zsh\nexit 0\n")
        dittoPartialFailure = toolsRoot.appendingPathComponent("ditto-partial-failure")
        try Self.writeTool(dittoPartialFailure, """
            #!/bin/zsh
            /bin/mkdir -p "$2"
            : > "$2/partial"
            exit 9
            """)
        mvRestoreFailure = toolsRoot.appendingPathComponent("mv-restore-failure")
        try Self.writeTool(mvRestoreFailure, """
            #!/bin/zsh
            source="${1:A}"
            destination="${2:A}"
            expected_backup='\(backupApp.path)'
            expected_target='\(targetApp.path)'
            expected_backup="${expected_backup:A}"
            expected_target="${expected_target:A}"
            if [[ "$source" == "$expected_backup" && "$destination" == "$expected_target" ]]; then exit 10; fi
            /bin/mv "$1" "$2"
            """)

        environment = ProcessInfo.processInfo.environment
        environment["MEETING_RECORDER_INSTALL_TESTING"] = "1"
        environment["MEETING_RECORDER_TEST_ROOT"] = root.path
        environment["MEETING_RECORDER_SOURCE_ROOT"] = sourceRoot.path
        environment["MEETING_RECORDER_INSTALL_ROOT"] = installRoot.path
        environment["MEETING_RECORDER_BACKUP_ROOT"] = backupRoot.path
        environment["MEETING_RECORDER_CODESIGN_TOOL"] = codesign.path
        environment["MEETING_RECORDER_OPEN_TOOL"] = open.path
        environment["MEETING_RECORDER_QUIT_TOOL"] = quit.path
        environment["MEETING_RECORDER_PGREP_TOOL"] = pgrep.path
        environment["MEETING_RECORDER_PS_TOOL"] = ps.path
        environment["MEETING_RECORDER_SLEEP_TOOL"] = sleep.path
        environment["MEETING_RECORDER_QUIT_ATTEMPTS"] = "1"
        environment["MEETING_RECORDER_TEST_BACKUP_STAMP"] = Self.stamp

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedTarget = targetApp.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedTarget.hasPrefix(resolvedRoot + "/") else {
            throw InstallHarnessError.unsafeTarget
        }
    }

    func installOldApp(marker: String) throws {
        try Self.makeApp(at: targetApp, marker: marker)
    }

    func targetMarker() throws -> String {
        try String(contentsOf: targetApp.appendingPathComponent("marker"), encoding: .utf8)
    }

    func setProcesses(_ processes: [String: String]) throws {
        let pids = processes.keys.sorted().joined(separator: "\n") + "\n"
        try Data(pids.utf8).write(to: stateRoot.appendingPathComponent("pids"))
        for (pid, path) in processes {
            let canonicalPath = path.hasPrefix("/var/") ? "/private\(path)" : path
            try Data((canonicalPath + "\n").utf8).write(to: stateRoot.appendingPathComponent("path-\(pid)"))
        }
    }

    func makeSignalStageTools(
        signal: String,
        outsideMarkers: URL
    ) throws -> (move: URL, ditto: URL, open: URL) {
        let move = toolsRoot.appendingPathComponent("move-signal-\(signal)")
        try Self.writeTool(move, """
            #!/bin/zsh
            /bin/mv "$1" "$2"
            if [[ ! -f '\(outsideMarkers.appendingPathComponent("backup-moved").path)' ]]; then
                : > '\(outsideMarkers.appendingPathComponent("backup-moved").path)'
                attempts=0
                while [[ ! -f '\(outsideMarkers.appendingPathComponent("release-move").path)' ]]; do
                    (( attempts >= 500 )) && exit 91
                    /bin/sleep 0.01
                    (( attempts += 1 ))
                done
            fi
            """)
        let ditto = toolsRoot.appendingPathComponent("ditto-signal-\(signal)")
        try Self.writeTool(ditto, """
            #!/bin/zsh
            : > '\(outsideMarkers.appendingPathComponent("ditto-called").path)'
            /usr/bin/ditto "$@"
            """)
        let open = toolsRoot.appendingPathComponent("open-signal-\(signal)")
        try Self.writeTool(open, """
            #!/bin/zsh
            : > '\(outsideMarkers.appendingPathComponent("open-called").path)'
            """)
        return (move, ditto, open)
    }

    func runSendingSignalAfterBackupMove(
        _ signal: String,
        outsideMarkers: URL
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = installScript
        process.arguments = ["2026-08-18"]
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let moved = outsideMarkers.appendingPathComponent("backup-moved")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: moved.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard FileManager.default.fileExists(atPath: moved.path) else {
            process.terminate()
            process.waitUntilExit()
            throw InstallHarnessError.signalStageNotReached
        }

        let sendSignal = Process()
        sendSignal.executableURL = URL(fileURLWithPath: "/bin/kill")
        sendSignal.arguments = ["-s", signal, String(process.processIdentifier)]
        try sendSignal.run()
        sendSignal.waitUntilExit()
        guard sendSignal.terminationStatus == 0 else {
            process.terminate()
            process.waitUntilExit()
            throw InstallHarnessError.signalDeliveryFailed
        }
        try Data().write(to: outsideMarkers.appendingPathComponent("release-move"))

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func run() throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = installScript
        process.arguments = ["2026-08-18"]
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    static func makeTemporaryDirectory(named prefix: String) throws -> URL {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mktemp")
        process.arguments = [
            "-d",
            FileManager.default.temporaryDirectory
                .appendingPathComponent("\(prefix).XXXXXX")
                .path,
        ]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            throw InstallHarnessError.setup
        }
        let canonicalPath = path.hasPrefix("/var/") ? "/private\(path)" : path
        return URL(fileURLWithPath: canonicalPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func makeApp(at url: URL, marker: String) throws {
        let executable = url.appendingPathComponent("Contents/MacOS/MeetingRecorderApp")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/zsh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.alan.local-meeting-recorder</string>
        <key>LSUIElement</key><true/>
        </dict></plist>
        """
        try Data(plist.utf8).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(marker.utf8).write(to: url.appendingPathComponent("marker"))
    }

    private static func writeTool(_ url: URL, _ source: String) throws {
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private enum InstallHarnessError: Error {
    case setup
    case unsafeTarget
    case signalStageNotReached
    case signalDeliveryFailed
}

@MainActor
private final class LiveLifecycleHarness {
    let directory: URL
    let workingURL: URL
    let finalURL: URL
    let capture: LifecycleCaptureSpy
    let writer: LifecycleWriterSpy
    let session: LiveRecordingSessionManager
    let coordinator: RecordingCoordinator
    let lifecycle: AppLifecycle
    private(set) var replyCount = 0

    init(
        suspendCaptureStart: Bool = false,
        finishGate: LifecycleAsyncGate? = nil,
        finishError: RecordingFailure? = nil
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workingURL = directory.appendingPathComponent(".meeting.inprogress.mov")
        finalURL = directory.appendingPathComponent("meeting.m4a")
        let paths = RecordingPaths(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            directoryURL: directory,
            workingURL: workingURL,
            finalURL: finalURL,
            recoveredURL: directory.appendingPathComponent("meeting-recovered.m4a")
        )
        let captureGate = suspendCaptureStart ? LifecycleAsyncGate() : nil
        let capture = LifecycleCaptureSpy(startGate: captureGate)
        let writer = LifecycleWriterSpy(
            workingURL: workingURL,
            finishGate: finishGate,
            finishError: finishError
        )
        let session = LiveRecordingSessionManager(
            activityGate: RecordingActivityGate(),
            store: LifecycleStoreSpy(paths: paths),
            capture: capture,
            permissions: LifecyclePermissionSpy(),
            sleep: LifecycleSleepSpy(),
            notifications: LifecycleNotificationSpy(),
            writerFactory: { _ in writer },
            converterFactory: { SampleBufferConverter() },
            mixerFactory: {
                AudioTimelineMixer(sampleRate: 48_000, channels: 2, chunkFrames: 960)
            },
            now: Date.init,
            sampleQueueCapacity: 8
        )
        let coordinator = RecordingCoordinator(session: session)
        self.capture = capture
        self.writer = writer
        self.session = session
        self.coordinator = coordinator
        lifecycle = AppLifecycle(
            showMenu: {},
            setRecoveryStatus: { _, _ in },
            recoveryRoot: directory,
            recover: { RecoveryBatchResult(results: [], batchFailure: nil) },
            notifyRecoveryResult: { _ in },
            registerHotkey: {},
            applyLoginItemSetting: {},
            startupError: { _ in },
            phase: { coordinator.phase },
            stopRecording: { await coordinator.toggleRecording() },
            awaitSessionStop: { _ = try await session.stop() }
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var reply: @MainActor () -> Void {
        { [weak self] in self?.replyCount += 1 }
    }
}

private actor LifecycleStoreSpy: RecordingSessionStoring {
    let paths: RecordingPaths
    init(paths: RecordingPaths) { self.paths = paths }
    func prepare(startedAt: Date) async throws -> RecordingPaths { paths }
    func releaseReservation(for outputURL: URL) async {}
}

private actor LifecycleCaptureSpy: AudioCapturing {
    private let startGate: LifecycleAsyncGate?
    private var startEntered = false
    private(set) var stopCallCount = 0

    init(startGate: LifecycleAsyncGate?) { self.startGate = startGate }

    func start(eventHandler: @escaping @Sendable (AudioCaptureEvent) async -> Void) async throws {
        startEntered = true
        if let startGate {
            await startGate.wait()
            throw CancellationError()
        }
    }

    func stop() async {
        stopCallCount += 1
        await startGate?.open()
    }

    func updateDefaultMicrophone() async throws {}

    func waitUntilStartEntered() async {
        while !startEntered { await Task.yield() }
    }
}

private final class LifecyclePermissionSpy: PermissionChecking, @unchecked Sendable {
    func currentStatus() async -> CapturePermissionStatus { CapturePermissionStatus(missing: []) }
    func requestMissingPermissions() async -> CapturePermissionStatus { CapturePermissionStatus(missing: []) }
}

private final class LifecycleSleepSpy: SleepPreventing, @unchecked Sendable {
    func begin() {}
    func end() {}
}

private actor LifecycleNotificationSpy: RecordingNotifying {
    func saved(_ recording: SavedRecording) async {}
    func failed(_ failure: RecordingFailure) async {}
}

private actor CompositionPermissionSpy: PermissionChecking {
    struct Snapshot: Sendable {
        let currentCount: Int
        let requestCount: Int
        let events: [String]
    }

    private let statuses: [CapturePermissionStatus]
    private let requestGate: LifecycleAsyncGate?
    private var currentCount = 0
    private var requestCount = 0
    private var events: [String] = []

    init(statuses: [CapturePermissionStatus], suspendRequest: Bool = false) {
        precondition(!statuses.isEmpty)
        self.statuses = statuses
        requestGate = suspendRequest ? LifecycleAsyncGate() : nil
    }

    func currentStatus() async -> CapturePermissionStatus {
        currentCount += 1
        let status = statuses[min(currentCount - 1, statuses.count - 1)]
        events.append("current.\(currentCount).\(status.isGranted ? "granted" : "denied")")
        return status
    }

    func requestMissingPermissions() async -> CapturePermissionStatus {
        requestCount += 1
        let requestNumber = requestCount
        events.append("request.\(requestNumber).started")
        await requestGate?.wait()
        events.append("request.\(requestNumber).finished")
        return statuses[min(currentCount, statuses.count - 1)]
    }

    var snapshot: Snapshot {
        Snapshot(currentCount: currentCount, requestCount: requestCount, events: events)
    }

    func releaseRequest() async {
        await requestGate?.open()
    }

    func waitForRequestCount(_ expected: Int) async -> Bool {
        await waitUntil { self.requestCount >= expected }
    }

    func waitForCurrentCount(_ expected: Int) async -> Bool {
        await waitUntil { self.currentCount >= expected }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !condition() {
            guard clock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }
}

private actor CompositionBlockingCapture: AudioCapturing {
    private let gate = LifecycleAsyncGate()
    private let suspendStart: Bool
    private var startEntered = false
    private(set) var startCallCount = 0

    init(suspendStart: Bool = true) {
        self.suspendStart = suspendStart
    }

    func start(eventHandler: @escaping @Sendable (AudioCaptureEvent) async -> Void) async throws {
        startCallCount += 1
        startEntered = true
        guard suspendStart else { return }
        await gate.wait()
        throw CancellationError()
    }

    func stop() async {
        await gate.open()
    }

    func updateDefaultMicrophone() async throws {}

    func waitUntilStartEntered() async {
        while !startEntered { await Task.yield() }
    }
}

private final class CompositionSleepSpy: SleepPreventing, @unchecked Sendable {
    func begin() {}
    func end() {}
}

private actor CompositionNotificationSpy: RecordingNotifying {
    func saved(_ recording: SavedRecording) async {}
    func failed(_ failure: RecordingFailure) async {}
}

private final class CompositionSignal: @unchecked Sendable {
    private let signalStream = AsyncStream<Void>.makeStream()

    func signal() {
        signalStream.continuation.yield()
    }

    func wait() async {
        var iterator = signalStream.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

private actor LifecycleWriterSpy: RecoverableAudioWriting {
    private let workingURL: URL
    private let finishGate: LifecycleAsyncGate?
    private let finishError: RecordingFailure?
    private var finishEntered = false
    private(set) var finishCallCount = 0
    private(set) var abortCallCount = 0

    init(workingURL: URL, finishGate: LifecycleAsyncGate?, finishError: RecordingFailure?) {
        self.workingURL = workingURL
        self.finishGate = finishGate
        self.finishError = finishError
    }

    func start() async throws {
        FileManager.default.createFile(atPath: workingURL.path, contents: Data("working".utf8))
    }

    func append(_ chunk: MixedAudioChunk) async throws {}

    func finish(finalURL: URL) async throws -> URL {
        finishCallCount += 1
        finishEntered = true
        await finishGate?.wait()
        if let finishError { throw finishError }
        FileManager.default.createFile(atPath: finalURL.path, contents: Data())
        try FileManager.default.removeItem(at: workingURL)
        return finalURL
    }

    func abort() async { abortCallCount += 1 }

    func waitUntilFinishEntered() async {
        while !finishEntered { await Task.yield() }
    }
}

private actor LifecycleAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
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
    private let feedback: RecoveryFeedbackSpy
    let lifecycle: AppLifecycle

    var calls: [String] { callLog.calls }
    var recoveryStates: [Bool] { recovery.states }
    var recoveryMessages: [String?] { recovery.messages }
    var startupErrors: [String] { startup.messages }
    var feedbacks: [RecoveryFeedback] { feedback.values }

    init(
        phase: RecordingPhase = .idle,
        recoveryRoot: URL = URL(fileURLWithPath: "/tmp/recording-root", isDirectory: true),
        recoveryResults: [RecoveryResult] = [],
        recoveryError: Error? = nil,
        hotkeyError: Error? = nil,
        loginError: Error? = nil,
        sessionStopError: Error? = nil,
        suspendRecovery: Bool = false
    ) {
        let callLog = LifecycleCallLog()
        let recovery = RecoveryServiceSpy(
            calls: callLog,
            results: recoveryResults,
            error: recoveryError,
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
        let feedback = RecoveryFeedbackSpy()
        self.callLog = callLog
        self.recovery = recovery
        self.hotkey = hotkey
        self.coordinator = coordinator
        self.termination = termination
        self.startup = startup
        self.feedback = feedback

        lifecycle = AppLifecycle(
            showMenu: { callLog.calls.append("menu.show") },
            setRecoveryStatus: recovery.setStatus,
            recoveryRoot: recoveryRoot,
            recover: recovery.run,
            notifyRecoveryResult: { result in
                switch result.outcome {
                case .recovered:
                    callLog.calls.append("notification.saved")
                case .failed:
                    callLog.calls.append("notification.failed")
                }
            },
            publishRecoveryFeedback: feedback.publish,
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
    private let error: Error?
    private let suspend: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var states: [Bool] = []
    private(set) var messages: [String?] = []

    init(calls: LifecycleCallLog, results: [RecoveryResult], error: Error?, suspend: Bool) {
        self.calls = calls
        self.results = results
        self.error = error
        self.suspend = suspend
    }

    func setStatus(_ isRecovering: Bool, _ message: String?) {
        states.append(isRecovering)
        messages.append(message)
    }

    func run() async -> RecoveryBatchResult {
        calls.calls.append("recovery.run")
        entered = true
        if suspend {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        let failure = error.map { error in
            if let failure = error as? RecordingFailure { return failure }
            return RecordingFailure(code: .write, message: error.localizedDescription)
        }
        return RecoveryBatchResult(results: results, batchFailure: failure)
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

private actor LifecycleSequencedRecoveryStore: InterruptedRecordingStoring {
    private var outcomes: [Result<[URL], RecordingFailure>]

    init(outcomes: [Result<[URL], RecordingFailure>]) {
        self.outcomes = outcomes
    }

    func listInterruptedRecordings() async throws -> [URL] {
        guard !outcomes.isEmpty else { return [] }
        return try outcomes.removeFirst().get()
    }

    func recoveredURL(for workingURL: URL) async throws -> URL {
        throw RecordingFailure(code: .write, message: "unexpected recoveredURL call")
    }

    func releaseReservation(for outputURL: URL) async {}
}

private actor LifecycleRecoveryFinalizerSpy: InterruptedRecordingFinalizing {
    func recover(workingURL: URL, recoveredURL: URL) async throws -> URL {
        recoveredURL
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

@MainActor
private final class RecoveryFeedbackSpy {
    private(set) var values: [RecoveryFeedback] = []

    func publish(_ feedback: RecoveryFeedback) {
        values.append(feedback)
    }
}
