import AppKit
import MeetingRecorderCore
import SwiftUI
import XCTest
@testable import MeetingRecorderApp

@MainActor
private final class MenuSessionSpy: RecordingSessionManaging {
    func events() async -> AsyncStream<RecordingSessionEvent> {
        AsyncStream { $0.finish() }
    }

    func start(at date: Date) async throws -> ActiveRecording {
        ActiveRecording(startedAt: date, workingURL: URL(fileURLWithPath: "/tmp/working.mov"))
    }

    func stop() async throws -> SavedRecording {
        SavedRecording(
            startedAt: Date(),
            duration: 0,
            fileURL: URL(fileURLWithPath: "/tmp/saved.m4a"),
            recovered: false
        )
    }
}

@MainActor
final class MenuBarPresentationTests: XCTestCase {
    private let active = ActiveRecording(
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        workingURL: URL(fileURLWithPath: "/tmp/meeting.inprogress.mov")
    )

    func testIdlePresentationOffersStartWithoutTimerInMenuBar() {
        let presentation = MenuBarPresentation(phase: .idle, elapsed: 0)

        XCTAssertEqual(presentation.statusText, "待机")
        XCTAssertEqual(presentation.timerText, "00:00:00")
        XCTAssertEqual(presentation.menuBarTitle, "")
        XCTAssertEqual(presentation.tone, .idle)
        XCTAssertEqual(presentation.primaryActionTitle, "开始录音")
        XCTAssertTrue(presentation.isPrimaryActionEnabled)
        XCTAssertEqual(presentation.accessibilityLabel, "会议录音，待机")
    }

    func testPreparingAndStoppingDisableRepeatedAction() {
        let preparing = MenuBarPresentation(phase: .preparing, elapsed: 0)
        let stopping = MenuBarPresentation(phase: .stopping(active), elapsed: 63)

        XCTAssertEqual(preparing.statusText, "正在准备录音")
        XCTAssertEqual(preparing.primaryActionTitle, "正在准备…")
        XCTAssertEqual(preparing.tone, .busy)
        XCTAssertFalse(preparing.isPrimaryActionEnabled)
        XCTAssertEqual(stopping.statusText, "正在保存录音")
        XCTAssertEqual(stopping.primaryActionTitle, "正在保存…")
        XCTAssertEqual(stopping.tone, .busy)
        XCTAssertFalse(stopping.isPrimaryActionEnabled)
        XCTAssertEqual(stopping.timerText, "00:01:03")
    }

    func testRecordingUsesRecordingToneAndStopAction() {
        let presentation = MenuBarPresentation(
            phase: .recording(active, warning: nil),
            elapsed: 2_538
        )

        XCTAssertEqual(presentation.statusText, "正在录音")
        XCTAssertEqual(presentation.timerText, "00:42:18")
        XCTAssertEqual(presentation.menuBarTitle, "00:42:18")
        XCTAssertEqual(presentation.tone, .recording)
        XCTAssertEqual(presentation.primaryActionTitle, "停止并保存")
        XCTAssertEqual(presentation.accessibilityLabel, "会议录音，正在录音，已录制 00:42:18")
    }

    func testElapsedTimeDoesNotWrapAfterTwentyFourHours() {
        let presentation = MenuBarPresentation(
            phase: .recording(active, warning: nil),
            elapsed: 90_061
        )

        XCTAssertEqual(presentation.timerText, "25:01:01")
        XCTAssertEqual(presentation.menuBarTitle, "25:01:01")
    }

    func testMicrophoneWarningKeepsRecordingTruthAndExposesWarning() {
        let warning = RecordingFailure(code: .microphone, message: "未检测到麦克风，系统声音仍在录制。")
        let presentation = MenuBarPresentation(
            phase: .recording(active, warning: warning),
            elapsed: 12
        )

        XCTAssertEqual(presentation.statusText, "正在录音")
        XCTAssertEqual(presentation.tone, .warning)
        XCTAssertEqual(presentation.warningText, warning.message)
        XCTAssertEqual(presentation.primaryActionTitle, "停止并保存")
        XCTAssertTrue(presentation.accessibilityLabel.contains("麦克风警告"))
    }

