import AppKit
import Combine
import MeetingRecorderCore
import SwiftUI

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published private(set) var presentation: MenuBarPresentation
    @Published private(set) var audioLevels: AudioLevels
    @Published var isRecovering: Bool {
        didSet { refreshPreferredHeight() }
    }
    @Published var recoveryMessage: String?
    @Published var permissionMessage: String? {
        didSet { refreshPreferredHeight() }
    }
    @Published private(set) var preferredHeight: CGFloat

    @Published private(set) var recordingRoot: URL
    private let coordinator: RecordingCoordinator?
    private let now: () -> Date
    private let onPrimaryAction: () -> Void
    private let onOpenToday: () -> Void
    private let onShowSettings: () -> Void
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    fileprivate var phase: RecordingPhase

    init(
        coordinator: RecordingCoordinator,
        recordingRoot: URL,
        now: @escaping () -> Date = Date.init,
        onPrimaryAction: @escaping () -> Void,
        onOpenToday: @escaping () -> Void,
        onShowSettings: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.recordingRoot = recordingRoot
        self.now = now
        phase = coordinator.phase
        let initialPresentation = MenuBarPresentation(
            phase: coordinator.phase,
            elapsed: Self.elapsed(for: coordinator.phase, now: now())
        )
        presentation = initialPresentation
        audioLevels = coordinator.audioLevels
        isRecovering = false
        recoveryMessage = nil
        permissionMessage = nil
        preferredHeight = Self.preferredHeight(
            phase: coordinator.phase,
            isRecovering: false,
            permissionMessage: nil,
            warningText: initialPresentation.warningText
        )
        self.onPrimaryAction = onPrimaryAction
        self.onOpenToday = onOpenToday
        self.onShowSettings = onShowSettings

        coordinator.$phase
            .sink { [weak self] phase in self?.update(phase: phase) }
            .store(in: &subscriptions)
        coordinator.$audioLevels
            .sink { [weak self] levels in self?.audioLevels = levels }
            .store(in: &subscriptions)
    }

    private init(
        phase: RecordingPhase,
        elapsed: TimeInterval,
        audioLevels: AudioLevels,
        recordingRoot: URL,
        isRecovering: Bool,
        recoveryMessage: String?,
        permissionMessage: String?
    ) {
        coordinator = nil
        self.recordingRoot = recordingRoot
        now = Date.init
        self.phase = phase
        let initialPresentation = MenuBarPresentation(phase: phase, elapsed: elapsed)
        presentation = initialPresentation
        self.audioLevels = audioLevels
        self.isRecovering = isRecovering
        self.recoveryMessage = recoveryMessage
        self.permissionMessage = permissionMessage
        preferredHeight = Self.preferredHeight(
            phase: phase,
            isRecovering: isRecovering,
            permissionMessage: permissionMessage,
            warningText: initialPresentation.warningText
        )
        onPrimaryAction = {}
        onOpenToday = {}
        onShowSettings = {}
    }

    isolated deinit { timer?.invalidate() }

    func performPrimaryAction() {
        guard !isRecovering, presentation.isPrimaryActionEnabled else { return }
        onPrimaryAction()
    }

    func openToday() { onOpenToday() }
    func showSettings() { onShowSettings() }

    func setRecovery(isRecovering: Bool, message: String? = nil) {
        self.isRecovering = isRecovering
        recoveryMessage = message
    }

    func setRecordingRoot(_ root: URL) {
        recordingRoot = root
    }

    var showsAudioMeter: Bool {
        if case .recording = phase { return true }
        return false
    }

    private func update(phase: RecordingPhase) {
        self.phase = phase
        presentation = MenuBarPresentation(
            phase: phase,
            elapsed: Self.elapsed(for: phase, now: now())
        )
        refreshPreferredHeight()
        updateTimer(for: phase)
    }

    private func refreshPreferredHeight() {
        preferredHeight = Self.preferredHeight(
            phase: phase,
            isRecovering: isRecovering,
            permissionMessage: permissionMessage,
            warningText: presentation.warningText
        )
    }

    private static func preferredHeight(
        phase: RecordingPhase,
        isRecovering: Bool,
        permissionMessage: String?,
        warningText: String?
    ) -> CGFloat {
        if isRecovering || permissionMessage != nil || warningText != nil {
            return 470
        }
        switch phase {
        case .idle: return 370
        case .preparing: return 340
        case .recording: return 430
        case .stopping: return 370
        case .failed: return 430
        }
    }

    private func updateTimer(for phase: RecordingPhase) {
        timer?.invalidate()
        timer = nil
        switch phase {
        case .recording, .stopping:
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.presentation = MenuBarPresentation(
                        phase: self.phase,
                        elapsed: Self.elapsed(for: self.phase, now: self.now())
                    )
                }
            }
        case .idle, .preparing, .failed:
            break
        }
    }

    private static func elapsed(for phase: RecordingPhase, now: Date) -> TimeInterval {
        switch phase {
        case let .recording(active, _), let .stopping(active):
            max(0, now.timeIntervalSince(active.startedAt))
        case .idle, .preparing, .failed:
            0
        }
    }

    static func preview(
        phase: RecordingPhase = .idle,
        elapsed: TimeInterval = 0,
        audioLevels: AudioLevels = .silent,
        recordingRoot: URL = URL(fileURLWithPath: "/Users/alan/Documents/快速本地录音软件/录音文件/一个很长的目录名称用于检查中文路径是否能够自然换行", isDirectory: true),
        isRecovering: Bool = false,
        recoveryMessage: String? = nil,
        permissionMessage: String? = nil
    ) -> MenuBarViewModel {
        MenuBarViewModel(
            phase: phase,
            elapsed: elapsed,
            audioLevels: audioLevels,
            recordingRoot: recordingRoot,
            isRecovering: isRecovering,
            recoveryMessage: recoveryMessage,
            permissionMessage: permissionMessage
        )
    }
}

