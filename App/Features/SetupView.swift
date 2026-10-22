import AVFoundation
import SleepEngineCore
import SwiftUI
import UIKit

/// Tab "Wecker": latest wake time, wake window, mode, preflight checklist, Start.
struct SetupView: View {
    @Environment(SessionController.self) private var controller
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettings.Key.wakeHour) private var wakeHour = 7
    @AppStorage(AppSettings.Key.wakeMinute) private var wakeMinute = 0
    @AppStorage(AppSettings.Key.windowMinutes) private var windowMinutes = 30
    @AppStorage(AppSettings.Key.mode) private var mode: SessionMode = .smart
    @State private var checks: [PreflightCheck] = []
    @State private var starting = false

    static let windowOptions = [0, 10, 15, 20, 30, 45, 60, 90]

    private var wakeTime: Binding<Date> {
        Binding(
            get: { AppSettings.nextWakeDate(hour: wakeHour, minute: wakeMinute) },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                wakeHour = c.hour ?? 7
                wakeMinute = c.minute ?? 0
            })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if mode != .trackingOnly {
                        Card(title: "Spätestens wecken um") {
                            DatePicker("Weckzeit", selection: wakeTime, displayedComponents: .hourAndMinute)
                                .datePickerStyle(.wheel)
                                .labelsHidden()
                                .frame(maxWidth: .infinity)
                        }
                    }
                    if mode == .smart {
                        Card(title: "Weckfenster") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Self.windowOptions, id: \.self) { m in
                                        Chip(title: m == 0 ? "Exakt" : "\(m) min", selected: windowMinutes == m) {
                                            windowMinutes = m
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Card(title: "Modus") {
                        Picker("Modus", selection: $mode) {
                            ForEach(SessionMode.allCases) { m in Text(m.title).tag(m) }
                        }
                        .pickerStyle(.segmented)
                        summaryLine
                    }
                    Card(title: "Vor dem Schlafen") {
                        ForEach(checks) { check in PreflightRow(check: check) }
                    }
                    if let error = controller.lastError {
                        HintBanner(text: error, tint: .red)
                    }
                    startButton
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Wecker")
        }
        .onAppear(perform: refreshChecks)
        .onChange(of: mode) { _, _ in refreshChecks() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshChecks() } }
    }

    private var summaryLine: some View {
        TimelineView(.everyMinute) { context in
            Text(summaryText(now: context.date))
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryText(now: Date) -> String {
        let latest = AppSettings.nextWakeDate(hour: wakeHour, minute: wakeMinute, from: now)
        let remaining = Fmt.duration(latest.timeIntervalSince(now))
        switch mode {
        case .trackingOnly:
            return "Nur Aufzeichnung – kein Wecker. Beenden mit Halten auf dem Nachtbildschirm."
        case .regular:
            return "Weckt dich um \(Fmt.time(latest)) · noch ca. \(remaining)"
        case .smart:
            if windowMinutes == 0 { return "Weckt dich um \(Fmt.time(latest)) · noch ca. \(remaining)" }
            let start = latest.addingTimeInterval(-Double(windowMinutes) * 60)
            return "Weckt dich zwischen \(Fmt.time(start)) und \(Fmt.time(latest)) · noch ca. \(remaining)"
        }
    }

    private var startButton: some View {
        Button {
            guard !starting else { return }
            starting = true
            Task {
                await controller.requestNotificationPermission()
                await controller.startNight()
                starting = false
                refreshChecks()
            }
        } label: {
            HStack {
                if starting { ProgressView().tint(.black) }
                Text("Start").font(.title2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 20))
        .foregroundStyle(.black)
        .disabled(starting)
    }

    private func refreshChecks() {
        checks = PreflightCheck.current(needsAlarm: mode != .trackingOnly, freeMB: controller.freeMegabytes())
    }
}

struct PreflightCheck: Identifiable {
    enum Level { case ok, warn, bad, info }

    var id: String
    var level: Level
    var title: String
    var detail: String

    @MainActor
    static func current(needsAlarm: Bool, freeMB: Int) -> [PreflightCheck] {
        var list: [PreflightCheck] = []

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            list.append(.init(id: "mic", level: .ok, title: "Mikrofon", detail: "Zugriff erlaubt"))
        case .denied:
            list.append(.init(id: "mic", level: .bad, title: "Mikrofon",
                              detail: "Verweigert – Einstellungen → Schlafkurve → Mikrofon"))
        default:
            list.append(.init(id: "mic", level: .warn, title: "Mikrofon", detail: "Wird beim Start abgefragt"))
        }

        if needsAlarm {
            let alarms = AlarmService.shared
            if alarms.isAuthorized {
                list.append(.init(id: "alarm", level: .ok, title: "Wecker", detail: "Erlaubt – klingelt auch bei Stummschaltung"))
            } else if alarms.isDenied {
                list.append(.init(id: "alarm", level: .bad, title: "Wecker",
                                  detail: "Verweigert – Einstellungen → Schlafkurve → Wecker & Timer"))
            } else {
                list.append(.init(id: "alarm", level: .warn, title: "Wecker", detail: "Wird beim Start abgefragt"))
            }
        }

        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let charging = device.batteryState == .charging || device.batteryState == .full
        let level = device.batteryLevel
        if charging {
            list.append(.init(id: "battery", level: .ok, title: "Akku", detail: "Am Ladekabel"))
        } else if level >= 0.3 || level < 0 {
            let text = level < 0 ? "Ladekabel empfohlen" : "\(Int(level * 100)) % – Ladekabel empfohlen (~30 % pro Nacht)"
            list.append(.init(id: "battery", level: .warn, title: "Akku", detail: text))
        } else {
            list.append(.init(id: "battery", level: .bad, title: "Akku", detail: "\(Int(level * 100)) % – bitte ans Ladekabel"))
        }

        list.append(.init(id: "space", level: freeMB >= 2000 ? .ok : .warn, title: "Speicher",
                          detail: freeMB >= 2000 ? "\(freeMB / 1000) GB frei" : "Nur \(freeMB) MB frei – mind. 2 GB empfohlen"))

        let bluetooth: [AVAudioSession.Port] = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        let route = AVAudioSession.sharedInstance().currentRoute
        let usesBluetooth = (route.outputs + route.inputs).contains { bluetooth.contains($0.portType) }
        list.append(.init(id: "bt", level: usesBluetooth ? .bad : .ok, title: "Bluetooth",
                          detail: usesBluetooth ? "Kopfhörer/Lautsprecher verbunden – bitte trennen" : "Kein Headset verbunden"))

        list.append(.init(id: "focus", level: .info, title: "Flugmodus oder Schlaf-Fokus",
                          detail: "Verhindert Anrufe, die die Aufnahme unterbrechen. Der Wecker klingelt trotzdem."))
        if needsAlarm {
            list.append(.init(id: "volume", level: .info, title: "Wecker-Lautstärke",
                              detail: "Einstellungen → Töne & Haptik → Klingelton- und Hinweislautstärke prüfen"))
        }
        list.append(.init(id: "place", level: .info, title: "Platzierung",
                          detail: "Nachttisch, Unterseite Richtung Bett, 0,5–1 m Abstand, keine Musik-Apps"))
        return list
    }
}

struct PreflightRow: View {
    var check: PreflightCheck

    private var symbol: (String, Color) {
        switch check.level {
        case .ok: return ("checkmark.circle.fill", .green)
        case .warn: return ("exclamationmark.circle.fill", .yellow)
        case .bad: return ("xmark.circle.fill", .red)
        case .info: return ("info.circle", Theme.secondaryText)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol.0).foregroundStyle(symbol.1).font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.subheadline.weight(.medium))
                Text(check.detail).font(.caption).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
