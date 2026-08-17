import AppKit
import MeetingRecorderCore
import SwiftUI
import XCTest
@testable import MeetingRecorderApp

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
        XCTAssertEqual(popover.contentSize, NSSize(width: 292, height: 470))
        XCTAssertTrue(statusItem.button?.target === controller)
        XCTAssertEqual(statusItem.button?.action, #selector(MenuBarController.togglePopover))
        XCTAssertEqual(statusItem.button?.accessibilityLabel(), "会议录音，无法开始录音：需要授权")
        XCTAssertFalse(statusItem.button?.accessibilityLabel()?.contains("正在录音") == true)
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

    func testSettingsWindowReusesOneWindow() {
        let controller = SettingsWindowController()
        let model = SettingsViewModel.preview

        controller.show(model: model)
        let firstWindow = controller.window
        controller.show(model: model)

        XCTAssertTrue(firstWindow === controller.window)
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

        try capture(
            AnyView(MenuBarView(model: .preview())),
            size: NSSize(width: 292, height: 470),
            at: directory.appendingPathComponent("菜单栏-待机-2026-08-17.png")
        )
        try capture(
            AnyView(MenuBarView(model: .preview(
                phase: .recording(active, warning: nil),
                elapsed: 90_061,
                audioLevels: AudioLevels(system: 0.72, microphone: 0.48)
            ))),
            size: NSSize(width: 292, height: 470),
            at: directory.appendingPathComponent("菜单栏-录音-2026-08-17.png")
        )
        try capture(
            AnyView(MenuBarView(model: .preview(
                phase: .recording(active, warning: warning),
                elapsed: 72,
                audioLevels: AudioLevels(system: 0.64, microphone: 0)
            ))),
            size: NSSize(width: 292, height: 470),
            at: directory.appendingPathComponent("菜单栏-麦克风提醒-2026-08-17.png")
        )
        try capture(
            AnyView(MenuBarView(model: .preview(
                phase: .stopping(active),
                elapsed: 86
            ))),
            size: NSSize(width: 292, height: 470),
            at: directory.appendingPathComponent("菜单栏-保存-2026-08-17.png")
        )
        try capture(
            AnyView(MenuBarView(model: .preview(
                phase: .failed(longFailure),
                permissionMessage: longFailure.message
            ))),
            size: NSSize(width: 292, height: 470),
            at: directory.appendingPathComponent("菜单栏-权限失败-2026-08-17.png")
        )
        try capture(
            AnyView(MenuBarView(model: .preview(
                isRecovering: true,
                recoveryMessage: "正在恢复：会议录音-2026-08-16-23-58-09-未完整恢复.m4a"
            ))),
            size: NSSize(width: 292, height: 470),
            at: directory.appendingPathComponent("菜单栏-恢复-2026-08-17.png")
        )
        try capture(
            AnyView(SettingsView(model: .preview)),
            size: NSSize(width: 480, height: 480),
            at: directory.appendingPathComponent("设置-2026-08-17.png")
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
        try capture(
            AnyView(SettingsView(model: narrowModel)),
            size: NSSize(width: 420, height: 520),
            at: directory.appendingPathComponent("设置-窄窗口-2026-08-17.png")
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

    init(failingDescriptor: HotkeyDescriptor? = nil) {
        self.failingDescriptor = failingDescriptor
    }

    func register(_ descriptor: HotkeyDescriptor, handler: @escaping @Sendable () -> Void) throws {
        registrations.append(descriptor)
        if descriptor == failingDescriptor { throw TestError.rejected }
    }

    func unregister() {}
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
