import AppKit
import MeetingRecorderCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBarController = MenuBarController()
    private var coordinator: RecordingCoordinator?
    private var menuModel: MenuBarViewModel?
    private var settingsModel: SettingsViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsStore = AppSettingsStore()
        let settings = settingsStore.load()
        let activityGate = RecordingActivityGate()
        let recordingStore = RecordingStore(root: settings.recordingRoot)
        let session = LiveRecordingSessionManager(activityGate: activityGate, store: recordingStore)
        let coordinator = RecordingCoordinator(session: session)
        let hotkey = HotkeyService()
        let loginItem = LoginItemService()

        let settingsModel = SettingsViewModel(
            initialSettings: settings,
            persistence: settingsStore,
            hotkey: hotkey,
            loginItem: loginItem,
            hotkeyAction: { Task { @MainActor in await coordinator.toggleRecording() } }
        )
        let menuModel = MenuBarViewModel(
            coordinator: coordinator,
            recordingRoot: settings.recordingRoot,
            onOpenToday: { [weak self] in self?.openToday() },
            onShowSettings: { [weak self] in self?.showSettings() }
        )

        self.coordinator = coordinator
        self.settingsModel = settingsModel
        self.menuModel = menuModel
        menuBarController.show(rootView: MenuBarView(model: menuModel))
        menuBarController.bind(to: menuModel)

        Task { [weak menuModel] in
            let status = await PermissionService().currentStatus()
            guard !status.isGranted else { return }
            await MainActor.run { menuModel?.permissionMessage = status.userMessage }
        }
    }

    private func showSettings() {
        guard let settingsModel else { return }
        menuBarController.showSettings(model: settingsModel)
    }

    private func openToday() {
        guard let root = settingsModel?.settings.recordingRoot else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let today = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        if FileManager.default.fileExists(atPath: today.path) {
            NSWorkspace.shared.open(today)
        } else {
            NSWorkspace.shared.open(root)
        }
    }
}
