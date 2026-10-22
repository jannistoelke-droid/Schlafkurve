import SleepEngineCore
import SwiftUI

/// Hidden diagnostics screen (5 taps on the version number).
struct DebugView: View {
    @Environment(SessionController.self) private var controller
    @Environment(SessionStore.self) private var store
    @State private var logSessionID: String?
    @State private var logLines: [String] = []

    var body: some View {
        List {
            Section("Live") {
                row("Phase", "\(controller.phase)")
                row("Aufnahme", controller.captureOK ? "ok" : "gestört")
                row("Pegel über Grundrauschen", String(format: "%.1f dB", controller.liveLevel))
                row("Klassifikator", controller.liveLabel.isEmpty ? "–" : controller.liveLabel)
                row("Live-Phase", controller.liveStage?.title ?? "–")
                row("Weckentscheidung", controller.wokeReason?.title ?? (controller.wakeTriggered ? "ja" : "nein"))
                row("Akku", controller.batteryText())
                row("Frei", "\(controller.freeMegabytes()) MB")
                row("Wecker-Erlaubnis", AlarmService.shared.isAuthorized ? "ja" : (AlarmService.shared.isDenied ? "verweigert" : "offen"))
                if let error = controller.lastError { Text(error).foregroundStyle(.red) }
            }
            if !controller.debugLines.isEmpty {
                Section("Eventlog (laufende Nacht)") {
                    ForEach(Array(controller.debugLines.enumerated()), id: \.offset) { _, line in logLine(line) }
                }
            }
            Section("Eventlog einer Nacht") {
                Picker("Nacht", selection: $logSessionID) {
                    Text("–").tag(String?.none)
                    ForEach(store.sessions) { meta in
                        Text("\(Fmt.day(meta.startDate)) \(Fmt.time(meta.startDate))\(meta.isTest ? " (Test)" : "")")
                            .tag(Optional(meta.id))
                    }
                }
                ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in logLine(line) }
            }
            Section("Speicher") {
                row("Nächte", "\(store.sessions.count)")
                row("Ordner", SessionFiles.root.path)
            }
        }
        .navigationTitle("Diagnose")
        .onAppear { if logSessionID == nil { logSessionID = store.sessions.first?.id } }
        .onChange(of: logSessionID) { _, id in loadLog(id) }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.trailing).monospacedDigit()
        }
        .font(.subheadline)
    }

    private func logLine(_ line: String) -> some View {
        Text(line).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
    }

    /// Last 150 lines of eventlog.jsonl, newest first.
    private func loadLog(_ id: String?) {
        guard let id else { logLines = []; return }
        let url = SessionFiles.folder(id).appendingPathComponent("eventlog.jsonl")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        logLines = Array(text.split(separator: "\n").suffix(150).reversed().map(String.init))
    }
}