    func testPermissionFailureNeverClaimsRecording() {
        let presentation = MenuBarPresentation(
            phase: .failed(.init(code: .permission, message: "需要授权")),
            elapsed: 0
        )

        XCTAssertFalse(presentation.statusText.contains("录音中"))
        XCTAssertFalse(presentation.accessibilityLabel.contains("正在录音"))
        XCTAssertEqual(presentation.statusText, "无法开始录音")
        XCTAssertEqual(presentation.tone, .warning)
        XCTAssertEqual(presentation.primaryActionTitle, "重新尝试")
        XCTAssertEqual(presentation.errorText, "需要授权")
    }

    func testNonPermissionFailureUsesAccurateFailureCopy() {
        let presentation = MenuBarPresentation(
            phase: .failed(.init(code: .write, message: "磁盘写入失败")),
            elapsed: 3
        )

        XCTAssertEqual(presentation.statusText, "录音失败")
        XCTAssertEqual(presentation.accessibilityLabel, "会议录音，录音失败：磁盘写入失败")
        XCTAssertEqual(presentation.menuBarTitle, "")
    }

    func testShortcutRequiresControlOrCommand() {
        XCTAssertThrowsError(try ShortcutDescriptorFactory.make(
            keyCode: 15,
            modifierFlags: [.option],
            charactersIgnoringModifiers: "r"
        )) { error in
            XCTAssertEqual(error as? ShortcutCaptureError, .missingRequiredModifier)
        }

        let descriptor = try? ShortcutDescriptorFactory.make(
            keyCode: 15,
            modifierFlags: [.control, .option],
            charactersIgnoringModifiers: "r"
        )
        XCTAssertEqual(descriptor?.displayText, "⌃⌥R")
    }

