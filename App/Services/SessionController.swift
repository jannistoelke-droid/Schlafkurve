import AVFoundation
import Foundation
import Observation
import SleepEngineCore
import UIKit
import UserNotifications

/// Orchestrates one night: permissions → backup alarm → capture → live wake decisions →
/// alarm stop → final analysis → morning report.
@MainActor
@Observable
final class SessionController {
    enum Phase: Equatable { case idle, tracking, finishing }

    static let shared = SessionController()

    var phase: Phase = .idle
    var current: SessionMeta?
    var liveLevel: Float = 0
    var liveLabel: String = ""
    var liveStage: SleepStage?
    var captureOK = true
    var wakeTriggered = false
    var wokeReason: WakeReason?
    var pendingReportID: String?
    var lastError: String?
    var debugLines: [String] = []

    @ObservationIgnored private let store = SessionStore.shared
    @ObservationIgnored private let alarms = AlarmService.shared
    @ObservationIgnored private let capture = AudioCaptureService()
    @ObservationIgnored private var pipeline: NightPipeline?
    @ObservationIgnored private var log: DiagnosticsLog?
    @ObservationIgnored private var watchdog: DispatchSourceTimer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var launched = false
    @ObservationIgnored private let decider = WakeDecider()

    var isTracking: Bool { phase == .tracking }

    // MARK: app lifecycle

    func launch() async {
        guard !launched else { return }
        launched = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        alarms.startObserving()
        alarms.onAlerting = { [weak self] in self?.capture.stopPreAlarm() }
        let recovered = await store.recoverUnfinished(excluding: current?.id)
        if let last = recovered.last { pendingReportID = last }
        store.applyRetention()
    }

    func scenePhaseChanged(active: Bool) {
        isForeground = active
        log?.log(active ? "foreground" : "background", [:])
        if active && phase == .tracking {
            capture.restartIfNeeded(reason: "foreground")
        }
    }

    // MARK: start

    func startNight(test: Bool = false) async {
        guard phase == .idle else { return }
        lastError = nil
        ClipPlayer.shared.stop()

        if AVAudioApplication.shared.recordPermission != .granted {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                lastError = "Kein Mikrofonzugriff. Bitte in Einstellungen → Schlafkurve → Mikrofon erlauben."
                return
            }
        }

