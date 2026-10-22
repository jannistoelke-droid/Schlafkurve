import AVFoundation
import Foundation

/// Keeps the last 30 s of 16 kHz audio in memory and writes AAC clips with pre-roll.
/// All methods are called on the pipeline queue.
final class ClipRecorder {
    struct Finished {
        let id: UUID
        let fileName: String
        let waveform: [Float]
    }

    private final class Clip {
        let id: UUID
        let url: URL
        var file: AVAudioFile?
        var cursor: Int64
        var stopAt: Int64?
        var peaks: [Float] = []
        var chunkPeak: Float = 0
        var chunkCount = 0
        init(id: UUID, url: URL, file: AVAudioFile, cursor: Int64) {
            self.id = id; self.url = url; self.file = file; self.cursor = cursor
        }
    }

    let format: AVAudioFormat
    private let sampleRate: Int64
    private let capacity: Int
    private var ring: [Float]
    private var total: Int64 = 0
    private var clips: [Clip] = []
    var onFinished: ((Finished) -> Void)?
    var onError: ((String) -> Void)?

    init(format: AVAudioFormat, ringSeconds: Double) {
        self.format = format
        sampleRate = Int64(format.sampleRate)
        capacity = Int(format.sampleRate * ringSeconds)
        ring = [Float](repeating: 0, count: capacity)
    }

    func isActive(_ id: UUID) -> Bool { clips.contains { $0.id == id } }

    /// Appends samples whose first sample has the absolute stream index `startIndex`.
    func append(_ samples: [Float], startIndex: Int64) {
        for (i, s) in samples.enumerated() {
            ring[Int((startIndex + Int64(i)) % Int64(capacity))] = s
        }
        total = startIndex + Int64(samples.count)
        for clip in clips { write(clip, upTo: total) }
        let done = clips.filter { c in c.stopAt.map { c.cursor >= $0 } ?? false }
        for clip in done { finish(clip) }
    }

    func start(id: UUID, from startIndex: Int64, url: URL) {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let earliest = max(0, total - Int64(capacity) + 1)
            let clip = Clip(id: id, url: url, file: file, cursor: max(startIndex, earliest))
            clips.append(clip)
            write(clip, upTo: total)
        } catch {
            onError?("clip_open_failed \(error)")
        }
    }

    func stop(id: UUID, at index: Int64) {
        guard let clip = clips.first(where: { $0.id == id }) else { return }
        clip.stopAt = index
        if clip.cursor >= index { finish(clip) }
    }

    func cancel(id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = clips.remove(at: i)
        clip.file = nil
        try? FileManager.default.removeItem(at: clip.url)
    }

    /// Ends every running clip at the current position (session end).
    func finishAll() {
        for clip in clips { finish(clip) }
    }

    private func write(_ clip: Clip, upTo end: Int64) {
        let limit = min(end, clip.stopAt ?? end)
        guard clip.cursor < limit, let file = clip.file else { return }
        let count = Int(limit - clip.cursor)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        for k in 0..<count {
            let s = ring[Int((clip.cursor + Int64(k)) % Int64(capacity))]
            channel[k] = s
            clip.chunkPeak = max(clip.chunkPeak, abs(s))
            clip.chunkCount += 1
            if clip.chunkCount >= Int(sampleRate / 10) {
                clip.peaks.append(clip.chunkPeak)
                clip.chunkPeak = 0
                clip.chunkCount = 0
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        do {
            try file.write(from: buffer)
        } catch {
            onError?("clip_write_failed \(error)")
        }
        clip.cursor = limit
    }

    private func finish(_ clip: Clip) {
        guard let i = clips.firstIndex(where: { $0 === clip }) else { return }
        clips.remove(at: i)
        if clip.chunkCount > 0 { clip.peaks.append(clip.chunkPeak) }
        clip.file = nil // closes and finalises the AAC file
        onFinished?(Finished(id: clip.id, fileName: clip.url.lastPathComponent, waveform: Self.waveform(from: clip.peaks)))
    }

    static func waveform(from peaks: [Float], bins: Int = 64) -> [Float] {
        guard !peaks.isEmpty else { return [] }
        let maxPeak = max(peaks.max() ?? 1, 1e-4)
        return (0..<bins).map { b in
            let from = b * peaks.count / bins
            let to = max(from + 1, (b + 1) * peaks.count / bins)
            let slice = peaks[min(from, peaks.count - 1)..<min(to, peaks.count)]
            return min(1, (slice.max() ?? 0) / maxPeak)
        }
    }
}
