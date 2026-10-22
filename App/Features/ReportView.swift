import SleepEngineCore
import SwiftUI

/// Morning report for one night (also used as the detail screen in "Nächte").
struct ReportView: View {
    var sessionID: String
    @Environment(SessionStore.self) private var store
    @State private var detail: SessionDetail?
    @State private var loaded = false

    var body: some View {
        Group {
            if let detail {
                ReportContent(detail: detail, reload: reload)
            } else if loaded {
                ContentUnavailableView("Nacht nicht gefunden", systemImage: "moon.zzz",
                                       description: Text("Die Daten dieser Nacht fehlen."))
            } else {
                ProgressView()
            }
        }
        .background(Theme.background)
        .navigationTitle(detail.map { Fmt.day($0.meta.startDate) } ?? "Bericht")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sessionID) { reload() }
        .onDisappear { ClipPlayer.shared.stop() }
    }

    private func reload() {
        detail = store.detail(sessionID)
        loaded = true
    }
}

struct ReportContent: View {
    var detail: SessionDetail
    /// Called after edits so the parent re-reads the files.
    var reload: () -> Void
    var editable = true

    @Environment(SessionStore.self) private var store
    @Environment(ClipPlayer.self) private var player
    @State private var selection: Date?
    @State private var newTag = ""
    @State private var askTag = false

    private var meta: SessionMeta { detail.meta }
    private var summary: SleepSummary { meta.summary ?? detail.analysis?.summary ?? SleepSummary() }
    private var model: ReportModel { ReportModel(meta: meta, analysis: detail.analysis) }
    private var events: [SoundEvent] { detail.events.filter { !detail.edit(for: $0.id).isFalseDetection } }

    static let presetTags = ["Kaffee", "Alkohol", "Sport", "Stress", "Spätes Essen"]

