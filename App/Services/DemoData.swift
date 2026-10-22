import Foundation
import SleepEngineCore

/// Sample nights for simulator screenshots (there is no Mac and no SwiftUI preview).
/// Only active with launch arguments, e.g. `-demoNights YES -demoTab report -demoScroll recordings`:
///   -demoTab    setup | history | stats | settings | report | night
///   -demoScroll chart | phases | snore | recordings | mood   (report only)
enum DemoData {
    private static var defaults: UserDefaults { .standard }

    static var isActive: Bool { defaults.bool(forKey: "demoNights") }
    static var tab: String? { defaults.string(forKey: "demoTab") }
    static var scrollTarget: String? { defaults.string(forKey: "demoScroll") }
    static let reportID = "demo-0"
    static let nightCount = 7

    /// Writes the sample nights once (skipped when they already exist).
    static func seedIfNeeded() {
        let marker = SessionFiles.folder("demo-\(nightCount - 1)").appendingPathComponent("session.json")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for k in 0..<nightCount {
            let base = k % 3 == 2 ? SyntheticNight.restless : SyntheticNight.typical
            var output = SyntheticNight(segments: base.segments, seed: UInt64(100 + k)).generate()
            let total = base.totalSeconds
            var gaps: [DataGap] = []
            if k == 0 {
                let gapStart = 2 * 3600.0 + 600
                let gapEnd = gapStart + 900
                output.frames.removeAll { $0.t >= gapStart && $0.t < gapEnd }
                output.events.removeAll { $0.end > gapStart && $0.start < gapEnd }
                gaps.append(DataGap(start: gapStart, end: gapEnd, reason: "interruption"))
            }

            let id = "demo-\(k)"
            let folder = SessionFiles.folder(id)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder.appendingPathComponent("clips"), withIntermediateDirectories: true)

            var snoreIndex = 0
            for i in output.events.indices {
                let e = output.events[i]
                if e.group == .snore {
                    snoreIndex += 1
                    if snoreIndex % 6 != 1 { continue }
                }
                let file = "clips/\(e.id.uuidString).m4a"
                FileManager.default.createFile(atPath: folder.appendingPathComponent(file).path, contents: Data())
                output.events[i].clipFile = file
            }

            let analysis = NightAnalyzer.analyze(frames: output.frames, events: output.events, timeInBed: total,
                                                 goalSeconds: 8 * 3600)
            let bedMinutes = 22 * 60 + 50 + (k * 17) % 50
            let night = cal.date(byAdding: .day, value: -(k + 1), to: today) ?? today
            let start = cal.date(byAdding: .minute, value: bedMinutes, to: night) ?? night
            let end = start.addingTimeInterval(total)

            var meta = SessionMeta(id: id, startDate: start, latestWake: end.addingTimeInterval(8 * 60), windowMinutes: 30, mode: .smart)
            meta.endDate = end
            meta.wakeDate = end
            meta.wakeReason = .smartLightSleep
            meta.gaps = gaps
            meta.mood = k % 3 == 2 ? 1 : (k % 2 == 0 ? 3 : 2)
            meta.tags = (k % 2 == 1 ? ["Kaffee"] : []) + (k % 3 == 0 ? ["Sport"] : [])
            meta.appBuild = "Demo"
            meta.summary = analysis.summary

            SessionFiles.writeMeta(meta)
            if let data = try? SessionFiles.encoder.encode(analysis) {
                try? data.write(to: folder.appendingPathComponent("analysis.json"), options: .atomic)
            }
            let encoder = JSONEncoder()
            let lines = output.events.compactMap { try? encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
            try? (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("events.jsonl"),
                                                               atomically: true, encoding: .utf8)
        }
    }

    /// A fake running night for the night screen (no audio is captured).
    @MainActor
    static func showNightScreen(_ controller: SessionController) {
        let now = Date()
        let latest = AppSettings.nextWakeDate(hour: 6, minute: 45, from: now)
        controller.current = SessionMeta(id: "demo-night", startDate: now, latestWake: latest, windowMinutes: 30, mode: .smart)
        controller.liveLevel = 6
        controller.liveLabel = "breathing"
        controller.phase = .tracking
    }
}
