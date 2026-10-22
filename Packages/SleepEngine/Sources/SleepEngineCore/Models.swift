import Foundation

/// Groups of sound events shown to the user.
public enum SoundGroup: String, Codable, CaseIterable, Sendable {
    case snore, talk, cough, environment, loud

    /// Lower value = higher priority when several groups fire at once.
    public var priority: Int {
        switch self {
        case .talk: return 0
        case .cough: return 1
        case .snore: return 2
        case .environment: return 3
        case .loud: return 4
        }
    }
}

public enum SleepStage: Int, Codable, CaseIterable, Sendable {
    case wake = 0, light = 1, deep = 2, rem = 3

    /// 0 = awake … 1 = deep. Used for the sleep-depth curve.
    public var depthTarget: Float {
        switch self {
        case .wake: return 0.05
        case .rem: return 0.45
        case .light: return 0.55
        case .deep: return 0.95
        }
    }
}

public enum WakeReason: String, Codable, Sendable {
    case smartLightSleep, awakeDetected, deadline, manualStop, backupFired, none
}

public enum Sensitivity: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    var confidenceShift: Float {
        switch self { case .low: return 0.1; case .medium: return 0; case .high: return -0.1 }
    }
    var decibelShift: Float {
        switch self { case .low: return 3; case .medium: return 0; case .high: return -3 }
    }
}

/// One second of analysed audio. `t` is seconds since session start (wall clock).
public struct FrameFeatures: Equatable, Sendable {
    public var t: Double
    public var levelDb: Float
    public var peakDb: Float
    public var noiseFloorDb: Float
    /// Band energies in dB: 60–250 Hz, 250–1000 Hz, 1–4 kHz, 4–8 kHz.
    public var bandLow: Float
    public var bandMid: Float
    public var bandHigh: Float
    public var bandAir: Float
    /// Spectral flatness 0 (tonal) … 1 (white noise), 250 Hz – 8 kHz.
    public var flatness: Float
    /// Mean normalised positive spectral flux.
    public var flux: Float
    /// Number of transient onsets in this second.
    public var onsets: Float
    /// 4 Hz envelope (dB) of the 100–1500 Hz band – used for breathing analysis.
    public var env: [Float]
    /// Classifier group confidences (max over windows overlapping this second).
    public var snore: Float
    public var talk: Float
    public var cough: Float
    public var breathing: Float
    public var environment: Float
    /// bit 0: our own pre-alarm sound was playing.
    public var flags: UInt8

    public init(t: Double = 0, levelDb: Float = -90, peakDb: Float = -90, noiseFloorDb: Float = -90,
                bandLow: Float = -90, bandMid: Float = -90, bandHigh: Float = -90, bandAir: Float = -90,
                flatness: Float = 0, flux: Float = 0, onsets: Float = 0, env: [Float] = [-90, -90, -90, -90],
                snore: Float = 0, talk: Float = 0, cough: Float = 0, breathing: Float = 0, environment: Float = 0,
                flags: UInt8 = 0) {
        self.t = t; self.levelDb = levelDb; self.peakDb = peakDb; self.noiseFloorDb = noiseFloorDb
        self.bandLow = bandLow; self.bandMid = bandMid; self.bandHigh = bandHigh; self.bandAir = bandAir
        self.flatness = flatness; self.flux = flux; self.onsets = onsets; self.env = env
        self.snore = snore; self.talk = talk; self.cough = cough; self.breathing = breathing
        self.environment = environment; self.flags = flags
    }

    public var aboveFloorDb: Float { levelDb - noiseFloorDb }
    public var selfPlayback: Bool { flags & 1 != 0 }
    public var maxClassifiedConfidence: Float { max(snore, talk, cough, environment) }

    public func confidence(for group: SoundGroup) -> Float {
        switch group {
        case .snore: return snore
        case .talk: return talk
        case .cough: return cough
        case .environment: return environment
        case .loud: return 0
        }
    }
}

public struct SoundEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var group: SoundGroup
    public var label: String
    public var start: Double
    public var end: Double
    public var peakDb: Float
    public var meanConfidence: Float
    public var clipFile: String?
    public var waveform: [Float]

    public init(id: UUID = UUID(), group: SoundGroup, label: String = "", start: Double, end: Double,
                peakDb: Float, meanConfidence: Float, clipFile: String? = nil, waveform: [Float] = []) {
        self.id = id; self.group = group; self.label = label; self.start = start; self.end = end
        self.peakDb = peakDb; self.meanConfidence = meanConfidence; self.clipFile = clipFile; self.waveform = waveform
    }

    public var duration: Double { end - start }
}

