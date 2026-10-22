import ActivityKit
import AlarmKit
import AppIntents
import Foundation
import SwiftUI

struct SleepAlarmMetadata: AlarmMetadata {
    var sessionID: String
}

/// AlarmKit wrapper. v1 has no app extension, so no countdown presentation is used;
/// snoozing is done by our own intent that schedules a new one-shot alarm.
@MainActor
final class AlarmService {
    static let shared = AlarmService()

    var log: ((String, [String: String]) -> Void)?
    var onAlerting: (() -> Void)?
    private var updatesTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    private var backupID: UUID? {
        get { defaults.string(forKey: "alarm.backup").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "alarm.backup") }
    }

    private var activeIDs: [UUID] {
        get { (defaults.stringArray(forKey: "alarm.active") ?? []).compactMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue.map(\.uuidString), forKey: "alarm.active") }
    }

    var isAuthorized: Bool { AlarmManager.shared.authorizationState == .authorized }
    var isDenied: Bool { AlarmManager.shared.authorizationState == .denied }

    func requestAuthorization() async -> Bool {
        do {
            return try await AlarmManager.shared.requestAuthorization() == .authorized
        } catch {
            log?("alarm_auth_failed", ["error": "\(error)"])
            return false
        }
    }

    func startObserving() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await alarms in AlarmManager.shared.alarmUpdates {
                self?.handle(alarms)
            }
        }
    }

    private var lastStates: [UUID: String] = [:]

    private func handle(_ alarms: [Alarm]) {
        var seen: [UUID: String] = [:]
        for alarm in alarms {
            let state = "\(alarm.state)"
            seen[alarm.id] = state
            if lastStates[alarm.id] != state {
                log?("alarm_state", ["id": String(alarm.id.uuidString.prefix(8)), "state": state])
                if alarm.state == .alerting { onAlerting?() }
            }
        }
        lastStates = seen
    }

    /// Safety alarm at the latest wake time – scheduled before tracking starts.
    func scheduleBackup(at date: Date, sessionID: String) async throws {
        let id = UUID()
        try await schedule(id: id, at: date, sessionID: sessionID, kind: "backup")
        backupID = id
    }

    /// Smart wake-up: schedule the replacement first, cancel the backup only afterwards.
    func fireReplacement(at date: Date, sessionID: String) async throws {
        let id = UUID()
        try await schedule(id: id, at: date, sessionID: sessionID, kind: "smart")
        activeIDs = activeIDs + [id]
        if let backup = backupID {
            do {
                try AlarmManager.shared.cancel(id: backup)
            } catch {
                log?("alarm_cancel_failed", ["error": "\(error)"])
            }
            backupID = nil
        }
    }

    func scheduleSnooze(minutes: Int, sessionID: String) async throws {
        let id = UUID()
        try await schedule(id: id, at: Date().addingTimeInterval(Double(minutes) * 60), sessionID: sessionID, kind: "snooze")
        activeIDs = activeIDs + [id]
    }

    func stop(alarmID: String) {
        guard let id = UUID(uuidString: alarmID) else { return }
        do { try AlarmManager.shared.stop(id: id) } catch { log?("alarm_stop_failed", ["error": "\(error)"]) }
    }

    /// Removes every alarm of this app (end of session).
    func cancelAll() {
        var ids = Set(activeIDs)
        if let b = backupID { ids.insert(b) }
        if let all = try? AlarmManager.shared.alarms { for a in all { ids.insert(a.id) } }
        for id in ids { try? AlarmManager.shared.cancel(id: id) }
        backupID = nil
        activeIDs = []
        log?("alarms_cancelled", ["count": "\(ids.count)"])
    }

    private func schedule(id: UUID, at date: Date, sessionID: String, kind: String) async throws {
        let snooze = AppSettings.snoozeEnabled
        let snoozeButton: AlarmButton? = snooze ? AlarmButton(text: "Schlummern", textColor: .white, systemImageName: "zzz") : nil
        let behavior: AlarmPresentation.Alert.SecondaryButtonBehavior? = snooze ? .custom : nil
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: "Guten Morgen", secondaryButton: snoozeButton, secondaryButtonBehavior: behavior)
        } else {
            // iOS 26.0 has no system-provided stop button yet
            let stopButton = AlarmButton(text: "Stopp", textColor: .white, systemImageName: "stop.circle")
            alert = AlarmPresentation.Alert(title: "Guten Morgen", stopButton: stopButton,
                                            secondaryButton: snoozeButton, secondaryButtonBehavior: behavior)
        }
        let attributes = AlarmAttributes<SleepAlarmMetadata>(presentation: AlarmPresentation(alert: alert),
                                                             metadata: SleepAlarmMetadata(sessionID: sessionID),
                                                             tintColor: Color.indigo)
        let secondary: (any LiveActivityIntent)? = snooze ? SnoozeSleepAlarmIntent(alarmID: id.uuidString) : nil
        let configuration = AlarmManager.AlarmConfiguration<SleepAlarmMetadata>.alarm(
            schedule: .fixed(date),
            attributes: attributes,
            stopIntent: StopSleepAlarmIntent(alarmID: id.uuidString),
            secondaryIntent: secondary,
            sound: .default)
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        log?("alarm_scheduled", ["kind": kind, "id": String(id.uuidString.prefix(8)), "at": date.formatted(date: .omitted, time: .standard)])
    }
}

struct StopSleepAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Wecker stoppen"

    @Parameter(title: "Alarm")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        await SessionController.shared.handleAlarmStopped(alarmID: alarmID)
        return .result()
    }
}

struct SnoozeSleepAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Schlummern"

    @Parameter(title: "Alarm")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        await SessionController.shared.handleSnooze(alarmID: alarmID)
        return .result()
    }
}
