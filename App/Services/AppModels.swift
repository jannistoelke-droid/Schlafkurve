import Foundation
import SleepEngineCore

enum SessionMode: String, Codable, CaseIterable, Identifiable {
    case smart, regular, trackingOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: return "Smart-Wecker"
        case .regular: return "Normaler Wecker"
        case .trackingOnly: return "Nur Tracking"
        }
    }
}

struct SessionMeta: Codable, Identifiable, Equatable {
    var id: String
    var startDate: Date
    var endDate: Date?
    var latestWake: Date?
    var windowMinutes: Int
    var mode: SessionMode
    var wakeDate: Date?
    var wakeReason: WakeReason?
    var gaps: [DataGap] = []
    var mood: Int?
    var tags: [String] = []
    var isTest: Bool = false
    var fullNightAudio: Bool = false
    var appBuild: String = ""
    var summary: SleepSummary?

    var isFinished: Bool { endDate != nil }
    var windowStart: Date? { latestWake.map { $0.addingTimeInterval(-Double(windowMinutes) * 60) } }
}

/// User settings (UserDefaults). Views use @AppStorage with the same keys and defaults.
enum AppSettings {
    enum Key {
        static let wakeHour = "wakeHour"
        static let wakeMinute = "wakeMinute"
        static let windowMinutes = "windowMinutes"
        static let mode = "mode"
        static let snoozeEnabled = "snoozeEnabled"
        static let snoozeMinutes = "snoozeMinutes"
        static let preAlarmEnabled = "preAlarmEnabled"
        static let preAlarmSeconds = "preAlarmSeconds"
        static let sensitivity = "sensitivity"
        static let fullNightAudio = "fullNightAudio"
        static let clipRetentionDays = "clipRetentionDays"
        static let sleepGoalHours = "sleepGoalHours"
        static let nightstandMode = "nightstandMode"
        static let showLevelMeter = "showLevelMeter"
        static let storeTalk = "storeTalk"
        static let storeSnore = "storeSnore"
        static let storeCough = "storeCough"
        static let storeEnvironment = "storeEnvironment"
        static let storeLoud = "storeLoud"
    }

    private static var d: UserDefaults { .standard }
    private static func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) as? Int ?? def }
    private static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }

    static var wakeHour: Int { int(Key.wakeHour, 7) }
    static var wakeMinute: Int { int(Key.wakeMinute, 0) }
    static var windowMinutes: Int { int(Key.windowMinutes, 30) }
    static var mode: SessionMode { SessionMode(rawValue: d.string(forKey: Key.mode) ?? "") ?? .smart }
    static var snoozeEnabled: Bool { bool(Key.snoozeEnabled, true) }
    static var snoozeMinutes: Int { int(Key.snoozeMinutes, 9) }
    static var preAlarmEnabled: Bool { bool(Key.preAlarmEnabled, true) }
    static var preAlarmSeconds: Int { int(Key.preAlarmSeconds, 60) }
    static var sensitivity: Sensitivity { Sensitivity(rawValue: d.string(forKey: Key.sensitivity) ?? "") ?? .medium }
    static var fullNightAudio: Bool { bool(Key.fullNightAudio, false) }
    static var clipRetentionDays: Int { int(Key.clipRetentionDays, 30) }
    static var sleepGoalHours: Double { d.object(forKey: Key.sleepGoalHours) as? Double ?? 8 }
    static var nightstandMode: Bool { bool(Key.nightstandMode, false) }

    static func storesClips(for group: SoundGroup) -> Bool {
        switch group {
        case .talk: return bool(Key.storeTalk, true)
        case .snore: return bool(Key.storeSnore, true)
        case .cough: return bool(Key.storeCough, true)
        case .environment: return bool(Key.storeEnvironment, true)
        case .loud: return bool(Key.storeLoud, true)
        }
    }

    /// Next occurrence of the configured wake time.
    static func nextWakeDate(hour: Int = wakeHour, minute: Int = wakeMinute, from now: Date = Date()) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let today = cal.date(from: comps) ?? now
        return today > now.addingTimeInterval(60) ? today : (cal.date(byAdding: .day, value: 1, to: today) ?? today)
    }

    static var appBuild: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

extension SleepStage {
    var title: String {
        switch self {
        case .wake: return "Wach"
        case .light: return "Leichtschlaf"
        case .deep: return "Tiefschlaf"
        case .rem: return "Traumschlaf"
        }
    }
}

extension SoundGroup {
    var title: String {
        switch self {
        case .snore: return "Schnarchen"
        case .talk: return "Reden"
        case .cough: return "Husten"
        case .environment: return "Umgebung"
        case .loud: return "Laut"
        }
    }

    var symbol: String {
        switch self {
        case .snore: return "zzz"
        case .talk: return "text.bubble"
        case .cough: return "lungs"
        case .environment: return "pawprint"
        case .loud: return "speaker.wave.3"
        }
    }
}

extension WakeReason {
    var title: String {
        switch self {
        case .smartLightSleep: return "im Leichtschlaf geweckt"
        case .awakeDetected: return "du warst schon wach"
        case .deadline: return "zur spätesten Weckzeit"
        case .manualStop: return "manuell beendet"
        case .backupFired: return "Sicherheitswecker"
        case .none: return "ohne Wecker"
        }
    }
}

enum Fmt {
    static func time(_ d: Date?) -> String {
        guard let d else { return "–" }
        return d.formatted(date: .omitted, time: .shortened)
    }

    static func duration(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite else { return "–" }
        let m = Int((s / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    static func day(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