/// User corrections, stored separately so raw detections stay untouched.
public struct EventEdit: Codable, Equatable, Sendable {
    public var userGroup: SoundGroup?
    public var isFalseDetection: Bool
    public var favorite: Bool
    public var deleted: Bool

    public init(userGroup: SoundGroup? = nil, isFalseDetection: Bool = false, favorite: Bool = false, deleted: Bool = false) {
        self.userGroup = userGroup; self.isFalseDetection = isFalseDetection; self.favorite = favorite; self.deleted = deleted
    }
}

public extension Array where Element == SoundEvent {
    /// Applies user edits: drops deleted/false detections and re-groups corrected events.
    func applying(_ edits: [String: EventEdit]) -> [SoundEvent] {
        compactMap { event in
            guard let edit = edits[event.id.uuidString] else { return event }
            if edit.deleted || edit.isFalseDetection { return nil }
            var e = event
            if let g = edit.userGroup { e.group = g }
            return e
        }
    }
}

public struct EpochFeatures: Codable, Equatable, Sendable {
    public var index: Int
    public var start: Double
    public var frameCount: Int
    public var gap: Bool
    public var movementSeconds: Int
    public var movementCount: Int
    public var movementEnergy: Float
    public var talkSeconds: Int
    public var snoreSeconds: Int
    public var coughCount: Int
    public var environmentSeconds: Int
    public var meanAboveFloorDb: Float
    public var maxAboveFloorDb: Float
    public var breathRate: Float?
    public var breathRegularity: Float?
    public var breathRateVar: Float?

    public init(index: Int, start: Double) {
        self.index = index; self.start = start; frameCount = 0; gap = true
        movementSeconds = 0; movementCount = 0; movementEnergy = 0; talkSeconds = 0; snoreSeconds = 0
        coughCount = 0; environmentSeconds = 0; meanAboveFloorDb = 0; maxAboveFloorDb = 0
        breathRate = nil; breathRegularity = nil; breathRateVar = nil
    }
}

public struct DataGap: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var reason: String
    public init(start: Double, end: Double, reason: String) { self.start = start; self.end = end; self.reason = reason }
}

public struct SleepSummary: Codable, Equatable, Sendable {
    public var timeInBed: Double = 0
    public var asleep: Double = 0
    public var onset: Double?
    public var finalWake: Double?
    public var awakenings: Int = 0
    public var wakeSeconds: Double = 0
    public var lightSeconds: Double = 0
    public var deepSeconds: Double = 0
    public var remSeconds: Double = 0
    public var quality: Int = 0
    public var snoreSeconds: Double = 0
    public var snoreEpisodes: Int = 0
    public var talkCount: Int = 0
    public var coughCount: Int = 0
    public var environmentCount: Int = 0
    public var loudCount: Int = 0
    public var meanBreathRate: Float?
    public var gapSeconds: Double = 0
    public var movementsPerHour: Double = 0

    public init() {}

    public var latency: Double? { onset }
    public var analysedSeconds: Double { wakeSeconds + lightSeconds + deepSeconds + remSeconds }
}

public struct NightAnalysis: Codable, Equatable, Sendable {
    public static let epochLength: Double = 30
    public var epochs: [EpochFeatures]
    public var stages: [SleepStage]
    public var z: [Float]
    public var depth: [Float]
    public var summary: SleepSummary
    public var engineVersion: Int

    public init(epochs: [EpochFeatures], stages: [SleepStage], z: [Float], depth: [Float], summary: SleepSummary, engineVersion: Int) {
        self.epochs = epochs; self.stages = stages; self.z = z; self.depth = depth; self.summary = summary; self.engineVersion = engineVersion
    }
}

/// Compact per-epoch state used by the live wake-up logic.
public struct LiveEpoch: Equatable, Sendable {
    public var stage: SleepStage
    public var movementSeconds: Int
    public var movementCount: Int
    public var z: Float
    public var environmentSeconds: Int
    public var gap: Bool

    public init(stage: SleepStage, movementSeconds: Int, movementCount: Int, z: Float, environmentSeconds: Int, gap: Bool) {
        self.stage = stage; self.movementSeconds = movementSeconds; self.movementCount = movementCount
        self.z = z; self.environmentSeconds = environmentSeconds; self.gap = gap
    }
}
