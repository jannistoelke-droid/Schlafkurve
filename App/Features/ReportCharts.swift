import Charts
import SleepEngineCore
import SwiftUI

/// Sleep-depth curve over stage bands, gaps greyed out, scrubber via chartXSelection.
struct SleepDepthChart: View {
    var model: ReportModel
    @Binding var selection: Date?

    var body: some View {
        Chart {
            ForEach(model.stageRuns) { run in
                RectangleMark(xStart: .value("Start", run.start), xEnd: .value("Ende", run.end),
                              yStart: .value("Unten", 0.0), yEnd: .value("Oben", 1.0))
                    .foregroundStyle(Theme.color(run.stage).opacity(0.18))
            }
            ForEach(model.gaps) { gap in
                RectangleMark(xStart: .value("Start", gap.start), xEnd: .value("Ende", gap.end),
                              yStart: .value("Unten", 0.0), yEnd: .value("Oben", 1.0))
                    .foregroundStyle(Color.gray.opacity(0.35))
                    .accessibilityLabel("Datenlücke")
            }
            ForEach(model.wakefulness) { p in
                AreaMark(x: .value("Zeit", p.time), y: .value("Wachheit", p.value),
                         series: .value("Abschnitt", p.segment), stacking: .unstacked)
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Theme.color(.wake).opacity(0.35), Theme.color(.deep).opacity(0.05)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            ForEach(model.wakefulness) { p in
                LineMark(x: .value("Zeit", p.time), y: .value("Wachheit", p.value),
                         series: .value("Abschnitt", p.segment))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            if let selection {
                RuleMark(x: .value("Auswahl", selection))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .chartXScale(domain: model.start...model.end)
        .chartYScale(domain: 0.0...1.0)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.05, 0.5, 0.95]) { value in
                AxisGridLine()
                AxisValueLabel {
                    Text(Self.label(value.as(Double.self) ?? 0))
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartXSelection(value: $selection)
        .frame(height: 220)
        .accessibilityLabel("Schlafkurve")
        .accessibilityValue(accessibilitySummary)
    }

    private static func label(_ y: Double) -> String {
        if y > 0.8 { return "Wach" }
        if y < 0.2 { return "Tief" }
        return "Leicht"
    }

    /// Dominant stage per hour, read out by VoiceOver.
    private var accessibilitySummary: String {
        var parts: [String] = []
        var hourStart = model.start
        while hourStart < model.end {
            let hourEnd = hourStart.addingTimeInterval(3600)
            var counts: [SleepStage: Int] = [:]
            var t = hourStart
            while t < min(hourEnd, model.end) {
                if let s = model.stage(at: t) { counts[s, default: 0] += 1 }
                t = t.addingTimeInterval(ReportModel.epoch)
            }
            if let top = counts.max(by: { $0.value < $1.value })?.key {
                parts.append("\(Fmt.time(hourStart)) \(top.title)")
            } else {
                parts.append("\(Fmt.time(hourStart)) Datenlücke")
            }
            hourStart = hourEnd
        }
        return parts.joined(separator: ", ")
    }
}

/// Event lane below the main chart: snore bars and points for the other events. Tap plays the nearest clip.
struct EventLaneChart: View {
    var model: ReportModel
    var events: [SoundEvent]
    var onTap: (SoundEvent) -> Void

    private var snores: [SoundEvent] { events.filter { $0.group == .snore } }
    private var others: [SoundEvent] { events.filter { $0.group != .snore } }

    var body: some View {
        Chart {
            ForEach(snores) { e in
                RectangleMark(xStart: .value("Start", model.date(e.start)), xEnd: .value("Ende", model.date(max(e.end, e.start + 20))),
                              yStart: .value("Unten", 0.3), yEnd: .value("Oben", 0.7))
                    .foregroundStyle(Theme.color(SoundGroup.snore))
                    .accessibilityLabel("\(SoundGroup.snore.title) \(Fmt.time(model.date(e.start)))")
            }
            ForEach(others) { e in
                PointMark(x: .value("Zeit", model.date((e.start + e.end) / 2)), y: .value("Spur", 0.5))
                    .foregroundStyle(Theme.color(e.group))
                    .symbolSize(Self.symbolSize(e.peakDb))
                    .accessibilityLabel("\(e.group.title) \(Fmt.time(model.date(e.start)))")
            }
        }
        .chartXScale(domain: model.start...model.end)
        .chartYScale(domain: 0.0...1.0)
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame else { return }
                        let x = location.x - geo[frame].origin.x
                        guard let time = proxy.value(atX: x, as: Date.self) else { return }
                        if let event = nearest(to: time) { onTap(event) }
                    }
            }
        }
        .frame(height: 44)
    }

    private static func symbolSize(_ peakDb: Float) -> CGFloat {
        CGFloat(min(max((peakDb + 60) * 3, 30), 160))
    }

    /// Nearest event with a clip within 2 minutes.
    private func nearest(to time: Date) -> SoundEvent? {
        let t = time.timeIntervalSince(model.start)
        return events
            .filter { $0.clipFile != nil }
            .map { e -> (SoundEvent, Double) in
                let d = t < e.start ? e.start - t : (t > e.end ? t - e.end : 0)
                return (e, d)
            }
            .filter { $0.1 <= 120 }
            .min { $0.1 < $1.1 }?.0
    }
}

/// Snoring minutes per 15 minutes.
struct SnoreBucketChart: View {
    var buckets: [ReportModel.Bucket]
    var model: ReportModel

    var body: some View {
        Chart(buckets) { b in
            RectangleMark(xStart: .value("Start", b.start), xEnd: .value("Ende", b.end.addingTimeInterval(-60)),
                          yStart: .value("Null", 0.0), yEnd: .value("Minuten", b.minutes))
                .foregroundStyle(Theme.color(SoundGroup.snore))
        }
        .chartXScale(domain: model.start...model.end)
        .chartYScale(domain: 0.0...15.0)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 5.0, 10.0, 15.0]) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .frame(height: 110)
        .accessibilityLabel("Schnarchminuten pro Viertelstunde")
    }
}

/// Simple line over the night, interrupted at gaps (noise level, breathing rate).
struct NightLineChart: View {
    var points: [ReportModel.Point]
    var model: ReportModel
    var unit: String
    var tint: Color

    var body: some View {
        Chart(points) { p in
            LineMark(x: .value("Zeit", p.time), y: .value(unit, p.value), series: .value("Abschnitt", p.segment))
                .interpolationMethod(.monotone)
                .foregroundStyle(tint)
        }
        .chartXScale(domain: model.start...model.end)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .frame(height: 100)
    }
}
