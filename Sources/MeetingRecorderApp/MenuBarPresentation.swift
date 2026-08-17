import Foundation
import MeetingRecorderCore

struct MenuBarPresentation: Equatable {
    enum Tone: Equatable {
        case idle
        case busy
        case recording
        case warning
    }

    let statusText: String
    let timerText: String
    let menuBarTitle: String
    let tone: Tone
    let primaryActionTitle: String
    let isPrimaryActionEnabled: Bool
    let warningText: String?
    let errorText: String?
    let accessibilityLabel: String
    let symbolName: String

    init(phase: RecordingPhase, elapsed: TimeInterval) {
        let timerText = Self.formatElapsed(elapsed)
        self.timerText = timerText

        switch phase {
        case .idle:
            statusText = "待机"
            menuBarTitle = ""
            tone = .idle
            primaryActionTitle = "开始录音"
            isPrimaryActionEnabled = true
            warningText = nil
            errorText = nil
            accessibilityLabel = "会议录音，待机"
            symbolName = "waveform.and.mic"
        case .preparing:
            statusText = "正在准备录音"
            menuBarTitle = ""
            tone = .busy
            primaryActionTitle = "正在准备…"
            isPrimaryActionEnabled = false
            warningText = nil
            errorText = nil
            accessibilityLabel = "会议录音，正在准备录音"
            symbolName = "waveform.and.mic"
        case let .recording(_, warning):
            statusText = "正在录音"
            menuBarTitle = timerText
            tone = warning == nil ? .recording : .warning
            primaryActionTitle = "停止并保存"
            isPrimaryActionEnabled = true
            warningText = warning?.message
            errorText = nil
            if let warning {
                accessibilityLabel = "会议录音，正在录音，已录制 \(timerText)，麦克风警告：\(warning.message)"
            } else {
                accessibilityLabel = "会议录音，正在录音，已录制 \(timerText)"
            }
            symbolName = warning == nil ? "record.circle.fill" : "exclamationmark.circle"
        case .stopping:
            statusText = "正在保存录音"
            menuBarTitle = timerText
            tone = .busy
            primaryActionTitle = "正在保存…"
            isPrimaryActionEnabled = false
            warningText = nil
            errorText = nil
            accessibilityLabel = "会议录音，正在保存，已录制 \(timerText)"
            symbolName = "waveform.and.mic"
        case let .failed(failure):
            statusText = failure.code == .permission ? "无法开始录音" : "录音失败"
            menuBarTitle = ""
            tone = .warning
            primaryActionTitle = "重新尝试"
            isPrimaryActionEnabled = true
            warningText = nil
            errorText = failure.message
            accessibilityLabel = "会议录音，\(statusText)：\(failure.message)"
            symbolName = "exclamationmark.circle"
        }
    }

    static let idle = MenuBarPresentation(phase: .idle, elapsed: 0)

    private static func formatElapsed(_ elapsed: TimeInterval) -> String {
        guard elapsed.isFinite else { return "00:00:00" }
        let seconds = max(0, Int(elapsed.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }
}