    var body: some View {
        let model = self.model
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if detail.analysis == nil {
                        HintBanner(text: "Für diese Nacht gibt es noch keine Auswertung. Einstellungen → Alle Nächte neu analysieren.")
                    } else {
                        chartCard(model).id("chart")
                        Card(title: "Schlafphasen") { StageShareBar(summary: summary) }.id("phases")
                    }
                    snoreCard(model).id("snore")
                    countsRow
                    if summary.meanBreathRate != nil && !model.breathing.isEmpty {
                        Card(title: "Atmung (geschätzt)") {
                            Text("Ø \(String(format: "%.1f", summary.meanBreathRate ?? 0)) Atemzüge/min")
                                .font(.bigNumber(.title3))
                            NightLineChart(points: model.breathing, model: model, unit: "Atemzüge/min", tint: Theme.color(.light))
                        }
                    }
                    if !model.noise.isEmpty {
                        Card(title: "Geräuschpegel (dB über Grundrauschen)") {
                            NightLineChart(points: model.noise, model: model, unit: "dB", tint: Theme.secondaryText)
                        }
                    }
                    if !meta.gaps.isEmpty || summary.gapSeconds > 0 {
                        dataQualityCard
                    }
                    RecordingsSection(detail: detail, model: model, events: events, editable: editable, reload: reload)
                        .id("recordings")
                    if editable { moodCard.id("mood") }
                    Text("Schätzung aus Geräuschen – kein Medizinprodukt.")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.top, 8)
                }
                .padding(16)
            }
            .task {
                guard DemoData.isActive, let target = DemoData.scrollTarget else { return }
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo(target, anchor: .top)
            }
        }
        .alert("Eigene Notiz", isPresented: $askTag) {
            TextField("z. B. Spätschicht", text: $newTag)
            Button("Hinzufügen") { addTag(newTag) }
            Button("Abbrechen", role: .cancel) { newTag = "" }
        }
    }

    // MARK: header

    private var header: some View {
        Card {
            HStack(alignment: .center, spacing: 16) {
                QualityRing(quality: summary.quality)
                VStack(alignment: .leading, spacing: 6) {
                    Text(Fmt.day(meta.startDate)).font(.headline)
                    Text("Im Bett \(Fmt.time(meta.startDate)) – \(Fmt.time(meta.endDate))")
                        .font(.subheadline).foregroundStyle(Theme.secondaryText)
                    if meta.isTest { Text("Testsession").font(.caption).foregroundStyle(.orange) }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    StatTile(title: "Geschlafen", value: Fmt.duration(summary.asleep), symbol: "bed.double")
                    StatTile(title: "Eingeschlafen nach", value: Fmt.duration(summary.onset), symbol: "hourglass")
                }
                GridRow {
                    StatTile(title: "Wachphasen", value: "\(summary.awakenings)", symbol: "sun.max", tint: Theme.color(.wake))
                    StatTile(title: wakeTitle, value: wakeValue, symbol: "alarm")
                }
            }
            if let reason = meta.wakeReason, reason != .none {
                Text("Geweckt: \(reason.title)").font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var wakeTitle: String { meta.wakeDate != nil ? "Geweckt um" : "Aufgestanden" }
    private var wakeValue: String { Fmt.time(meta.wakeDate ?? meta.endDate) }

    // MARK: main chart

    private func chartCard(_ model: ReportModel) -> some View {
        Card(title: "Schlafkurve") {
            Text(scrubText(model))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(selection == nil ? Theme.secondaryText : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            SleepDepthChart(model: model, selection: $selection)
            EventLaneChart(model: model, events: events) { event in play(event) }
            legend
        }
    }

    private func scrubText(_ model: ReportModel) -> String {
        guard let t = selection else { return "Zum Ansehen über die Kurve streichen" }
        var parts = [Fmt.time(t)]
        if model.isGap(at: t) {
            parts.append("Datenlücke")
        } else if let stage = model.stage(at: t) {
            parts.append(stage.title)
        }
        let s = t.timeIntervalSince(meta.startDate)
        let near = Set(events.filter { $0.start - 60 <= s && $0.end + 60 >= s }.map(\.group))
        parts += SoundGroup.allCases.filter { near.contains($0) }.map(\.title)
        return parts.joined(separator: " · ")
    }

    private var legend: some View {
        ViewThatFits {
            HStack(spacing: 12) { legendItems }
            VStack(alignment: .leading, spacing: 4) { legendItems }
        }
        .font(.caption2)
        .foregroundStyle(Theme.secondaryText)
    }

    @ViewBuilder private var legendItems: some View {
        ForEach(SoundGroup.allCases, id: \.self) { g in
            HStack(spacing: 4) {
                Circle().fill(Theme.color(g)).frame(width: 8, height: 8)
                Text(g.title)
            }
        }
        HStack(spacing: 4) {
            Rectangle().fill(Color.gray.opacity(0.35)).frame(width: 10, height: 8)
            Text("Datenlücke")
        }
    }

    private func play(_ event: SoundEvent) {
        guard let url = detail.clipURL(event) else { return }
        player.toggle(id: event.id, url: url)
    }

    // MARK: cards

    private func snoreCard(_ model: ReportModel) -> some View {
        Card(title: "Schnarchen") {
            if summary.snoreSeconds < 30 {
                Text("Kaum Schnarchen erkannt.").foregroundStyle(Theme.secondaryText)
            } else {
                HStack {
                    StatTile(title: "Minuten", value: "\(Int((summary.snoreSeconds / 60).rounded()))",
                             symbol: SoundGroup.snore.symbol, tint: Theme.color(SoundGroup.snore))
                    StatTile(title: "Anteil", value: "\(snorePercent) %")
                    StatTile(title: "Episoden", value: "\(summary.snoreEpisodes)")
                }
                SnoreBucketChart(buckets: model.snoreBuckets(events), model: model)
            }
        }
    }

    private var snorePercent: Int {
        let base = summary.asleep > 0 ? summary.asleep : summary.timeInBed
        return base > 0 ? Int((summary.snoreSeconds / base * 100).rounded()) : 0
    }

    private var countsRow: some View {
        Card(title: "Geräusche") {
            HStack {
                countTile(.talk, summary.talkCount)
                countTile(.cough, summary.coughCount)
                countTile(.environment, summary.environmentCount)
                countTile(.loud, summary.loudCount)
            }
        }
    }

    private func countTile(_ group: SoundGroup, _ count: Int) -> some View {
        StatTile(title: group.title, value: "\(count)", symbol: group.symbol, tint: Theme.color(group))
    }

    private var dataQualityCard: some View {
        Card(title: "Datenqualität") {
            Text("Lücken insgesamt: \(Fmt.duration(max(summary.gapSeconds, meta.gaps.reduce(0) { $0 + $1.end - $1.start })))")
                .font(.subheadline)
            ForEach(Array(meta.gaps.enumerated()), id: \.offset) { _, gap in
                HStack {
                    Image(systemName: "waveform.slash").foregroundStyle(.orange)
                    Text("\(Fmt.time(meta.startDate.addingTimeInterval(gap.start))) · \(Self.gapReason(gap.reason))")
                    Spacer()
                    Text(Fmt.duration(gap.end - gap.start)).foregroundStyle(Theme.secondaryText)
                }
                .font(.caption)
            }
            Text("In Lücken wurde nicht aufgenommen – sie zählen nicht als Schlaf.")
                .font(.caption2).foregroundStyle(Theme.secondaryText)
        }
    }

    static func gapReason(_ raw: String) -> String {
        switch raw {
        case "app_beendet": return "App wurde beendet"
        case "interruption": return "Unterbrechung (Anruf, Siri, Wecker)"
        case "config_change": return "Audio-Gerät gewechselt"
        case "media_reset": return "Audio-System neu gestartet"
        case "stall": return "Aufnahme hing"
        default: return raw
        }
    }

    // MARK: mood and notes

    private var moodCard: some View {
        Card(title: "Wie fühlst du dich?") {
            HStack(spacing: 12) {
                ForEach([1, 2, 3], id: \.self) { m in
                    Button {
                        var updated = meta
                        updated.mood = updated.mood == m ? nil : m
                        save(updated)
                    } label: {
                        Text(["😫", "😐", "😊"][m - 1])
                            .font(.system(size: 36))
                            .padding(8)
                            .background(meta.mood == m ? Theme.accent.opacity(0.35) : Theme.elevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(["Schlecht", "Mittel", "Gut"][m - 1])
                    .accessibilityAddTraits(meta.mood == m ? .isSelected : [])
                }
            }
            Text("Notizen").font(.subheadline).foregroundStyle(Theme.secondaryText)
            FlowChips(tags: allTags, selected: Set(meta.tags), toggle: toggleTag) { askTag = true }
        }
    }

    private var allTags: [String] {
        var tags = Self.presetTags
        for t in meta.tags where !tags.contains(t) { tags.append(t) }
        return tags
    }

    private func toggleTag(_ tag: String) {
        var updated = meta
        if let i = updated.tags.firstIndex(of: tag) { updated.tags.remove(at: i) } else { updated.tags.append(tag) }
        save(updated)
    }

    private func addTag(_ raw: String) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        newTag = ""
        guard !tag.isEmpty, !meta.tags.contains(tag) else { return }
        var updated = meta
        updated.tags.append(tag)
        save(updated)
    }

    private func save(_ updated: SessionMeta) {
        store.save(updated)
        reload()
    }
}

/// Wrapping row of tag chips plus a "+" chip.
struct FlowChips: View {
    var tags: [String]
    var selected: Set<String>
    var toggle: (String) -> Void
    var add: () -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Chip(title: tag, selected: selected.contains(tag)) { toggle(tag) }
            }
            Chip(title: "+ Eigene", selected: false, action: add)
        }
    }
}
