import SleepEngineCore
import SwiftUI

/// Clips of one night: highlights first, then grouped by type.
struct RecordingsSection: View {
    var detail: SessionDetail
    var model: ReportModel
    var events: [SoundEvent]
    var editable: Bool
    var reload: () -> Void

    private var clips: [SoundEvent] { events.filter { e in detail.clipURL(e).map { FileManager.default.fileExists(atPath: $0.path) } ?? false } }

    /// Favourites plus the three loudest clips.
    private var highlights: [SoundEvent] {
        let favourites = clips.filter { detail.edit(for: $0.id).favorite }
        let loudest = clips.sorted { $0.peakDb > $1.peakDb }.prefix(3)
        var result = favourites
        for e in loudest where !result.contains(where: { $0.id == e.id }) { result.append(e) }
        return result.sorted { $0.start < $1.start }
    }

    var body: some View {
        Card(title: "Aufnahmen") {
            if clips.isEmpty {
                Text(events.isEmpty ? "Keine Geräusche erkannt." : "Keine Aufnahmen gespeichert (abgelaufen oder abgeschaltet).")
                    .foregroundStyle(Theme.secondaryText)
            } else {
                if clips.count > 4 {
                    Text("Highlights").font(.subheadline.weight(.semibold))
                    ForEach(highlights) { e in row(e) }
                    Divider().overlay(Theme.elevated)
                }
                ForEach(SoundGroup.allCases, id: \.self) { group in
                    let items = clips.filter { $0.group == group }.sorted { $0.start < $1.start }
                    if !items.isEmpty {
                        DisclosureGroup {
                            ForEach(items) { e in row(e) }
                        } label: {
                            Label("\(group.title) (\(items.count))", systemImage: group.symbol)
                                .foregroundStyle(Theme.color(group))
                        }
                    }
                }
            }
        }
    }

    private func row(_ e: SoundEvent) -> some View {
        EventRow(event: e, start: model.start, url: detail.clipURL(e), edit: detail.edit(for: e.id), editable: editable,
                 change: { change in update(e, change) })
    }

    private func update(_ event: SoundEvent, _ change: @escaping (inout EventEdit) -> Void) {
        let id = detail.meta.id
        SessionStore.shared.updateEdit(sessionID: id, eventID: event.id, change)
        reload()
        Task {
            await SessionStore.shared.refreshSummary(id)
            reload()
        }
    }
}

struct EventRow: View {
    var event: SoundEvent
    var start: Date
    var url: URL?
    var edit: EventEdit
    var editable: Bool
    var change: (@escaping (inout EventEdit) -> Void) -> Void

    @Environment(ClipPlayer.self) private var player
    @State private var confirmDelete = false

    private var isPlaying: Bool { player.playingID == event.id }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if let url { player.toggle(id: event.id, url: url) }
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.color(event.group))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Abspielen")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: event.group.symbol).foregroundStyle(Theme.color(event.group))
                    Text(Fmt.time(start.addingTimeInterval(event.start))).monospacedDigit()
                    Text("· \(Int(event.duration.rounded())) s").foregroundStyle(Theme.secondaryText)
                    if edit.userGroup != nil {
                        Image(systemName: "pencil").font(.caption2).foregroundStyle(Theme.secondaryText)
                    }
                }
                .font(.subheadline)
                WaveformView(samples: event.waveform, progress: isPlaying ? player.progress : 0, tint: Theme.color(event.group))
                    .frame(height: 22)
            }

            if editable {
                Button {
                    change { $0.favorite.toggle() }
                } label: {
                    Image(systemName: edit.favorite ? "star.fill" : "star")
                        .foregroundStyle(edit.favorite ? Color.yellow : Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(edit.favorite ? "Favorit entfernen" : "Als Favorit merken")
                menu
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .confirmationDialog("Aufnahme löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { change { $0.deleted = true } }
        }
    }

    private var menu: some View {
        Menu {
            Menu("Typ ändern") {
                ForEach(SoundGroup.allCases, id: \.self) { g in
                    Button {
                        change { $0.userGroup = g }
                    } label: {
                        Label(g.title, systemImage: g == event.group ? "checkmark" : g.symbol)
                    }
                }
            }
            Button {
                change { $0.isFalseDetection = true }
            } label: {
                Label("Fehlerkennung", systemImage: "xmark.circle")
            }
            if let url {
                ShareLink(item: url) { Label("Teilen", systemImage: "square.and.arrow.up") }
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(Theme.secondaryText)
        }
        .accessibilityLabel("Weitere Aktionen")
    }
}