    func testEscapeCancelsShortcutCaptureWithoutCreatingShortcut() throws {
        let capture = ShortcutCaptureController(monitor: ShortcutMonitorSpy())
        var cancelCount = 0
        var captureCount = 0
        capture.onCancel = { cancelCount += 1 }
        capture.onCapture = { _ in captureCount += 1 }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))

        XCTAssertNil(capture.handle(event))
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(captureCount, 0)
    }

    func testShortcutMonitorExistsOnlyWhileFocusedInActiveWindow() {
        let monitor = ShortcutMonitorSpy()
        let capture = ShortcutCaptureController(monitor: monitor)

        capture.update(isFocused: true, windowIsActive: false)
        XCTAssertEqual(monitor.installCount, 0)
        capture.update(isFocused: true, windowIsActive: true)
        XCTAssertEqual(monitor.installCount, 1)
        capture.update(isFocused: false, windowIsActive: true)
        XCTAssertEqual(monitor.removeCount, 1)
    }

    func testShortcutMonitorIsRemovedWhenCaptureControllerIsReleased() {
        let monitor = ShortcutMonitorSpy()
        var capture: ShortcutCaptureController? = ShortcutCaptureController(monitor: monitor)
        capture?.update(isFocused: true, windowIsActive: true)

        capture = nil

        XCTAssertEqual(monitor.installCount, 1)
        XCTAssertEqual(monitor.removeCount, 1)
    }

    func testMenuBarControllerConfiguresTransientAccessibleStatusButton() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let popover = NSPopover()
        let controller = MenuBarController(statusItem: statusItem, popover: popover)
        let model = MenuBarViewModel.preview()

        controller.show(rootView: MenuBarView(model: model))
        controller.update(MenuBarPresentation(
            phase: .failed(.init(code: .permission, message: "需要授权")),
            elapsed: 0
        ))

        XCTAssertEqual(popover.behavior, .transient)
        XCTAssertEqual(popover.contentSize.width, 292)
        XCTAssertTrue(statusItem.button?.target === controller)
        XCTAssertEqual(statusItem.button?.action, #selector(MenuBarController.togglePopover))
        XCTAssertEqual(statusItem.button?.accessibilityLabel(), "会议录音，无法开始录音：需要授权")
        XCTAssertFalse(statusItem.button?.accessibilityLabel()?.contains("正在录音") == true)

        controller.bind(to: model)
        XCTAssertEqual(popover.contentSize.height, 320)
        model.permissionMessage = "请开启录音权限。"
        XCTAssertEqual(popover.contentSize.height, 416)
        model.permissionMessage = nil
        XCTAssertEqual(popover.contentSize.height, 320)
    }

    func testPermissionRequestGrantedOnRecheckStartsExactlyOnce() async {
        let missing = CapturePermissionStatus(missing: [.systemAudio, .microphone])
        let granted = CapturePermissionStatus(missing: [])
        let permissions = PermissionCheckingSpy(
            currentResponses: [missing, granted],
            requestResponse: granted
        )
        var toggleCount = 0
        var messages: [String?] = []
        let action = PermissionGatedRecordingAction(
            permissions: permissions,
            phase: { .idle },
            toggle: { toggleCount += 1 },
            updatePermissionMessage: { messages.append($0) },
            notifications: NoopNotificationSpy()
        )

        await action.perform()

        XCTAssertEqual(permissions.requestCount, 1)
        XCTAssertEqual(permissions.currentCount, 2)
        XCTAssertEqual(toggleCount, 1)
        XCTAssertNil(messages.last ?? "unexpected")
    }

    func testPermissionRequestDeniedShowsMessageWithoutAutomaticRetry() async {
        let missing = CapturePermissionStatus(missing: [.systemAudio])
        let permissions = PermissionCheckingSpy(
            currentResponses: [missing, missing],
            requestResponse: missing
        )
        var toggleCount = 0
        var message: String?
        let action = PermissionGatedRecordingAction(
            permissions: permissions,
            phase: { .failed(.init(code: .permission, message: "需要授权")) },
            toggle: { toggleCount += 1 },
            updatePermissionMessage: { message = $0 },
            notifications: NoopNotificationSpy()
        )

        await action.perform()

        XCTAssertEqual(permissions.requestCount, 1)
        XCTAssertEqual(permissions.currentCount, 2)
        XCTAssertEqual(toggleCount, 0)
        XCTAssertEqual(message, missing.userMessage)
    }

    func testStoppingRecordingNeverRequestsPermissionAgain() async {
        let missing = CapturePermissionStatus(missing: [.microphone])
        let permissions = PermissionCheckingSpy(
            currentResponses: [missing],
            requestResponse: missing
        )
        var toggleCount = 0
        let recording = RecordingPhase.recording(active, warning: nil)
        let action = PermissionGatedRecordingAction(
            permissions: permissions,
            phase: { recording },
            toggle: { toggleCount += 1 },
            updatePermissionMessage: { _ in },
            notifications: NoopNotificationSpy()
        )

        await action.perform()

        XCTAssertEqual(permissions.currentCount, 0)
        XCTAssertEqual(permissions.requestCount, 0)
        XCTAssertEqual(toggleCount, 1)
    }

    func testOpenTodayKeepsUsingLaunchRootAfterExpectedSettingChanges() {
        let launchRoot = URL(fileURLWithPath: "/tmp/launch-root", isDirectory: true)
        let changedRoot = URL(fileURLWithPath: "/tmp/changed-root", isDirectory: true)
        var settings = AppSettings.default
        settings.recordingRoot = changedRoot
        let resolver = LaunchRecordingLocation(root: launchRoot, timeZone: TimeZone(secondsFromGMT: 0)!)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try! XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 8, day: 22)))

        let target = resolver.target(for: date) { path in
            path.hasPrefix(launchRoot.path) && path.hasSuffix("2024-08-22")
        }

        XCTAssertEqual(settings.recordingRoot, changedRoot)
        XCTAssertEqual(target.path, "/tmp/launch-root/2024-08-22")
        XCTAssertFalse(target.path.hasPrefix(changedRoot.path))
    }

    func testFailedHotkeyRegistrationRestoresOldSettingAndRegistration() {
        let old = AppMetadata.defaultHotkey
        let replacement = HotkeyDescriptor(keyCode: 1, modifiers: 0x0100, displayText: "⌘S")
        let persistence = SettingsPersistenceSpy(settings: .default)
        let hotkey = HotkeyRegistrationSpy(failingDescriptor: replacement)
        let model = SettingsViewModel(
            initialSettings: .default,
            persistence: persistence,
            hotkey: hotkey,
            loginItem: LoginItemSpy()
        )

        model.applyHotkey(replacement)

        XCTAssertEqual(model.settings.hotkey, old)
        XCTAssertEqual(hotkey.registrations, [replacement, old])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(persistence.savedSettings.last?.hotkey, old)
    }

    func testHotkeyTeardownFailureStopsBeforeRegisteringReplacement() {
        let old = AppMetadata.defaultHotkey
        let replacement = HotkeyDescriptor(keyCode: 1, modifiers: 0x0100, displayText: "⌘S")
        let persistence = SettingsPersistenceSpy(settings: .default)
        let hotkey = HotkeyRegistrationSpy()
        let model = SettingsViewModel(
            initialSettings: .default,
            persistence: persistence,
            hotkey: hotkey,
            hotkeyTeardownError: { TestError.rejected },
            loginItem: LoginItemSpy()
        )

        model.applyHotkey(replacement)

        XCTAssertEqual(hotkey.unregisterCount, 1)
        XCTAssertTrue(hotkey.registrations.isEmpty)
        XCTAssertEqual(model.settings.hotkey, old)
        XCTAssertTrue(model.errorMessage?.contains("重启") == true)
    }

    func testFailedLoginItemChangeRestoresOldValue() {
        let persistence = SettingsPersistenceSpy(settings: .default)
        let login = LoginItemSpy(error: TestError.rejected)
        let model = SettingsViewModel(
            initialSettings: .default,
            persistence: persistence,
            hotkey: HotkeyRegistrationSpy(),
            loginItem: login
        )

        model.setLaunchAtLogin(false)

        XCTAssertTrue(model.settings.launchAtLogin)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(persistence.savedSettings.last?.launchAtLogin, true)
    }

    func testShowingSettingsRefreshesExternalLoginItemStateWithoutOverwritingExpectation() {
        let persistence = SettingsPersistenceSpy(settings: .default)
        let login = LoginItemSpy()
        let model = SettingsViewModel(
            initialSettings: .default,
            persistence: persistence,
            hotkey: HotkeyRegistrationSpy(),
            loginItem: login
        )
        login.isEnabled = false

        let controller = SettingsWindowController()
        controller.show(model: model)

        XCTAssertFalse(model.launchAtLoginIsEnabled)
        XCTAssertTrue(model.settings.launchAtLogin)
        XCTAssertTrue(persistence.savedSettings.isEmpty)
        controller.window?.close()
    }

    func testStoppingNeverShowsStaleAudioMeters() {
        let stopping = MenuBarViewModel.preview(
            phase: .stopping(active),
            elapsed: 20,
            audioLevels: AudioLevels(system: 0.9, microphone: 0.8)
        )
        let recording = MenuBarViewModel.preview(
            phase: .recording(active, warning: nil),
            elapsed: 20,
            audioLevels: AudioLevels(system: 0.9, microphone: 0.8)
        )

        XCTAssertFalse(stopping.showsAudioMeter)
        XCTAssertTrue(recording.showsAudioMeter)
    }

    func testRecoveryFailureRemainsVisibleAfterRecoveryAndRevealsFullWorkingPath() {
        let workingURL = URL(fileURLWithPath: "/tmp/recordings/.meeting.inprogress.mov")
        var revealedURL: URL?
        let model = MenuBarViewModel.preview(onRevealRecoveryURL: { revealedURL = $0 })
        let feedback = RecoveryFeedback(
            id: "failed-working",
            title: "录音恢复失败",
            message: "\(workingURL.path)\ncannot finalize",
            revealURL: workingURL,
            isFailure: true
        )

        model.setRecovery(isRecovering: true, message: "recovering")
        model.publishRecoveryFeedback(feedback)
        model.setRecovery(isRecovering: false)

        XCTAssertFalse(model.isRecovering)
        XCTAssertEqual(model.recoveryFeedbacks, [feedback])
        XCTAssertTrue(model.recoveryFeedbacks[0].message.contains(workingURL.path))
        model.revealRecoveryFeedback(id: feedback.id)
        XCTAssertEqual(revealedURL, workingURL)
        model.dismissRecoveryFeedback(id: feedback.id)
        XCTAssertTrue(model.recoveryFeedbacks.isEmpty)
    }

    func testSettingsActionIsBlockedDuringRecovery() {
        let session = MenuSessionSpy()
        let coordinator = RecordingCoordinator(session: session)
        var showSettingsCount = 0
        let model = MenuBarViewModel(
            coordinator: coordinator,
            recordingRoot: AppMetadata.defaultRecordingRoot,
            onPrimaryAction: {},
            onOpenToday: {},
            onShowSettings: { showSettingsCount += 1 }
        )

        model.setRecovery(isRecovering: true)
        model.showSettings()
        XCTAssertEqual(showSettingsCount, 0)

        model.setRecovery(isRecovering: false)
        model.showSettings()
        XCTAssertEqual(showSettingsCount, 1)
    }

    func testSettingsMutationsAreBlockedWhileLifecycleIsRecovering() {
        let replacement = HotkeyDescriptor(keyCode: 1, modifiers: 0x0100, displayText: "⌘S")
        let persistence = SettingsPersistenceSpy(settings: .default)
        let hotkey = HotkeyRegistrationSpy()
        let login = LoginItemSpy()
        let model = SettingsViewModel(
            initialSettings: .default,
            persistence: persistence,
            hotkey: hotkey,
            loginItem: login
        )

        model.setLifecycleBusy(true)
        model.applyHotkey(replacement)
        model.setLaunchAtLogin(false)

        XCTAssertEqual(model.settings, .default)
        XCTAssertTrue(hotkey.registrations.isEmpty)
        XCTAssertTrue(login.isEnabled)
        XCTAssertTrue(persistence.savedSettings.isEmpty)

        model.setLifecycleBusy(false)
        model.applyHotkey(replacement)
        XCTAssertEqual(model.settings.hotkey, replacement)
    }

    func testSettingsWindowReusesOneWindow() {
        let controller = SettingsWindowController()
        let model = SettingsViewModel.preview

        controller.show(model: model)
        let firstWindow = controller.window
        controller.show(model: model)

        XCTAssertTrue(firstWindow === controller.window)
        XCTAssertGreaterThanOrEqual(controller.window?.contentView?.bounds.height ?? 0, 560)
        controller.window?.close()
    }

    func testCaptureVisualStatesWhenRequested() throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment["MEETING_RECORDER_CAPTURE_UI"] else {
            throw XCTSkip("Set MEETING_RECORDER_CAPTURE_UI to capture the visual review states.")
        }
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let longFailure = RecordingFailure(
            code: .permission,
            message: "请在系统设置 > 隐私与安全性中开启屏幕与系统音频录制和麦克风权限。完成后回到这里重新尝试。"
        )
        let warning = RecordingFailure(
            code: .microphone,
            message: "未检测到麦克风，系统声音仍在录制。请检查麦克风连接。"
        )

        try captureMenu(
            model: .preview(),
            at: directory.appendingPathComponent("菜单栏-待机-Round1-2026-08-18.png")
        )
        try captureMenu(
            model: .preview(
                phase: .recording(active, warning: nil),
                elapsed: 90_061,
                audioLevels: AudioLevels(system: 0.72, microphone: 0.48)
            ),
            at: directory.appendingPathComponent("菜单栏-录音-Round1-2026-08-18.png")
        )
        try captureMenu(
            model: .preview(
                phase: .recording(active, warning: warning),
                elapsed: 72,
                audioLevels: AudioLevels(system: 0.64, microphone: 0)
            ),
            at: directory.appendingPathComponent("菜单栏-麦克风提醒-Round1-2026-08-18.png")
        )
        try captureMenu(
            model: .preview(
                phase: .stopping(active),
                elapsed: 86,
                audioLevels: AudioLevels(system: 0.91, microphone: 0.84)
            ),
            at: directory.appendingPathComponent("菜单栏-保存-Round1-2026-08-18.png")
        )
        try captureMenu(
            model: .preview(
                phase: .failed(longFailure),
                permissionMessage: longFailure.message
            ),
            at: directory.appendingPathComponent("菜单栏-权限失败-Round1-2026-08-18.png")
        )
        try captureMenu(
            model: .preview(
                isRecovering: true,
                recoveryMessage: "正在恢复：会议录音-2026-08-16-23-58-09-未完整恢复.m4a"
            ),
            at: directory.appendingPathComponent("菜单栏-恢复-Round1-2026-08-18.png")
        )

        let narrowSettings = AppSettings(
            recordingRoot: URL(fileURLWithPath: "/Users/alan/Documents/一个很长的中文保存目录/会议录音文件/需要在窄窗口中完整换行", isDirectory: true),
            hotkey: AppMetadata.defaultHotkey,
            launchAtLogin: true
        )
        let narrowPersistence = SettingsPersistenceSpy(settings: narrowSettings)
        let narrowModel = SettingsViewModel(
            initialSettings: narrowSettings,
            persistence: narrowPersistence,
            hotkey: HotkeyRegistrationSpy(),
            loginItem: LoginItemSpy()
        )
        let settingsController = SettingsWindowController()
        settingsController.show(model: narrowModel)
        let settingsWindow = try XCTUnwrap(settingsController.window)
        settingsWindow.orderFrontRegardless()
        XCTAssertTrue(settingsWindow.isVisible)
        XCTAssertTrue(settingsWindow.canBecomeKey)
        XCTAssertTrue(settingsWindow.makeFirstResponder(nil))
        try captureWindow(
            settingsWindow,
            at: directory.appendingPathComponent("设置窗口-正常-Round1-2026-08-18.png")
        )

        narrowModel.errorMessage = "无法安全移除旧快捷键。请重启应用后再修改；本次没有注册新快捷键，也没有修改已保存的设置。"
        XCTAssertTrue(settingsWindow.makeFirstResponder(nil))
        try captureWindow(
            settingsWindow,
            at: directory.appendingPathComponent("设置窗口-错误-Round1-2026-08-18.png")
        )

        settingsWindow.setContentSize(settingsWindow.contentMinSize)
        XCTAssertTrue(settingsWindow.makeFirstResponder(nil))
        try captureWindow(
            settingsWindow,
            at: directory.appendingPathComponent("设置窗口-最小尺寸-Round1-2026-08-18.png")
        )

        narrowModel.errorMessage = nil
        settingsWindow.makeKeyAndOrderFront(nil)
        let contentView = try XCTUnwrap(settingsWindow.contentView)
        contentView.layoutSubtreeIfNeeded()
        let recorder = try XCTUnwrap(firstSubview(of: ShortcutRecorderNSView.self, in: contentView))
        XCTAssertTrue(settingsWindow.makeFirstResponder(recorder))
        recorder.needsDisplay = true
        try captureWindow(
            settingsWindow,
            at: directory.appendingPathComponent("设置窗口-快捷键焦点-Round1-2026-08-18.png")
        )
        settingsWindow.makeFirstResponder(nil)
        settingsWindow.close()
    }

    private func captureMenu(model: MenuBarViewModel, at outputURL: URL) throws {
        try capture(
            AnyView(MenuBarView(model: model)),
            size: NSSize(width: 292, height: model.preferredHeight),
            at: outputURL
        )
    }

    private func capture(_ view: AnyView, size: NSSize, at outputURL: URL) throws {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setFrame(NSRect(origin: .zero, size: size), display: false)
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Unable to allocate visual review bitmap for \(outputURL.lastPathComponent)")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Unable to encode visual review PNG for \(outputURL.lastPathComponent)")
        }
        try data.write(to: outputURL, options: .atomic)
        window.close()
    }

    private func captureWindow(_ window: NSWindow, at outputURL: URL) throws {
        let contentView = try XCTUnwrap(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            return XCTFail("Unable to allocate window bitmap for \(outputURL.lastPathComponent)")
        }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Unable to encode window PNG for \(outputURL.lastPathComponent)")
        }
        try data.write(to: outputURL, options: .atomic)
    }

    private func firstSubview<View: NSView>(of type: View.Type, in root: NSView) -> View? {
        if let match = root as? View { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }
}

