import AppKit
import MeetingRecorderCore

@MainActor
final class PermissionGatedRecordingAction {
    private let permissions: any PermissionChecking
    private let phase: () -> RecordingPhase
    private let toggle: () async -> Void
    private let updatePermissionMessage: (String?) -> Void
    private var requestInFlight = false

    init(
        permissions: any PermissionChecking,
        phase: @escaping () -> RecordingPhase,
        toggle: @escaping () async -> Void,
        updatePermissionMessage: @escaping (String?) -> Void
    ) {
        self.permissions = permissions
        self.phase = phase
        self.toggle = toggle
        self.updatePermissionMessage = updatePermissionMessage
    }

    func perform() async {
        switch phase() {
        case .recording:
            await toggle()
        case .preparing, .stopping:
            return
        case .idle, .failed:
            guard !requestInFlight else { return }
            requestInFlight = true
            defer { requestInFlight = false }

            let current = await permissions.currentStatus()
            if current.isGranted {
                updatePermissionMessage(nil)
                await toggle()
                return
            }

            _ = await permissions.requestMissingPermissions()
            let rechecked = await permissions.currentStatus()
            guard rechecked.isGranted else {
                updatePermissionMessage(rechecked.userMessage)
                return
            }

            updatePermissionMessage(nil)
            await toggle()
        }
    }
}

@MainActor
final class RecordingActionEntrypoint {
    let action: PermissionGatedRecordingAction

    init(action: PermissionGatedRecordingAction) {
        self.action = action
    }

    func perform() async {
        await action.perform()
    }
}

enum LifecycleTerminationDisposition: Equatable {
    case terminateNow
    case terminateLater
}

@MainActor
final class AppLifecycle {
    private let showMenu: () -> Void
    private let setRecoveryStatus: (Bool, String?) -> Void
    private let recoveryRoot: URL
    private let recover: () async -> RecoveryBatchResult
    private let notifyRecoveryResult: (RecoveryResult) async -> Void
    private let publishRecoveryFeedback: (RecoveryFeedback) -> Void
    private let registerHotkey: () throws -> Void
    private let applyLoginItemSetting: () throws -> Void
    private let startupError: (String) -> Void
    private let phase: () -> RecordingPhase
    private let stopRecording: () async -> Void
    private let awaitSessionStop: () async throws -> Void

    private var didStart = false
    private var isRecovering = false
    private var launchTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var didReplyToTermination = false

    init(
        showMenu: @escaping () -> Void,
        setRecoveryStatus: @escaping (Bool, String?) -> Void,
        recoveryRoot: URL = AppMetadata.defaultRecordingRoot,
        recover: @escaping () async -> RecoveryBatchResult,
        notifyRecoveryResult: @escaping (RecoveryResult) async -> Void,
        publishRecoveryFeedback: @escaping (RecoveryFeedback) -> Void = { _ in },
        registerHotkey: @escaping () throws -> Void,
        applyLoginItemSetting: @escaping () throws -> Void,
        startupError: @escaping (String) -> Void,
        phase: @escaping () -> RecordingPhase,
        stopRecording: @escaping () async -> Void,
        awaitSessionStop: @escaping () async throws -> Void
    ) {
        self.showMenu = showMenu
        self.setRecoveryStatus = setRecoveryStatus
        self.recoveryRoot = recoveryRoot
        self.recover = recover
        self.notifyRecoveryResult = notifyRecoveryResult
        self.publishRecoveryFeedback = publishRecoveryFeedback
        self.registerHotkey = registerHotkey
        self.applyLoginItemSetting = applyLoginItemSetting
        self.startupError = startupError
        self.phase = phase
        self.stopRecording = stopRecording
        self.awaitSessionStop = awaitSessionStop
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        showMenu()
        isRecovering = true

        let task = Task { [weak self] in
            guard let self else { return }
            self.setRecoveryStatus(true, "正在检查上次中断的录音，请稍候。")
            await self.finishLaunch()
        }
        launchTask = task
    }

    func launch() async {
        start()
        await waitForLaunch()
    }

