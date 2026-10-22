import Charts
import SleepEngineCore
import SwiftUI

/// Tab "Statistik": 7/30-day trends.
struct StatsView: View {
    @Environment(SessionStore.self) private var store
    @State private var days = 7

    private struct Night: Identifiable {
        var id: String
        var day: Date
        var quality: Double
        var asleepHours: Double
        var snoreMinutes: Double
        /// Hours after 18:00 the day before (bedtime 23:30 → 5.5, wake 06:45 → 12.75).
        var bedHour: Double
        var wakeHour: Double
        var tags: [String]
    }

    private struct TagImpact {
        var tag: String
        var with: Int
        var without: Int
    }

    private var nights: [Night] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return store.finishedSessions.compactMap { meta -> Night? in
            guard let s = meta.summary, meta.startDate >= cutoff, let end = meta.endDate else { return nil }
            let wake = meta.wakeDate ?? end
            return Night(id: meta.id, day: Calendar.current.startOfDay(for: wake), quality: Double(s.quality),
                         asleepHours: s.asleep / 3600, snoreMinutes: s.snoreSeconds / 60,
                         bedHour: Self.hoursAfterSix(meta.startDate), wakeHour: Self.hoursAfterSix(wake), tags: meta.tags)
        }
        .sorted { $0.day < $1.day }
    }

    private static func hoursAfterSix(_ date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let h = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        return h >= 18 ? h - 18 : h + 6
    }

    private static func clock(_ hoursAfterSix: Double) -> String {
        let total = Int(((hoursAfterSix + 18) * 60).rounded()) % (24 * 60)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var body: some View {
        let nights = self.nights
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Zeitraum", selection: $days) {
                        Text("7 Tage").tag(7)
                        Text("30 Tage").tag(30)
                    }
                    .pickerStyle(.segmented)

                    if nights.isEmpty {
                        ContentUnavailableView("Noch keine Daten", systemImage: "chart.bar",
                                               description: Text("Nach der ersten Nacht erscheinen hier deine Trends."))
                    } else {
                        averages(nights)
                        Card(title: "Schlafqualität (%)") { barChart(nights, value: \.quality, unit: "%", tint: Theme.accent) }
                        Card(title: "Geschlafen (h)") { barChart(nights, value: \.asleepHours, unit: "h", tint: Theme.color(.deep)) }
                        Card(title: "Schnarchen (min)") {
                            barChart(nights, value: \.snoreMinutes, unit: "min", tint: Theme.color(SoundGroup.snore))
                        }
                        Card(title: "Zubettgehen und Aufwachen") { rhythmChart(nights) }
                        notesImpact(nights)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Statistik")
        }
    }

    private func averages(_ nights: [Night]) -> some View {
        let n = Double(nights.count)
        let quality = nights.map(\.quality).reduce(0, +) / n
        let asleep = nights.map(\.asleepHours).reduce(0, +) / n
        let snore = nights.map(\.snoreMinutes).reduce(0, +) / n
        return Card(title: "Durchschnitt (\(nights.count) Nächte)") {
            HStack {
                StatTile(title: "Qualität", value: "\(Int(quality.rounded())) %")
                StatTile(title: "Geschlafen", value: Fmt.duration(asleep * 3600))
                StatTile(title: "Schnarchen", value: "\(Int(snore.rounded())) min")
            }
        }
    }

    private func barChart(_ nights: [Night], value: KeyPath<Night, Double>, unit: String, tint: Color) -> some View {
        Chart(nights) { night in
            BarMark(x: .value("Tag", night.day, unit: .day), y: .value(unit, night[keyPath: value]))
                .foregroundStyle(tint)
                .cornerRadius(4)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: days > 7 ? 7 : 1)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.defaultDigits))
            }
        }
        .frame(height: 140)
    }

    private func rhythmChart(_ nights: [Night]) -> some View {
        let bedSpread = Self.standardDeviation(nights.map(\.bedHour))
        let wakeSpread = Self.standardDeviation(nights.map(\.wakeHour))
        return VStack(alignment: .leading, spacing: 8) {
            Chart(nights) { night in
                RuleMark(x: .value("Tag", night.day, unit: .day),
                         yStart: .value("Bett", night.bedHour), yEnd: .value("Auf", night.wakeHour))
                    .foregroundStyle(Theme.accent.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 6, lineCap: .round))
                PointMark(x: .value("Tag", night.day, unit: .day), y: .value("Bett", night.bedHour))
                    .foregroundStyle(Theme.color(.deep))
                PointMark(x: .value("Tag", night.day, unit: .day), y: .value("Auf", night.wakeHour))
                    .foregroundStyle(Theme.color(.wake))
            }
            .chartYScale(domain: .automatic(includesZero: false, reversed: true))
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(Self.clock(value.as(Double.self) ?? 0)) }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: days > 7 ? 7 : 1)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.defaultDigits))
                }
            }
            .frame(height: 180)
            Text("Regelmäßigkeit: Zubettgehen ± \(Int((bedSpread * 60).rounded())) min · Aufwachen ± \(Int((wakeSpread * 60).rounded())) min")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    /// Average quality with vs. without each note, only when both sides have ≥ 3 nights.
    @ViewBuilder
    private func notesImpact(_ nights: [Night]) -> some View {
        let tags = Set(nights.flatMap(\.tags)).sorted()
        let rows: [TagImpact] = tags.compactMap { tag in
            let with = nights.filter { $0.tags.contains(tag) }.map(\.quality)
            let without = nights.filter { !$0.tags.contains(tag) }.map(\.quality)
            guard with.count >= 3, without.count >= 3 else { return nil }
            return TagImpact(tag: tag, with: Int((with.reduce(0, +) / Double(with.count)).rounded()),
                             without: Int((without.reduce(0, +) / Double(without.count)).rounded()))
        }
        Card(title: "Einfluss deiner Notizen") {
            if rows.isEmpty {
                Text("Erscheint, sobald eine Notiz an mindestens 3 Nächten gesetzt ist und an 3 Nächten nicht.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(rows, id: \.tag) { row in
                    HStack {
                        Text(row.tag)
                        Spacer()
                        Text("mit \(row.with) % · ohne \(row.without) %")
                            .monospacedDigit()
                            .foregroundStyle(row.with < row.without ? Color.orange : Color.green)
                    }
                    .font(.subheadline)
                }
            }
        }
    }
}
