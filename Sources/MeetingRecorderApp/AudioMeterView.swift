import SwiftUI

struct AudioMeterView: View {
    let systemLevel: Float
    let microphoneLevel: Float
    let microphoneHasWarning: Bool

    var body: some View {
        VStack(spacing: 9) {
            meterRow(label: "系统声音", level: systemLevel, color: AppColors.success)
            meterRow(
                label: "麦克风",
                level: microphoneLevel,
                color: microphoneHasWarning ? AppColors.warning : AppColors.success
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "系统声音音量 \(percent(systemLevel))，麦克风音量 \(percent(microphoneLevel))"
        )
    }

    private func meterRow(label: String, level: Float, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(AppColors.ink3)
                .frame(width: 52, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppColors.line)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(clamped(level)))
                }
            }
            .frame(height: 5)
        }
    }

    private func clamped(_ level: Float) -> Float {
        guard level.isFinite else { return 0 }
        return min(max(level, 0), 1)
    }

    private func percent(_ level: Float) -> String {
        "\(Int(clamped(level) * 100))%"
    }
}
