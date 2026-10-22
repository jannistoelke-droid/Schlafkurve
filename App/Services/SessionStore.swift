import AVFoundation
import Foundation
import Observation
import SleepEngineCore

/// File layout of one night: Application Support/Sessions/<id>/
///   session.json · frames.bin · events.jsonl · edits.json · analysis.json · eventlog.jsonl · clips/ · night.m4a
enum SessionFiles {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sessions", isDirectory: true)
    }

    static var exportsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Exports", isDirectory: true)
    }

    static func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    static func makeID(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return f.string(from: date) + "_" + String(UUID().uuidString.prefix(4))
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()

    static func writeMeta(_ meta: SessionMeta) {
        let url = folder(meta.id).appendingPathComponent("session.json")
        if let data = try? encoder.encode(meta) { try? data.write(to: url, options: .atomic) }
    }

    static func readMeta(_ id: String) -> SessionMeta? {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent("session.json")) else { return nil }
        return try? decoder.decode(SessionMeta.self, from: data)
    }

    static func readEvents(_ id: String) -> [SoundEvent] {
        guard let text = try? String(contentsOf: folder(id).appendingPathComponent("events.jsonl"), encoding: .utf8) else { return [] }
        let d = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? d.decode(SoundEvent.self, from: Data($0.utf8)) }
    }

    static func readEdits(_ id: String) -> [String: EventEdit] {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent("edits.json")) else { return [:] }
        return (try? decoder.decode([String: EventEdit].self, from: data)) ?? [:]
    }

    static func writeEdits(_ edits: [String: EventEdit], id: String) {
        if let data = try? encoder.encode(edits) {
            try? data.write(to: folder(id).appendingPathComponent("edits.json"), options: .atomic)
        }
    }

    static func readAnalysis(_ id: String) -> NightAnalysis? {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent("analysis.json")) else { return nil }
        return try? decoder.decode(NightAnalysis.self, from: data)
    }

    static func readFrames(_ id: String) -> [FrameFeatures] {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent("frames.bin")),
              let decoded = try? FrameCodec.decode(data) else { return [] }
        return decoded.frames
    }

    /// Full-night analysis from the files on disk (off the main thread).
    static func analyze(id: String, timeInBed: Double, goalSeconds: Double) -> NightAnalysis {
        let frames = readFrames(id)
        let events = readEvents(id).applying(readEdits(id))
        let duration = max(timeInBed, (frames.last?.t ?? 0) + 1)
        let analysis = NightAnalyzer.analyze(frames: frames, events: events, timeInBed: duration, goalSeconds: goalSeconds)
        if let data = try? encoder.encode(analysis) {
            try? data.write(to: folder(id).appendingPathComponent("analysis.json"), options: .atomic)
        }
        return analysis
    }

    static func zip(folder: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinatorError) { zipURL in
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let e = coordinatorError { throw e }
        if let e = copyError { throw e }
    }
}

struct SessionDetail {
    var meta: SessionMeta
    var analysis: NightAnalysis?
    var rawEvents: [SoundEvent]
    var edits: [String: EventEdit]

    var events: [SoundEvent] {
        rawEvents.compactMap { e in
            let edit = edits[e.id.uuidString]
            if edit?.deleted == true { return nil }
            var copy = e
            if let g = edit?.userGroup { copy.group = g }
            return copy
        }
    }

    func edit(for id: UUID) -> EventEdit { edits[id.uuidString] ?? EventEdit() }

    func clipURL(_ event: SoundEvent) -> URL? {
        event.clipFile.map { SessionFiles.folder(meta.id).appendingPathComponent($0) }
    }
}

