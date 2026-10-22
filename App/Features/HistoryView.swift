import SleepEngineCore
import SwiftUI

/// Tab "Nächte": all finished nights, newest first.
struct HistoryView: View {
    @Environment(SessionStore.self) private var store
    @State private var pendingDelete: SessionMeta?

    private var nights: [SessionMeta] { store.sessions.filter(\.isFinished) }

    var body: some View {
        NavigationStack {
            Group {
                if nights.isEmpty {
                    ContentUnavailableView("Noch keine Nächte", systemImage: "moon.stars",
                                           description: Text("Stell im Tab „Wecker“ deine Weckzeit ein und tippe auf Start."))
                } else {
                    List {
                        ForEach(nights) { meta in
                            NavigationLink(value: meta.id) { HistoryRow(meta: meta) }
                                .listRowBackground(Theme.surface)
                                .swipeActions {
                                    Button(role: .destructive) { pendingDelete = meta } label: {
                                        Label("Löschen", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle("Nächte")
            .navigationDestination(for: String.self) { id in ReportView(sessionID: id) }
            .confirmationDialog("Nacht löschen?", isPresented: Binding(get: { pendingDelete != nil },
                                                                      set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { meta in
                Button("Löschen", role: .destructive) { store.delete(meta.id) }
            } message: { _ in
                Text("Aufnahmen und Messdaten dieser Nacht werden endgültig entfernt.")
            }
        }
    }
}

struct HistoryRow: View {
    var meta: SessionMeta
    @State private var depth: [Float] = []

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(Fmt.day(meta.startDate)).font(.headline)
                    if meta.isTest {
                        Text("Test").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.25), in: Capsule())
                    }
                }
                HStack(spacing: 10) {
                    Label(Fmt.duration(meta.summary?.asleep), systemImage: "bed.double")
                    if let snore = meta.summary?.snoreSeconds, snore >= 60 {
                        Label("\(Int(snore / 60)) min", systemImage: SoundGroup.snore.symbol)
                            .foregroundStyle(Theme.color(SoundGroup.snore))
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 4)
            Sparkline(values: depth).frame(width: 70, height: 28)
            Text("\(meta.summary?.quality ?? 0) %")
                .font(.bigNumber(.title3))
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .task(id: meta.id) {
            let id = meta.id
            let values = await Task.detached { SessionFiles.readAnalysis(id)?.depth ?? [] }.value
            depth = Sparkline.downsample(values, to: 48)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Mini sleep-depth line (awake at the top).
struct Sparkline: View {
    var values: [Float]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            var path = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                                y: size.height * CGFloat(min(max(v, 0), 1)))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            context.stroke(path, with: .color(Theme.accent), lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }

    static func downsample(_ values: [Float], to count: Int) -> [Float] {
        guard values.count > count, count > 1 else { return values }
        let step = Double(values.count) / Double(count)
        return (0..<count).map { i in
            let a = Int(Double(i) * step)
            let b = min(values.count, max(a + 1, Int(Double(i + 1) * step)))
            let slice = values[a..<b]
            return slice.reduce(0, +) / Float(slice.count)
        }
    }
}
