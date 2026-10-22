import Foundation

public enum QualityScorer {
    public static func score(_ s: SleepSummary, goalSeconds: Double, tuning: Tuning.Quality = Tuning.standard.quality) -> Int {
        guard s.analysedSeconds > 0 else { return 0 }
        let duration = min(max(s.asleep / max(goalSeconds, 1), 0), 1) * tuning.durationWeight
        let deepShare = s.asleep > 0 ? s.deepSeconds / s.asleep : 0
        let deep = min(max(deepShare / tuning.targetDeepShare, 0), 1) * tuning.deepWeight
        let continuity = min(max(1 - Double(s.awakenings) / tuning.awakeningsForZero, 0), 1) * tuning.continuityWeight
        let calm = min(max(1 - s.movementsPerHour / tuning.movementsPerHourForZero, 0), 1) * tuning.calmWeight
        let latencyMinutes = (s.onset ?? 3600) / 60
        let latencyFactor = latencyMinutes <= 15 ? 1.0 : (latencyMinutes <= 30 ? 0.6 : 0.3)
        let total = duration + deep + continuity + calm + latencyFactor * tuning.latencyWeight
        return Int(total.rounded())
    }
}

public enum NightAnalyzer {
    /// Full-night analysis (non-causal). Used after the alarm, for re-analysis and by sleepreplay.
    public static func analyze(frames: [FrameFeatures], events: [SoundEvent], timeInBed: Double,
                               goalSeconds: Double = 8 * 3600, tuning: Tuning = .standard) -> NightAnalysis {
        let epochs = EpochBuilder.build(frames: frames, duration: timeInBed, tuning: tuning)
        let result = Stager.stage(epochs, tuning: tuning.staging, causal: false)
        let length = tuning.staging.epochLength
        var s = SleepSummary()
        s.timeInBed = timeInBed

        for (i, e) in epochs.enumerated() {
            if e.gap { s.gapSeconds += length; continue }
            switch result.stages[i] {
            case .wake: s.wakeSeconds += length
            case .light: s.lightSeconds += length
            case .deep: s.deepSeconds += length
            case .rem: s.remSeconds += length
            }
        }
        if let o = result.onsetIndex {
            s.onset = Double(o) * length
            var lastSleep: Int?
            for i in stride(from: epochs.count - 1, through: o, by: -1) where !epochs[i].gap && result.stages[i] != .wake {
                lastSleep = i
                break
            }
            if let l = lastSleep {
                s.finalWake = Double(l + 1) * length
                var asleep = 0.0
                var awakenings = 0
                var wakeRun = 0
                for i in o...l {
                    if epochs[i].gap { continue }
                    if result.stages[i] == .wake {
                        wakeRun += 1
                    } else {
                        if wakeRun >= 2 { awakenings += 1 }
                        wakeRun = 0
                        asleep += length
                    }
                }
                s.asleep = asleep
                s.awakenings = awakenings
            }
        }

        let sorted = events.sorted { $0.start < $1.start }
        var lastSnoreEnd: Double?
        for e in sorted {
            switch e.group {
            case .snore:
                s.snoreSeconds += e.duration
                if let last = lastSnoreEnd, e.start - last <= tuning.events.snoreEpisodeGap {
                    // same episode
                } else {
                    s.snoreEpisodes += 1
                }
                lastSnoreEnd = e.end
            case .talk: s.talkCount += 1
            case .cough: s.coughCount += 1
            case .environment: s.environmentCount += 1
            case .loud: s.loudCount += 1
            }
        }
        let rates = epochs.compactMap { $0.breathRate }
        if rates.count >= 10 { s.meanBreathRate = rates.reduce(0, +) / Float(rates.count) }
        let validHours = s.analysedSeconds / 3600
        let movements = epochs.reduce(0) { $0 + ($1.gap ? 0 : $1.movementCount) }
        s.movementsPerHour = validHours > 0 ? Double(movements) / validHours : 0
        s.quality = QualityScorer.score(s, goalSeconds: goalSeconds, tuning: tuning.quality)

        return NightAnalysis(epochs: epochs, stages: result.stages, z: result.z, depth: result.depth,
                             summary: s, engineVersion: Tuning.engineVersion)
    }
}

/// Binary per-second feature log (`frames.bin`). Little-endian, versioned.
public enum FrameCodec {
    public static let magic: [UInt8] = [0x53, 0x4B, 0x46, 0x31] // "SKF1"
    public static let version: UInt16 = 1
    public static let fieldCount = 24
    public static let headerSize = 16
    public static var recordSize: Int { fieldCount * 4 }

