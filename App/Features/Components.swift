import SleepEngineCore
import SwiftUI

extension SleepStage {
    var symbol: String {
        switch self {
        case .wake: return "sun.max"
        case .rem: return "sparkles"
        case .light: return "cloud"
        case .deep: return "moon.zzz"
        }
    }
}

extension Font {
    static func bigNumber(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .rounded).weight(.semibold).monospacedDigit()
    }
}

/// Small labelled value used in report and stats cards.
struct StatTile: View {
    var title: String
    var value: String
    var symbol: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
                Text(title)
            }
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
            Text(value).font(.bigNumber(.title3))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Rounded selectable chip (window minutes, note tags).
struct Chip: View {
    var title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? Theme.accent.opacity(0.85) : Theme.elevated,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(selected ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 64-bar mini waveform of a clip; bars before `progress` are highlighted.
struct WaveformView: View {
    var samples: [Float]
    var progress: Double = 0
    var tint: Color

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let peak = max(samples.max() ?? 1, 0.0001)
            let step = size.width / CGFloat(samples.count)
            let barWidth = max(step * 0.6, 1)
            for (i, s) in samples.enumerated() {
                let h = max(CGFloat(s / peak) * size.height, 2)
                let rect = CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: barWidth, height: h)
                let played = Double(i) / Double(samples.count) < progress
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(played ? tint : tint.opacity(0.4)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Quality ring 0–100 %.
struct QualityRing: View {
    var quality: Int

    var body: some View {
        ZStack {
            Circle().stroke(Theme.elevated, lineWidth: 10)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(quality, 0), 100)) / 100)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(quality)").font(.bigNumber(.title))
                Text("%").font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(width: 96, height: 96)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Schlafqualität \(quality) Prozent")
    }
}

/// Horizontal stacked bar of stage shares.
struct StageShareBar: View {
    var summary: SleepSummary

    private static let order: [SleepStage] = [.wake, .rem, .light, .deep]

    private func seconds(_ stage: SleepStage) -> Double {
        switch stage {
        case .wake: return summary.wakeSeconds
        case .rem: return summary.remSeconds
        case .light: return summary.lightSeconds
        case .deep: return summary.deepSeconds
        }
    }

    var body: some View {
        let total = max(summary.analysedSeconds, 1)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Self.order, id: \.self) { stage in
                        if seconds(stage) > 0 {
                            Rectangle()
                                .fill(Theme.color(stage))
                                .frame(width: max(geo.size.width * CGFloat(seconds(stage) / total) - 2, 2))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(height: 14)
            .accessibilityHidden(true)
            ForEach(Self.order, id: \.self) { stage in
                HStack {
                    Image(systemName: stage.symbol).foregroundStyle(Theme.color(stage)).frame(width: 22)
                    Text(stage == .rem ? "\(stage.title) (experimentell)" : stage.title)
                    Spacer()
                    Text("\(Fmt.duration(seconds(stage))) · \(Int((seconds(stage) / total * 100).rounded())) %")
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Small bordered banner for hints and errors.
struct HintBanner: View {
    var text: String
    var symbol = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