    func waitForLaunch() async {
        let task = launchTask
        await task?.value
    }

    func prepareForTermination(
        reply: @escaping @MainActor () -> Void
    ) -> LifecycleTerminationDisposition {
        if terminationTask != nil {
            return .terminateLater
        }
        guard requiresDeferredTermination else {
            return .terminateNow
        }

        let pendingLaunch = launchTask
        let task = Task { [weak self] in
            guard let self else { return }
            await pendingLaunch?.value
            await self.finishRecordingForTermination()
            guard !self.didReplyToTermination else { return }
            self.didReplyToTermination = true
            reply()
        }
        terminationTask = task
        return .terminateLater
    }

    func waitForTermination() async {
        let task = terminationTask
        await task?.value
    }

    private var requiresDeferredTermination: Bool {
        if isRecovering || launchTask != nil {
            return true
        }
        switch phase() {
        case .preparing, .recording, .stopping:
            return true
        case .idle, .failed:
            return false
        }
    }

    private func finishLaunch() async {
        do {
            let batch = await recover()
            if let failure = batch.batchFailure { throw failure }
            let results = batch.results
            for result in results {
                setRecoveryStatus(true, Self.message(for: result))
                await notifyRecoveryResult(result)
                if case let .failed(workingURL, message) = result.outcome {
                    publishRecoveryFeedback(RecoveryFeedback(
                        id: "recovery-failed-\(workingURL.standardizedFileURL.path)",
                        title: "录音恢复失败",
                        message: "\(workingURL.path)\n\(message)",
                        revealURL: workingURL,
                        isFailure: true
                    ))
                }
            }
            let recoveredCount = results.reduce(into: 0) { count, result in
                if case .recovered = result.outcome { count += 1 }
            }
            if recoveredCount > 0 {
                publishRecoveryFeedback(RecoveryFeedback(
                    id: "recovery-success-summary",
                    title: "录音恢复完成",
                    message: "已恢复 \(recoveredCount) 条中断录音。",
                    revealURL: nil,
                    isFailure: false
                ))
            }
            setRecoveryStatus(false, nil)
        } catch {
            let message = "\(recoveryRoot.path)\n\(Self.errorMessage(error))"
            startupError("恢复中断录音失败：\(message)")
            publishRecoveryFeedback(RecoveryFeedback(
                id: "recovery-batch-failed-\(recoveryRoot.standardizedFileURL.path)",
                title: "无法检查中断录音",
                message: message,
                revealURL: recoveryRoot,
                isFailure: true
            ))
            setRecoveryStatus(false, nil)
        }
        isRecovering = false

        do {
            try registerHotkey()
        } catch {
            startupError("快捷键无法使用：\(error.localizedDescription)")
        }

        do {
            try applyLoginItemSetting()
        } catch {
            startupError("登录启动设置未生效：\(error.localizedDescription)")
        }
        launchTask = nil
    }

    private func finishRecordingForTermination() async {
        switch phase() {
        case .recording:
            await stopRecording()
        case .preparing, .stopping:
            _ = try? await awaitSessionStop()
        case .idle, .failed:
            return
        }
    }

    private static func message(for result: RecoveryResult) -> String {
        switch result.outcome {
        case let .recovered(fileURL):
            "已恢复 \(fileURL.lastPathComponent)"
        case let .failed(workingURL, message):
            "未能恢复 \(workingURL.lastPathComponent)：\(message)"
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        if let failure = error as? RecordingFailure { return failure.message }
        return error.localizedDescription
    }

}

struct LaunchRecordingLocation {
    let root: URL
    let timeZone: TimeZone

    init(root: URL, timeZone: TimeZone = .current) {
        self.root = root
        self.timeZone = timeZone
    }

    func target(
        for date: Date,
        directoryExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = root.appendingPathComponent(formatter.string(from: date), isDirectory: true)
        return directoryExists(today.path) ? today : root
    }
}

@MainActor
private final class PermissionMessageRelay {
    var handler: (String?) -> Void = { _ in }