    public enum CodecError: Error { case badHeader, unsupportedVersion }

    public static func header(startDate: Date) -> Data {
        var d = Data(magic)
        appendUInt16(version, to: &d)
        appendUInt16(UInt16(fieldCount), to: &d)
        appendUInt64(startDate.timeIntervalSince1970.bitPattern, to: &d)
        return d
    }

    public static func encode(_ f: FrameFeatures) -> Data {
        var values = [Float](repeating: 0, count: fieldCount)
        values[0] = Float(f.t)
        values[1] = f.levelDb
        values[2] = f.peakDb
        values[3] = f.noiseFloorDb
        values[4] = f.bandLow
        values[5] = f.bandMid
        values[6] = f.bandHigh
        values[7] = f.bandAir
        values[8] = f.flatness
        values[9] = f.flux
        values[10] = f.onsets
        for k in 0..<4 { values[11 + k] = k < f.env.count ? f.env[k] : -90 }
        values[15] = f.snore
        values[16] = f.talk
        values[17] = f.cough
        values[18] = f.breathing
        values[19] = f.environment
        values[20] = Float(f.flags)
        var d = Data(capacity: recordSize)
        for v in values { appendUInt32(v.bitPattern, to: &d) }
        return d
    }

    public static func decode(_ data: Data) throws -> (startDate: Date, frames: [FrameFeatures]) {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize, Array(bytes[0..<4]) == magic else { throw CodecError.badHeader }
        let v = readUInt16(bytes, 4)
        guard v == version else { throw CodecError.unsupportedVersion }
        let fields = Int(readUInt16(bytes, 6))
        let start = Date(timeIntervalSince1970: Double(bitPattern: readUInt64(bytes, 8)))
        let size = fields * 4
        guard size > 0 else { throw CodecError.badHeader }
        var frames: [FrameFeatures] = []
        frames.reserveCapacity((bytes.count - headerSize) / size)
        var offset = headerSize
        while offset + size <= bytes.count {
            var values = [Float](repeating: 0, count: max(fields, fieldCount))
            for k in 0..<fields { values[k] = Float(bitPattern: readUInt32(bytes, offset + k * 4)) }
            var f = FrameFeatures()
            f.t = Double(values[0])
            f.levelDb = values[1]
            f.peakDb = values[2]
            f.noiseFloorDb = values[3]
            f.bandLow = values[4]
            f.bandMid = values[5]
            f.bandHigh = values[6]
            f.bandAir = values[7]
            f.flatness = values[8]
            f.flux = values[9]
            f.onsets = values[10]
            f.env = [values[11], values[12], values[13], values[14]]
            f.snore = values[15]
            f.talk = values[16]
            f.cough = values[17]
            f.breathing = values[18]
            f.environment = values[19]
            f.flags = UInt8(max(0, min(255, values[20])))
            frames.append(f)
            offset += size
        }
        return (start, frames)
    }

    private static func appendUInt16(_ v: UInt16, to d: inout Data) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8))
    }
    private static func appendUInt32(_ v: UInt32, to d: inout Data) {
        for k in 0..<4 { d.append(UInt8((v >> (8 * UInt32(k))) & 0xFF)) }
    }
    private static func appendUInt64(_ v: UInt64, to d: inout Data) {
        for k in 0..<8 { d.append(UInt8((v >> (8 * UInt64(k))) & 0xFF)) }
    }
    private static func readUInt16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | (UInt16(b[o + 1]) << 8) }
    private static func readUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(b[o + k]) << (8 * UInt32(k)) }
        return v
    }
    private static func readUInt64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[o + k]) << (8 * UInt64(k)) }
        return v
    }
}

/// Append-only writer for frames.bin (crash-safe: flushes every `flushEvery` frames).
public final class FrameWriter {
    private let handle: FileHandle
    private var buffer = Data()
    private var pending = 0
    private let flushEvery: Int
    public private(set) var written = 0

    public init(url: URL, startDate: Date, flushEvery: Int = 60) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: FrameCodec.header(startDate: startDate))
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.flushEvery = flushEvery
    }

    public func append(_ f: FrameFeatures) {
        buffer.append(FrameCodec.encode(f))
        pending += 1
        written += 1
        if pending >= flushEvery { flush() }
    }

    public func flush() {
        guard !buffer.isEmpty else { return }
        try? handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
        pending = 0
    }

    public func close() {
        flush()
        try? handle.close()
    }
}
