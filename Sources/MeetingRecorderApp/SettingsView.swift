import AppKit
import Combine
import MeetingRecorderCore
import SwiftUI

@MainActor
protocol SettingsPersisting: AnyObject {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

extension AppSettingsStore: SettingsPersisting {}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published var errorMessage: String?

    private let persistence: any SettingsPersisting
    private let hotkey: any HotkeyRegistering
    private let loginItem: any LoginItemManaging
    private let hotkeyAction: @Sendable () -> Void

    init(
        initialSettings: AppSettings,
        persistence: any SettingsPersisting,
        hotkey: any HotkeyRegistering,
        loginItem: any LoginItemManaging,
        hotkeyAction: @escaping @Sendable () -> Void = {}
    ) {
        settings = initialSettings
        self.persistence = persistence
        self.hotkey = hotkey
        self.loginItem = loginItem
        self.hotkeyAction = hotkeyAction
    }

    func setRecordingRoot(_ root: URL) {
        errorMessage = nil
        settings.recordingRoot = root
        persistence.save(settings)
    }

    func applyHotkey(_ descriptor: HotkeyDescriptor) {
        guard descriptor != settings.hotkey else { return }
        let previous = settings.hotkey
        errorMessage = nil
        hotkey.unregister()
        do {
            try hotkey.register(descriptor, handler: hotkeyAction)
            settings.hotkey = descriptor
            persistence.save(settings)
        } catch {
            do {
                try hotkey.register(previous, handler: hotkeyAction)
            } catch {
                errorMessage = "新快捷键无法使用，旧快捷键也未能恢复：\(error.localizedDescription)"
                settings.hotkey = previous
                persistence.save(settings)
                return
            }
            settings.hotkey = previous
            persistence.save(settings)
            errorMessage = "这个快捷键无法使用，已恢复为 \(previous.displayText)。"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != settings.launchAtLogin else { return }
        let previous = settings.launchAtLogin
        errorMessage = nil
        do {
            try loginItem.setEnabled(enabled)
            settings.launchAtLogin = enabled
            persistence.save(settings)
        } catch {
            settings.launchAtLogin = previous
            persistence.save(settings)
            errorMessage = error.localizedDescription
        }
    }

    static var preview: SettingsViewModel {
        let persistence = PreviewSettingsPersistence()
        return SettingsViewModel(
            initialSettings: persistence.load(),
            persistence: persistence,
            hotkey: PreviewHotkeyService(),
            loginItem: PreviewLoginItemService()
        )
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("设置")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(AppColors.ink)
                Text("只保存在这台 Mac 上")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.ink3)
            }

            settingSection(title: "保存位置") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.settings.recordingRoot.path)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.ink2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("当前保存位置：\(model.settings.recordingRoot.path)")
                    Button("选择文件夹…", action: chooseFolder)
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityLabel("选择录音保存文件夹")
                    Text("修改后将在下次启动时生效。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.ink3)
                }
            }

            settingSection(title: "快捷键") {
                VStack(alignment: .leading, spacing: 6) {
                    ShortcutRecorderView(
                        displayText: model.settings.hotkey.displayText,
                        onCapture: model.applyHotkey,
                        onError: { model.errorMessage = $0 }
                    )
                    Text("点击后按新组合键。必须包含 Control 或 Command；按 Esc 取消。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            settingSection(title: "启动") {
                Button {
                    model.setLaunchAtLogin(!model.settings.launchAtLogin)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.settings.launchAtLogin ? "checkmark.square.fill" : "square")
                            .foregroundStyle(model.settings.launchAtLogin ? AppColors.ink : AppColors.ink3)
                        Text("登录 Mac 时自动启动")
                            .font(.system(size: 13))
                            .foregroundStyle(AppColors.ink)
                    }
                }
                .buttonStyle(.plain)
                .focusable(true)
                .accessibilityLabel("登录 Mac 时自动启动会议录音")
                .accessibilityValue(model.settings.launchAtLogin ? "已开启" : "已关闭")
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.warning)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.warningSurface)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppColors.warningBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("设置错误：\(errorMessage)")
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(
            minWidth: 420,
            idealWidth: 480,
            maxWidth: 480,
            minHeight: 370,
            alignment: .topLeading
        )
        .background(AppColors.page)
    }

    private func settingSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.ink3)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppColors.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择录音保存位置"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.settings.recordingRoot
        if panel.runModal() == .OK, let url = panel.url {
            model.setRecordingRoot(url)
        }
    }
}

enum AppColors {
    static let page = Color(red: 234 / 255, green: 236 / 255, blue: 241 / 255)
    static let surface = Color.white
    static let subtleSurface = Color(red: 247 / 255, green: 248 / 255, blue: 250 / 255)
    static let ink = Color(red: 23 / 255, green: 27 / 255, blue: 35 / 255)
    static let ink2 = Color(red: 53 / 255, green: 60 / 255, blue: 72 / 255)
    static let ink3 = Color(red: 79 / 255, green: 88 / 255, blue: 102 / 255)
    static let line = Color(red: 215 / 255, green: 219 / 255, blue: 227 / 255)
    static let recording = Color(red: 168 / 255, green: 68 / 255, blue: 60 / 255)
    static let warning = Color(red: 141 / 255, green: 107 / 255, blue: 63 / 255)
    static let success = Color(red: 91 / 255, green: 143 / 255, blue: 114 / 255)
    static let warningSurface = Color(red: 248 / 255, green: 243 / 255, blue: 234 / 255)
    static let warningBorder = Color(red: 227 / 255, green: 215 / 255, blue: 196 / 255)
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AppColors.ink)
            .frame(height: 30)
            .padding(.horizontal, 12)
            .background(configuration.isPressed ? AppColors.line : AppColors.surface)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(AppColors.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

@MainActor
private final class PreviewSettingsPersistence: SettingsPersisting {
    private var settings = AppSettings.default
    func load() -> AppSettings { settings }
    func save(_ settings: AppSettings) { self.settings = settings }
}

@MainActor
private final class PreviewHotkeyService: HotkeyRegistering {
    func register(_ descriptor: HotkeyDescriptor, handler: @escaping @Sendable () -> Void) throws {}
    func unregister() {}
}

@MainActor
private final class PreviewLoginItemService: LoginItemManaging {
    var isEnabled = true
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}