    func publish(_ message: String?) {
        handler(message)
    }
}

@MainActor
final class ProductionCompositionRoot {
    let settingsStore: AppSettingsStore
    let launchSettings: AppSettings
    let permissions: any PermissionChecking
    let activityGate: RecordingActivityGate
    let recordingStore: RecordingStore
    let capture: any AudioCapturing
    let sleep: any SleepPreventing
    let notifications: any RecordingNotifying
    let session: LiveRecordingSessionManager
    let recovery: RecoveryService
    let coordinator: RecordingCoordinator
    let hotkey: HotkeyService
    let loginItem: LoginItemService
    let recordingEntrypoint: RecordingActionEntrypoint
    let menuRecordingHandler: @Sendable () -> Void
    let hotkeyRecordingHandler: @Sendable () -> Void
    private let permissionMessageRelay: PermissionMessageRelay

    init(
        settingsStore: AppSettingsStore = AppSettingsStore(),
        permissions: any PermissionChecking = PermissionService(),
        capture: any AudioCapturing = ScreenCaptureEngine(),
        sleep: any SleepPreventing = SleepPreventionService(),
        notifications: any RecordingNotifying = NotificationService(),
        sessionFactory: ((
            RecordingActivityGate,
            RecordingStore,
            any AudioCapturing,
            any PermissionChecking,
            any SleepPreventing,
            any RecordingNotifying
        ) -> LiveRecordingSessionManager)? = nil,
        recoveryFactory: ((RecordingActivityGate, RecordingStore) -> RecoveryService)? = nil
    ) {
        self.settingsStore = settingsStore
        let settings = settingsStore.load()
        launchSettings = settings
        let activityGate = RecordingActivityGate()
        let recordingStore = RecordingStore(root: settings.recordingRoot)
        let session = sessionFactory?(
            activityGate,
            recordingStore,
            capture,
            permissions,
            sleep,
            notifications
        ) ?? LiveRecordingSessionManager(
            activityGate: activityGate,
            store: recordingStore,
            capture: capture,
            permissions: permissions,
            sleep: sleep,
            notifications: notifications
        )
        let recovery = recoveryFactory?(activityGate, recordingStore)
            ?? RecoveryService(activityGate: activityGate, store: recordingStore)
        let coordinator = RecordingCoordinator(session: session)
        let permissionMessageRelay = PermissionMessageRelay()
        let recordingAction = PermissionGatedRecordingAction(
            permissions: permissions,
            phase: { coordinator.phase },
            toggle: { await coordinator.toggleRecording() },
            updatePermissionMessage: permissionMessageRelay.publish
        )
        let recordingEntrypoint = RecordingActionEntrypoint(action: recordingAction)
        let recordingHandler: @Sendable () -> Void = {
            Task { @MainActor in await recordingEntrypoint.perform() }
        }

        self.permissions = permissions
        self.activityGate = activityGate
        self.recordingStore = recordingStore
        self.capture = capture
        self.sleep = sleep
        self.notifications = notifications
        self.session = session
        self.recovery = recovery
        self.coordinator = coordinator
        hotkey = HotkeyService()
        loginItem = LoginItemService()
        self.recordingEntrypoint = recordingEntrypoint
        menuRecordingHandler = recordingHandler
        hotkeyRecordingHandler = recordingHandler
        self.permissionMessageRelay = permissionMessageRelay
    }