@MainActor
private final class ShortcutMonitorSpy: ShortcutEventMonitoring {
    private(set) var installCount = 0
    private(set) var removeCount = 0

    func install(_ handler: @escaping @MainActor (NSEvent) -> NSEvent?) -> Any {
        installCount += 1
        return NSObject()
    }

    func remove(_ token: Any) {
        removeCount += 1
    }
}

@MainActor
private final class SettingsPersistenceSpy: SettingsPersisting {
    let loaded: AppSettings
    private(set) var savedSettings: [AppSettings] = []

    init(settings: AppSettings) {
        loaded = settings
    }

    func load() -> AppSettings { loaded }
    func save(_ settings: AppSettings) { savedSettings.append(settings) }
}

@MainActor
private final class HotkeyRegistrationSpy: HotkeyRegistering {
    private let failingDescriptor: HotkeyDescriptor?
    private(set) var registrations: [HotkeyDescriptor] = []
    private(set) var unregisterCount = 0

    init(failingDescriptor: HotkeyDescriptor? = nil) {
        self.failingDescriptor = failingDescriptor
    }

    func register(_ descriptor: HotkeyDescriptor, handler: @escaping @Sendable () -> Void) throws {
        registrations.append(descriptor)
        if descriptor == failingDescriptor { throw TestError.rejected }
    }

