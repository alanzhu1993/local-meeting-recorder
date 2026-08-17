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
private final class RecordingActionReference {
    weak var action: PermissionGatedRecordingAction?
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBarController = MenuBarController()
    private var coordinator: RecordingCoordinator?
    private var menuModel: MenuBarViewModel?
    private var settingsModel: SettingsViewModel?
    private var recordingAction: PermissionGatedRecordingAction?
    private var launchRecordingLocation: LaunchRecordingLocation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsStore = AppSettingsStore()
        let settings = settingsStore.load()
        let permissions = PermissionService()
        let activityGate = RecordingActivityGate()
        let recordingStore = RecordingStore(root: settings.recordingRoot)
        let session = LiveRecordingSessionManager(
            activityGate: activityGate,
            store: recordingStore,
            permissions: permissions
        )
        let coordinator = RecordingCoordinator(session: session)
        let hotkey = HotkeyService()
        let loginItem = LoginItemService()

        let recordingActionReference = RecordingActionReference()
        let settingsModel = SettingsViewModel(
            initialSettings: settings,
            persistence: settingsStore,
            hotkey: hotkey,
            hotkeyTeardownError: { hotkey.lastTeardownError },
            loginItem: loginItem,
            hotkeyAction: {
                Task { @MainActor in await recordingActionReference.action?.perform() }
            }
        )

        weak var weakMenuModel: MenuBarViewModel?
        let recordingAction = PermissionGatedRecordingAction(
            permissions: permissions,
            phase: { coordinator.phase },
            toggle: { await coordinator.toggleRecording() },
            updatePermissionMessage: { message in weakMenuModel?.permissionMessage = message }
        )
        recordingActionReference.action = recordingAction
        let menuModel = MenuBarViewModel(
            coordinator: coordinator,
            recordingRoot: settings.recordingRoot,
            onPrimaryAction: { Task { @MainActor in await recordingAction.perform() } },
            onOpenToday: { [weak self] in self?.openToday() },
            onShowSettings: { [weak self] in self?.showSettings() }
        )
        weakMenuModel = menuModel

        self.coordinator = coordinator
        self.settingsModel = settingsModel
        self.menuModel = menuModel
        self.recordingAction = recordingAction
        launchRecordingLocation = LaunchRecordingLocation(root: settings.recordingRoot)
        menuBarController.show(rootView: MenuBarView(model: menuModel))
        menuBarController.bind(to: menuModel)

        Task { [weak menuModel] in
            let status = await permissions.currentStatus()
            guard !status.isGranted else { return }
            await MainActor.run { menuModel?.permissionMessage = status.userMessage }
        }
    }

    private func showSettings() {
        guard let settingsModel else { return }
        menuBarController.showSettings(model: settingsModel)
    }

    private func openToday() {
        guard let launchRecordingLocation else { return }
        NSWorkspace.shared.open(launchRecordingLocation.target(for: Date()))
    }
}