    func bindPermissionMessageHandler(_ handler: @escaping (String?) -> Void) {
        permissionMessageRelay.handler = handler
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBarController = MenuBarController()
    private var coordinator: RecordingCoordinator?
    private var menuModel: MenuBarViewModel?
    private var settingsModel: SettingsViewModel?
    private var launchRecordingLocation: LaunchRecordingLocation?
    private var lifecycle: AppLifecycle?

    // Retaining the composition root also retains NotificationService's delegate for app lifetime.
    private var compositionRoot: ProductionCompositionRoot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let composition = ProductionCompositionRoot()
        let settingsStore = composition.settingsStore
        let settings = composition.launchSettings
        let permissions = composition.permissions
        let session = composition.session
        let recovery = composition.recovery
        let notifications = composition.notifications
        let coordinator = composition.coordinator
        let hotkey = composition.hotkey
        let loginItem = composition.loginItem

        let settingsModel = SettingsViewModel(
            initialSettings: settings,
            persistence: settingsStore,
            hotkey: hotkey,
            hotkeyTeardownError: { hotkey.lastTeardownError },
            loginItem: loginItem,
            hotkeyAction: composition.hotkeyRecordingHandler
        )

        let menuModel = MenuBarViewModel(
            coordinator: coordinator,
            recordingRoot: settings.recordingRoot,
            onPrimaryAction: composition.menuRecordingHandler,
            onOpenToday: { [weak self] in self?.openToday() },
            onShowSettings: { [weak self] in self?.showSettings() }
        )
        composition.bindPermissionMessageHandler { [weak menuModel] message in
            menuModel?.permissionMessage = message
        }

        let lifecycle = AppLifecycle(
            showMenu: { [menuBarController] in
                menuModel.setRecovery(
                    isRecovering: true,
                    message: "正在检查上次中断的录音，请稍候。"
                )
                settingsModel.setLifecycleBusy(true)
                menuBarController.show(rootView: MenuBarView(model: menuModel))
                menuBarController.bind(to: menuModel)
            },
            setRecoveryStatus: { isRecovering, message in
                menuModel.setRecovery(isRecovering: isRecovering, message: message)
                settingsModel.setLifecycleBusy(isRecovering)
            },
            recoveryRoot: settings.recordingRoot,
            recover: {
                await recovery.recoverInterruptedRecordingsBatch()
            },
            notifyRecoveryResult: { result in
                switch result.outcome {
                case let .recovered(fileURL):
                    let startedAt = (try? fileURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                        ?? Date()
                    await notifications.saved(SavedRecording(
                        startedAt: startedAt,
                        duration: 0,
                        fileURL: fileURL,
                        recovered: true
                    ))
                case let .failed(_, message):
                    await notifications.failed(RecordingFailure(code: .finalize, message: message))
                }
            },
            publishRecoveryFeedback: menuModel.publishRecoveryFeedback,
            registerHotkey: {
                try hotkey.register(
                    settingsModel.settings.hotkey,
                    handler: composition.hotkeyRecordingHandler
                )
            },
            applyLoginItemSetting: {
                try loginItem.setEnabled(settingsModel.settings.launchAtLogin)
                settingsModel.refreshSystemState()
            },
            startupError: { message in
                if let existing = settingsModel.errorMessage, !existing.isEmpty {
                    settingsModel.errorMessage = "\(existing)\n\(message)"
                } else {
                    settingsModel.errorMessage = message
                }
            },
            phase: { coordinator.phase },
            stopRecording: { await composition.recordingEntrypoint.perform() },
            awaitSessionStop: { _ = try await session.stop() }
        )

        self.coordinator = coordinator
        self.settingsModel = settingsModel
        self.menuModel = menuModel
        launchRecordingLocation = LaunchRecordingLocation(root: settings.recordingRoot)
        self.lifecycle = lifecycle
        compositionRoot = composition
        lifecycle.start()

        Task { [weak menuModel, weak lifecycle] in
            await lifecycle?.waitForLaunch()
            let status = await permissions.currentStatus()
            guard !status.isGranted else { return }
            await MainActor.run { menuModel?.permissionMessage = status.userMessage }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let lifecycle else { return .terminateNow }
        switch lifecycle.prepareForTermination(reply: {
            sender.reply(toApplicationShouldTerminate: true)
        }) {
        case .terminateNow:
            return .terminateNow
        case .terminateLater:
            return .terminateLater
        }
    }

    private func showSettings() {
        guard menuModel?.isRecovering == false, let settingsModel else { return }
        menuBarController.showSettings(model: settingsModel)
    }

    private func openToday() {
        guard let launchRecordingLocation else { return }
        NSWorkspace.shared.open(launchRecordingLocation.target(for: Date()))
    }
}