struct MenuBarView: View {
    @ObservedObject var model: MenuBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            statusSummary
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            ScrollView {
                secondaryContent
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .frame(width: 292, height: model.preferredHeight)
        .background(AppColors.page)
    }

    private var secondaryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isRecovering {
                notice(
                    title: "正在恢复录音",
                    detail: model.recoveryMessage ?? "正在检查上次中断的录音，请稍候。"
                )
            }

            if let warning = model.presentation.warningText {
                notice(title: "麦克风提醒", detail: warning)
            }

            if let error = model.presentation.errorText {
                notice(title: model.presentation.statusText, detail: error)
            }

            if let permission = model.permissionMessage,
               model.presentation.errorText == nil {
                notice(title: "录音权限", detail: permission)
            }

            if model.permissionMessage != nil {
                Text("请只录制你有权录制的会议。")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.showsAudioMeter {
                AudioMeterView(
                    systemLevel: model.audioLevels.system,
                    microphoneLevel: model.audioLevels.microphone,
                    microphoneHasWarning: model.presentation.warningText != nil
                )
            }

            Button(action: model.performPrimaryAction) {
                Text(model.isRecovering ? "正在恢复…" : model.presentation.primaryActionTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryRecordingButtonStyle(isRecording: isRecording))
            .disabled(model.isRecovering || !model.presentation.isPrimaryActionEnabled)
            .accessibilityLabel(model.isRecovering ? "正在恢复录音，暂时不能开始" : model.presentation.primaryActionTitle)

            VStack(spacing: 0) {
                utilityButton("打开今天的录音", systemImage: "folder", action: model.openToday)
                Divider().overlay(AppColors.line)
                utilityButton("设置", systemImage: "gearshape", action: model.showSettings)
            }
            .background(AppColors.surface)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppColors.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if model.presentation.errorText == nil, model.permissionMessage == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("保存到")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.ink3)
                    Text(model.recordingRoot.path)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("录音保存到 \(model.recordingRoot.path)")
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 15, weight: .medium))
            Text("会议录音")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Text("本地")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.ink3)
        }
        .foregroundStyle(AppColors.ink)
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(AppColors.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(AppColors.line).frame(height: 1) }
    }

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(model.isRecovering ? "正在恢复录音" : model.presentation.statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColors.ink)
            }
            Text(model.presentation.timerText)
                .font(.system(size: 26, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(AppColors.ink)
                .accessibilityLabel("计时 \(model.presentation.timerText)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.presentation.accessibilityLabel)
    }

    private func notice(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.warningText)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(AppColors.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.warningSurface)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppColors.warningBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func utilityButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage).frame(width: 16)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppColors.ink3)
            }
            .font(.system(size: 13))
            .foregroundStyle(AppColors.ink2)
            .padding(.horizontal, 11)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(true)
        .accessibilityLabel(title)
    }

    private var isRecording: Bool {
        if case .recording = model.presentationState { return true }
        return false
    }

    private var statusColor: Color {
        if model.isRecovering { return AppColors.warning }
        switch model.presentation.tone {
        case .idle: return AppColors.success
        case .busy: return AppColors.ink3
        case .recording: return AppColors.recording
        case .warning: return AppColors.warning
        }
    }
}

private extension MenuBarViewModel {
    var presentationState: RecordingPhase { phase }
}

private struct PrimaryRecordingButtonStyle: ButtonStyle {
    let isRecording: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? Color.white : AppColors.ink3)
            .frame(height: 32)
            .background(background(configuration: configuration))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isEnabled ? Color.clear : AppColors.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func background(configuration: Configuration) -> Color {
        guard isEnabled else { return AppColors.subtleSurface }
        let active = isRecording ? AppColors.recording : AppColors.ink
        return configuration.isPressed ? active.opacity(0.82) : active
    }
}
