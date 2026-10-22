import Foundation
import OSLog

/// Per-session JSONL event log (`eventlog.jsonl`). It is the only diagnostic the user can
/// export without a Mac, so everything important goes here.
final class DiagnosticsLog {
    private let queue = DispatchQueue(label: "app.schlafkurve.diagnostics", qos: .utility)
    private var handle: FileHandle?
    private let start: Date
    private let logger = Logger(subsystem: "app.schlafkurve", category: "session")
    private let lock = NSLock()
    private var recentLines: [String] = []
    private let iso = ISO8601DateFormatter()

    init(url: URL, start: Date) {
        self.start = start
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func log(_ event: String, _ fields: [String: String] = [:]) {
        let now = Date()
        var object = fields
        object["event"] = event
        object["time"] = iso.string(from: now)
        object["t"] = String(format: "%.1f", now.timeIntervalSince(start))
        logger.info("\(event, privacy: .public) \(fields.description, privacy: .public)")
        let summary = "\(now.formatted(date: .omitted, time: .standard)) \(event) \(fields.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))"
        lock.lock()
        recentLines.append(summary)
        if recentLines.count > 200 { recentLines.removeFirst(recentLines.count - 200) }
        lock.unlock()
        queue.async { [weak self] in
            guard let self, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
            try? self.handle?.write(contentsOf: data + Data("\n".utf8))
        }
    }

    var recent: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recentLines
    }

    func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }
}