@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [SessionMeta] = []
    var isBusy = false

    init() {
        try? FileManager.default.createDirectory(at: SessionFiles.root, withIntermediateDirectories: true)
        reload()
    }

    var finishedSessions: [SessionMeta] { sessions.filter { $0.isFinished && !$0.isTest } }

    func reload() {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: SessionFiles.root.path)) ?? []
        sessions = ids.compactMap { SessionFiles.readMeta($0) }.sorted { $0.startDate > $1.startDate }
    }

    func save(_ meta: SessionMeta) {
        SessionFiles.writeMeta(meta)
        if let i = sessions.firstIndex(where: { $0.id == meta.id }) {
            sessions[i] = meta
        } else {
            sessions.insert(meta, at: 0)
            sessions.sort { $0.startDate > $1.startDate }
        }
    }

    func detail(_ id: String) -> SessionDetail? {
        guard let meta = sessions.first(where: { $0.id == id }) ?? SessionFiles.readMeta(id) else { return nil }
        return SessionDetail(meta: meta, analysis: SessionFiles.readAnalysis(id), rawEvents: SessionFiles.readEvents(id),
                             edits: SessionFiles.readEdits(id))
    }

    func updateEdit(sessionID: String, eventID: UUID, _ change: (inout EventEdit) -> Void) {
        var edits = SessionFiles.readEdits(sessionID)
        var edit = edits[eventID.uuidString] ?? EventEdit()
        change(&edit)
        edits[eventID.uuidString] = edit
        SessionFiles.writeEdits(edits, id: sessionID)
    }

    /// Recomputes the summary after edits (counts change when events are re-grouped).
    func refreshSummary(_ id: String) async {
        guard var meta = sessions.first(where: { $0.id == id }), let end = meta.endDate else { return }
        let bed = end.timeIntervalSince(meta.startDate)
        let goal = AppSettings.sleepGoalHours * 3600
        let analysis = await Task.detached { SessionFiles.analyze(id: id, timeInBed: bed, goalSeconds: goal) }.value
        meta.summary = analysis.summary
        save(meta)
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: SessionFiles.folder(id))
        sessions.removeAll { $0.id == id }
    }

    func export(_ id: String) throws -> URL {
        try FileManager.default.createDirectory(at: SessionFiles.exportsFolder, withIntermediateDirectories: true)
        let target = SessionFiles.exportsFolder.appendingPathComponent("Schlafkurve_\(id).zip")
        try SessionFiles.zip(folder: SessionFiles.folder(id), to: target)
        return target
    }

    func exportAll() throws -> URL {
        try FileManager.default.createDirectory(at: SessionFiles.exportsFolder, withIntermediateDirectories: true)
        let target = SessionFiles.exportsFolder.appendingPathComponent("Schlafkurve_alle_Naechte.zip")
        try SessionFiles.zip(folder: SessionFiles.root, to: target)
        return target
    }

    func reanalyzeAll() async {
        isBusy = true
        let goal = AppSettings.sleepGoalHours * 3600
        for var meta in sessions where meta.isFinished {
            let id = meta.id
            let bed = (meta.endDate ?? meta.startDate).timeIntervalSince(meta.startDate)
            let analysis = await Task.detached { SessionFiles.analyze(id: id, timeInBed: bed, goalSeconds: goal) }.value
            meta.summary = analysis.summary
            save(meta)
        }
        isBusy = false
    }

    /// Sessions that never got an end (app killed during the night) are closed and analysed.
    func recoverUnfinished(excluding currentID: String?) async -> [String] {
        var recovered: [String] = []
        let goal = AppSettings.sleepGoalHours * 3600
        for var meta in sessions where !meta.isFinished && meta.id != currentID {
            let id = meta.id
            let lastT = await Task.detached { SessionFiles.readFrames(id).last?.t ?? 0 }.value
            let end = meta.startDate.addingTimeInterval(lastT + 1)
            meta.endDate = end
            if meta.wakeReason == nil { meta.wakeReason = meta.mode == .trackingOnly ? WakeReason.none : .backupFired }
            meta.gaps.append(DataGap(start: lastT + 1, end: lastT + 1, reason: "app_beendet"))
            let bed = end.timeIntervalSince(meta.startDate)
            let analysis = await Task.detached { SessionFiles.analyze(id: id, timeInBed: bed, goalSeconds: goal) }.value
            meta.summary = analysis.summary
            save(meta)
            recovered.append(id)
        }
        return recovered
    }

    /// Deletes old clips (favourites stay). frames.bin and events are always kept.
    func applyRetention() {
        let days = AppSettings.clipRetentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for meta in sessions where meta.startDate < cutoff {
            let edits = SessionFiles.readEdits(meta.id)
            let keep = Set(SessionFiles.readEvents(meta.id).filter { edits[$0.id.uuidString]?.favorite == true }.compactMap(\.clipFile))
            let clipsDir = SessionFiles.folder(meta.id).appendingPathComponent("clips")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: clipsDir.path)) ?? []
            for f in files where !keep.contains("clips/" + f) {
                try? FileManager.default.removeItem(at: clipsDir.appendingPathComponent(f))
            }
        }
    }
}

/// Plays one clip at a time. Only used while no night session is running.
@MainActor
@Observable
final class ClipPlayer {
    static let shared = ClipPlayer()

    private(set) var playingID: UUID?
    private(set) var progress: Double = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    func toggle(id: UUID, url: URL) {
        if playingID == id {
            stop()
            return
        }
        stop()
        guard SessionController.shared.phase == .idle else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.play()
            player = p
            playingID = id
            progress = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                Task { @MainActor in ClipPlayer.shared.tick() }
            }
        } catch {
            playingID = nil
        }
    }

    private func tick() {
        guard let p = player else { return }
        if !p.isPlaying {
            stop()
            return
        }
        progress = p.duration > 0 ? p.currentTime / p.duration : 0
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playingID = nil
        progress = 0
    }
}