    func unregister() { unregisterCount += 1 }
}

private final class PermissionCheckingSpy: PermissionChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var currentResponses: [CapturePermissionStatus]
    private let requestResponse: CapturePermissionStatus
    private(set) var currentCount = 0
    private(set) var requestCount = 0

    init(
        currentResponses: [CapturePermissionStatus],
        requestResponse: CapturePermissionStatus
    ) {
        self.currentResponses = currentResponses
        self.requestResponse = requestResponse
    }

    func currentStatus() async -> CapturePermissionStatus {
        lock.withLock {
            currentCount += 1
            if currentResponses.count > 1 {
                return currentResponses.removeFirst()
            }
            return currentResponses.first ?? requestResponse
        }
    }

    func requestMissingPermissions() async -> CapturePermissionStatus {
        lock.withLock { requestCount += 1 }
        return requestResponse
    }
}

@MainActor
private final class LoginItemSpy: LoginItemManaging {
    private let error: Error?
    var isEnabled = true

    init(error: Error? = nil) {
        self.error = error
    }

    func setEnabled(_ enabled: Bool) throws {
        if let error { throw error }
        isEnabled = enabled
    }
}

private enum TestError: Error {
    case rejected
}

private final class NoopNotificationSpy: RecordingNotifying, @unchecked Sendable {
    func saved(_ recording: SavedRecording) async {}
    func failed(_ failure: RecordingFailure) async {}
    func permissionNeeded(_ message: String) async {}
}
