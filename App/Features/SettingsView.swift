import SleepEngineCore
import SwiftUI

/// Tab "Einstellungen": wake-up, detection, storage, goals, diagnostics, about.
struct SettingsView: View {
    @Environment(SessionController.self) private var controller
    @Environment(SessionStore.self) private var store
    @AppStorage(AppSettings.Key.windowMinutes) private var windowMinutes = 30
    @AppStorage(AppSettings.Key.snoozeEnabled) private var snoozeEnabled = true
    @AppStorage(AppSettings.Key.snoozeMinutes) private var snoozeMinutes = 9
    @AppStorage(AppSettings.Key.preAlarmEnabled) private var preAlarmEnabled = true
    @AppStorage(AppSettings.Key.preAlarmSeconds) private var preAlarmSeconds = 60
    @AppStorage(AppSettings.Key.sensitivity) private var sensitivity: Sensitivity = .medium
    @AppStorage(AppSettings.Key.fullNightAudio) private var fullNightAudio = false
    @AppStorage(AppSettings.Key.clipRetentionDays) private var clipRetentionDays = 30
    @AppStorage(AppSettings.Key.sleepGoalHours) private var sleepGoalHours = 8.0
    @AppStorage(AppSettings.Key.nightstandMode) private var nightstandMode = false
    @AppStorage(AppSettings.Key.showLevelMeter) private var showLevelMeter = true
    @AppStorage(AppSettings.Key.storeSnore) private var storeSnore = true
    @AppStorage(AppSettings.Key.storeTalk) private var storeTalk = true
    @AppStorage(AppSettings.Key.storeCough) private var storeCough = true
    @AppStorage(AppSettings.Key.storeEnvironment) private var storeEnvironment = true
    @AppStorage(AppSettings.Key.storeLoud) private var storeLoud = true

    @State private var versionTaps = 0
    @State private var showDebug = false
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var exporting = false

    var body: some View {
        NavigationStack {
            Form {
                wakeSection
                detectionSection
                storageSection
                Section("Ziele") {
                    Stepper("Schlafziel: \(String(format: "%g", sleepGoalHours)) h", value: $sleepGoalHours, in: 5...11, step: 0.5)
                }
                testSection
                exportSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Einstellungen")
            .navigationDestination(isPresented: $showDebug) { DebugView() }
        }
    }

    private var wakeSection: some View {
        Section {
            Picker("Standard-Weckfenster", selection: $windowMinutes) {
                ForEach(SetupView.windowOptions, id: \.self) { m in Text(m == 0 ? "Exakt" : "\(m) min").tag(m) }
            }
            Toggle("Sanfter Vorlauf", isOn: $preAlarmEnabled)
            if preAlarmEnabled {
                Picker("Vorlauf-Dauer", selection: $preAlarmSeconds) {
                    Text("30 s").tag(30)
                    Text("60 s").tag(60)
                    Text("90 s").tag(90)
                }
            }
            Toggle("Schlummern", isOn: $snoozeEnabled)
            if snoozeEnabled {
                Stepper("Schlummern: \(snoozeMinutes) min", value: $snoozeMinutes, in: 1...30)
            }
        } header: {
            Text("Wecken")
        } footer: {
            Text("Weckton ist der Systemton (eigene Töne sind mit AlarmKit unzuverlässig). Der Vorlauf blendet einen leisen Ton aus der App ein, bevor der Wecker klingelt.")
        }
    }

    private var detectionSection: some View {
        Section {
            Picker("Empfindlichkeit", selection: $sensitivity) {
                Text("Niedrig").tag(Sensitivity.low)
                Text("Mittel").tag(Sensitivity.medium)
                Text("Hoch").tag(Sensitivity.high)
            }
            Toggle("Schnarchen speichern", isOn: $storeSnore)
            Toggle("Reden speichern", isOn: $storeTalk)
            Toggle("Husten speichern", isOn: $storeCough)
            Toggle("Umgebung speichern", isOn: $storeEnvironment)
            Toggle("Laute Geräusche speichern", isOn: $storeLoud)
            Toggle("Pegelanzeige in der Nacht", isOn: $showLevelMeter)
            Toggle("Nachttisch-Modus", isOn: $nightstandMode)
        } header: {
            Text("Erkennung")
        } footer: {
            Text("Nachttisch-Modus: Der Bildschirm bleibt an (schwarz). Sicherer gegen Abbrüche, braucht das Ladekabel.")
        }
    }

    private var storageSection: some View {
        Section {
            Picker("Aufnahmen behalten", selection: $clipRetentionDays) {
                Text("7 Tage").tag(7)
                Text("30 Tage").tag(30)
                Text("90 Tage").tag(90)
                Text("Unbegrenzt").tag(0)
            }
            Toggle("Ganznacht-Aufnahme", isOn: $fullNightAudio)
            Button {
                Task { await store.reanalyzeAll() }
            } label: {
                HStack {
                    Text("Alle Nächte neu analysieren")
                    Spacer()
                    if store.isBusy { ProgressView() }
                }
            }
            .disabled(store.isBusy || controller.phase != .idle)
        } header: {
            Text("Speicher")
        } footer: {
            Text("Favoriten bleiben immer. Ganznacht-Aufnahme braucht ca. 90 MB pro Nacht und hilft beim Feintuning. Messdaten (frames.bin) werden nie gelöscht.")
        }
    }

    private var testSection: some View {
        Section {
            Button("Testsession starten (10 min)") {
                Task { await controller.startNight(test: true) }
            }
            .disabled(controller.phase != .idle)
            if let error = controller.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Test")
        } footer: {
            Text("Späteste Weckzeit in 10 Minuten, Fenster 5 Minuten – der ganze Ablauf tagsüber in Minuten.")
        }
    }

    private var exportSection: some View {
        Section {
            if let latest = store.sessions.first(where: \.isFinished) {
                Button("Letzte Nacht exportieren (\(Fmt.day(latest.startDate)))") { runExport { try store.export(latest.id) } }
            }
            Button("Alle Nächte exportieren") { runExport { try store.exportAll() } }
            if exporting { ProgressView() }
            if let url = exportURL {
                ShareLink(item: url) {
                    Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
                }
            }
            if let exportError {
                Text(exportError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Export")
        } footer: {
            Text("ZIP liegt auch unter iTunes/Geräte → Dateifreigabe → Schlafkurve → Exports. Über Teilen → „In Dateien sichern“ landet es im iCloud Drive.")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(AppSettings.appBuild).foregroundStyle(Theme.secondaryText).monospacedDigit()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                versionTaps += 1
                if versionTaps >= 5 {
                    versionTaps = 0
                    showDebug = true
                }
            }
            Text("Schlafkurve ist kein Medizinprodukt und stellt keine Diagnosen. Schlafphasen und Atmung sind Schätzungen aus Geräuschen.")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        } header: {
            Text("Über")
        }
    }

    private func runExport(_ work: @escaping () throws -> URL) {
        exporting = true
        exportError = nil
        exportURL = nil
        Task {
            do {
                exportURL = try work()
            } catch {
                exportError = "Export fehlgeschlagen: \(error.localizedDescription)"
            }
            exporting = false
        }
    }
}