        let mode = test ? SessionMode.smart : AppSettings.mode
        let window = test ? 5 : AppSettings.windowMinutes
        let start = Date()
        let latest: Date? = mode == .trackingOnly ? nil : (test ? start.addingTimeInterval(10 * 60) : AppSettings.nextWakeDate())
        let id = SessionFiles.makeID(for: start)
        let folder = SessionFiles.folder(id)
        do {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("clips"), withIntermediateDirectories: true)
        } catch {
            lastError = "Speicherordner konnte nicht angelegt werden."
            return
        }
        let log = DiagnosticsLog(url: folder.appendingPathComponent("eventlog.jsonl"), start: start)
        self.log = log
        alarms.log = { event, fields in log.log(event, fields) }
        capture.log = { event, fields in log.log(event, fields) }

        if let latest {
            if !alarms.isAuthorized {
                let ok = await alarms.requestAuthorization()
                if !ok {
                    lastError = "Ohne Wecker-Erlaubnis kann ich nicht wecken. Erlaube sie in den Einstellungen oder wähle „Nur Tracking“."
                    try? FileManager.default.removeItem(at: folder)
                    return
                }
            }
            do {
                try await alarms.scheduleBackup(at: latest, sessionID: id)
            } catch {
                lastError = "Wecker konnte nicht gestellt werden: \(error.localizedDescription)"
                try? FileManager.default.removeItem(at: folder)
                return
            }
        }

        var meta = SessionMeta(id: id, startDate: start, latestWake: latest, windowMinutes: mode == .smart ? window : 0, mode: mode)
        meta.isTest = test
        meta.fullNightAudio = AppSettings.fullNightAudio
        meta.appBuild = AppSettings.appBuild
        store.save(meta)

        do {
            let config = NightPipeline.Config(folder: folder, start: start, sensitivity: AppSettings.sensitivity,
                                              fullNightAudio: meta.fullNightAudio)
            let pipeline = try NightPipeline(config: config, log: log)
            pipeline.onEpoch = { [weak self] live, hasOnset in
                Task { @MainActor in self?.handleEpoch(live, hasOnset: hasOnset) }
            }
            pipeline.onSecond = { [weak self] level, label in
                Task { @MainActor in
                    guard let self, self.isForeground else { return }
                    self.liveLevel = level
                    if !label.isEmpty { self.liveLabel = label }
                }
            }
            try capture.start(pipeline: pipeline)
            self.pipeline = pipeline
        } catch {
            alarms.cancelAll()
            lastError = "Aufnahme konnte nicht starten: \(error.localizedDescription)"
            log.log("start_failed", ["error": "\(error)"])
            meta.endDate = Date()
            store.save(meta)
            return
        }

        current = meta
        phase = .tracking
        wakeTriggered = false
        wokeReason = nil
        liveStage = nil
        captureOK = true
        ticks = 0
        log.log("session_start", ["mode": mode.rawValue, "latest": latest?.formatted() ?? "-", "window": "\(window)",
                                  "test": "\(test)", "build": AppSettings.appBuild, "battery": batteryText(),
                                  "sensitivity": AppSettings.sensitivity.rawValue])
        startWatchdog()
        if AppSettings.nightstandMode { UIApplication.shared.isIdleTimerDisabled = true }
    }

    // MARK: during the night

    private func handleEpoch(_ live: [LiveEpoch], hasOnset: Bool) {
        guard phase == .tracking, let meta = current else { return }
        liveStage = live.last?.stage
        guard !wakeTriggered, meta.mode == .smart, let latest = meta.latestWake else { return }
        let decision = decider.evaluate(now: Date(), latest: latest, window: Double(meta.windowMinutes) * 60,
                                        recent: Array(live.suffix(6)), hasOnset: hasOnset)
        if case let .wakeNow(reason) = decision {
            Task { await triggerWake(reason) }
        }
    }

    private func triggerWake(_ reason: WakeReason) async {
        guard !wakeTriggered, let meta = current else { return }
        wakeTriggered = true
        wokeReason = reason
        log?.log("wake_decision", ["reason": reason.rawValue, "stage": liveStage.map { "\($0)" } ?? "-"])
        guard reason != .deadline, let latest = meta.latestWake else { return } // backup alarm rings at the deadline
        let pre = AppSettings.preAlarmEnabled ? Double(AppSettings.preAlarmSeconds) : 0
        let fireDate = Date().addingTimeInterval(max(pre, 5))
        guard fireDate < latest.addingTimeInterval(-5) else { return } // backup is about to ring anyway
        if pre > 0 {
            capture.startPreAlarm(duration: pre)
            pipeline?.markSelfPlayback(until: latest.addingTimeInterval(600))
        }
        do {
            try await alarms.fireReplacement(at: fireDate, sessionID: meta.id)
        } catch {
            log?.log("replacement_failed", ["error": "\(error)"])
        }
    }

    func handleAlarmStopped(alarmID: String) async {
        log?.log("alarm_stop_intent", ["id": String(alarmID.prefix(8))])
        capture.stopPreAlarm()
        if phase == .tracking {
            await finish(reason: wokeReason ?? .deadline)
        } else {
            let recovered = await store.recoverUnfinished(excluding: nil)
            if let last = recovered.last { pendingReportID = last }
        }
    }

    func handleSnooze(alarmID: String) async {
        log?.log("snooze_intent", ["id": String(alarmID.prefix(8))])
        capture.stopPreAlarm()
        let sessionID = current?.id ?? store.sessions.first?.id ?? "unknown"
        do {
            try await alarms.scheduleSnooze(minutes: AppSettings.snoozeMinutes, sessionID: sessionID)
        } catch {
            log?.log("snooze_failed", ["error": "\(error)"])
        }
        alarms.stop(alarmID: alarmID)
    }

    /// Manual stop from the night screen.
    func stopNight() async {
        await finish(reason: wakeTriggered || (current?.latestWake.map { Date() >= $0 } ?? false) ? (wokeReason ?? .deadline) : .manualStop)
    }

    // MARK: finish

    func finish(reason: WakeReason) async {
        guard phase == .tracking, var meta = current, let pipeline else { return }
        phase = .finishing
        stopWatchdog()
        capture.stop()
        alarms.cancelAll()
        UIApplication.shared.isIdleTimerDisabled = false
        let end = Date()
        meta.endDate = end
        meta.wakeReason = meta.mode == .trackingOnly ? WakeReason.none : reason
        meta.wakeDate = (reason == .manualStop || meta.mode == .trackingOnly) ? nil : end
        log?.log("session_end", ["reason": reason.rawValue, "battery": batteryText()])

        await Task.detached { pipeline.finish() }.value
        meta.gaps += pipeline.gaps
        let id = meta.id
        let bed = end.timeIntervalSince(meta.startDate)
        let goal = AppSettings.sleepGoalHours * 3600
        let analysis = await Task.detached { SessionFiles.analyze(id: id, timeInBed: bed, goalSeconds: goal) }.value
        meta.summary = analysis.summary
        store.save(meta)
        log?.log("analysis_done", ["quality": "\(analysis.summary.quality)", "asleep": "\(Int(analysis.summary.asleep / 60))"])
        log?.close()
        log = nil
        self.pipeline = nil
        current = nil
        phase = .idle
        pendingReportID = id
        await notifyReportReady(meta)
    }

    private func notifyReportReady(_ meta: SessionMeta) async {
        guard !isForeground else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Dein Schlafbericht ist fertig"
        if let s = meta.summary {
            content.body = "Qualität \(s.quality) % · geschlafen \(Fmt.duration(s.asleep))"
        }
        try? await center.add(UNNotificationRequest(identifier: meta.id, content: content, trigger: nil))
    }

    func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    // MARK: watchdog & heartbeat

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
        timer.resume()
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func watchdogTick() {
        guard phase == .tracking, let pipeline else { return }
        ticks += 1
        let age = pipeline.secondsSinceLastBuffer
        if age > 30 {
            if captureOK { log?.log("flatline", ["bufferAge": String(format: "%.0f", age)]) }
            captureOK = false
            if capture.restartIfNeeded(reason: "watchdog") { captureOK = true }
        } else if !captureOK {
            captureOK = true
            log?.log("capture_recovered", [:])
        }
        if ticks % 6 == 0 {
            let stats = pipeline.stats
            log?.log("heartbeat", [
                "bufferAge": String(format: "%.1f", age),
                "frames": "\(stats.frames)",
                "events": "\(stats.events)",
                "engine": "\(capture.engineRunning)",
                "battery": batteryText(),
                "thermal": "\(ProcessInfo.processInfo.thermalState.rawValue)",
                "cpu": String(format: "%.1f", cpuSeconds()),
                "freeMB": "\(freeMegabytes())",
                "stage": liveStage.map { "\($0)" } ?? "-",
            ])
        }
        if isForeground { debugLines = log.map { Array($0.recent.suffix(40).reversed()) } ?? [] }
    }

    // MARK: helpers

    func batteryText() -> String {
        let level = UIDevice.current.batteryLevel
        let state: String
        switch UIDevice.current.batteryState {
        case .charging: state = "lädt"
        case .full: state = "voll"
        case .unplugged: state = "Akku"
        default: state = "?"
        }
        return level >= 0 ? "\(Int(level * 100))% \(state)" : state
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    func freeMegabytes() -> Int {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int((values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000)
    }
}
