import Foundation
import SleepEngineCore
#if canImport(SoundAnalysis)
import SoundAnalysis
#endif

// sleepreplay – re-run the Schlafkurve engine outside the app.
//   sleepreplay --frames <frames.bin | folder> [--report] [--json <out.json>]
//   sleepreplay --synthetic [typical|restless]
//   sleepreplay --list-labels            (macOS only: SoundAnalysis classifier labels)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func hm(_ seconds: Double?) -> String {
    guard let s = seconds else { return "–" }
    let m = Int(s / 60)
    return String(format: "%dh%02d", m / 60, m % 60)
}

func report(_ name: String, _ a: NightAnalysis) {
    let s = a.summary
    print("== \(name)")
    print("  time in bed \(hm(s.timeInBed))  asleep \(hm(s.asleep))  onset \(hm(s.onset))  final wake \(hm(s.finalWake))  quality \(s.quality)%")
    print("  wake \(hm(s.wakeSeconds))  light \(hm(s.lightSeconds))  deep \(hm(s.deepSeconds))  rem \(hm(s.remSeconds))  gaps \(hm(s.gapSeconds))  awakenings \(s.awakenings)")
    print("  snore \(Int(s.snoreSeconds / 60)) min / \(s.snoreEpisodes) episodes  talk \(s.talkCount)  cough \(s.coughCount)  env \(s.environmentCount)  loud \(s.loudCount)  breath \(s.meanBreathRate.map { String(format: "%.1f/min", $0) } ?? "–")  moves/h \(String(format: "%.1f", s.movementsPerHour))")
    var line = ""
    for (i, st) in a.stages.enumerated() {
        if a.epochs[i].gap { line += "·"; continue }
        switch st {
        case .wake: line += "W"
        case .light: line += "-"
        case .deep: line += "_"
        case .rem: line += "R"
        }
    }
    var i = line.startIndex
    var row = 0
    while i < line.endIndex {
        let end = line.index(i, offsetBy: 120, limitedBy: line.endIndex) ?? line.endIndex
        print("  \(hm(Double(row) * 3600)) " + String(line[i..<end]))
        i = end
        row += 1
    }
}

func loadEvents(near frames: URL) -> [SoundEvent] {
    let dir = frames.deletingLastPathComponent()
    let decoder = JSONDecoder()
    var events: [SoundEvent] = []
    if let text = try? String(contentsOf: dir.appendingPathComponent("events.jsonl"), encoding: .utf8) {
        for line in text.split(separator: "\n") {
            if let e = try? decoder.decode(SoundEvent.self, from: Data(line.utf8)) { events.append(e) }
        }
    }
    if let data = try? Data(contentsOf: dir.appendingPathComponent("edits.json")),
       let edits = try? decoder.decode([String: EventEdit].self, from: data) {
        events = events.applying(edits)
    }
    return events
}

func framesFiles(at path: String) -> [URL] {
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { fail("not found: \(path)") }
    if !isDir.boolValue { return [url] }
    var result: [URL] = []
    if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
        for case let f as URL in e where f.lastPathComponent == "frames.bin" { result.append(f) }
    }
    return result.sorted { $0.path < $1.path }
}

let args = Array(CommandLine.arguments.dropFirst())
func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.contains("--list-labels") {
    #if canImport(SoundAnalysis)
    do {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        for label in request.knownClassifications.sorted() { print(label) }
    } catch {
        fail("SoundAnalysis error: \(error)")
    }
    #else
    fail("--list-labels needs macOS (SoundAnalysis)")
    #endif
} else if args.contains("--synthetic") {
    let which = value(after: "--synthetic") ?? "typical"
    let night = which == "restless" ? SyntheticNight.restless : SyntheticNight.typical
    let out = night.generate()
    report("synthetic \(which)", NightAnalyzer.analyze(frames: out.frames, events: out.events, timeInBed: night.totalSeconds))
} else if let path = value(after: "--frames") {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for file in framesFiles(at: path) {
        guard let data = try? Data(contentsOf: file), let decoded = try? FrameCodec.decode(data) else {
            print("skip (unreadable): \(file.path)")
            continue
        }
        let events = loadEvents(near: file)
        let duration = (decoded.frames.last?.t ?? 0) + 1
        let analysis = NightAnalyzer.analyze(frames: decoded.frames, events: events, timeInBed: duration)
        report(file.deletingLastPathComponent().lastPathComponent, analysis)
        if let out = value(after: "--json"), let json = try? encoder.encode(analysis) {
            let target = framesFiles(at: path).count > 1
                ? URL(fileURLWithPath: out).appendingPathComponent(file.deletingLastPathComponent().lastPathComponent + ".json")
                : URL(fileURLWithPath: out)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? json.write(to: target)
        }
    }
} else {
    print("usage: sleepreplay --frames <frames.bin|folder> [--json out] | --synthetic [typical|restless] | --list-labels")
}
