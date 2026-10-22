import Foundation

/// Deterministic random numbers (identical on every platform).
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    public mutating func gaussian() -> Float {
        let u1 = max(unit(), 1e-6)
        let u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * Float.pi * u2)
    }
}

/// Feature-level synthetic nights for tests, demo reports and screenshots.
public struct SyntheticNight: Sendable {
    public struct Segment: Sendable {
        public var stage: SleepStage
        public var minutes: Double
        public var snoring: Bool
        public init(_ stage: SleepStage, _ minutes: Double, snoring: Bool = false) {
            self.stage = stage; self.minutes = minutes; self.snoring = snoring
        }
    }

    public var segments: [Segment]
    public var seed: UInt64

    public init(segments: [Segment], seed: UInt64 = 42) {
        self.segments = segments
        self.seed = seed
    }

    /// A typical 7.5 h night with four cycles, snoring and a short awakening.
    public static let typical = SyntheticNight(segments: [
        Segment(.wake, 15), Segment(.light, 15), Segment(.deep, 45), Segment(.light, 20), Segment(.rem, 15),
        Segment(.light, 25), Segment(.deep, 35), Segment(.light, 20, snoring: true), Segment(.rem, 20),
        Segment(.wake, 3), Segment(.light, 30), Segment(.deep, 20), Segment(.light, 25), Segment(.rem, 25),
        Segment(.light, 20, snoring: true), Segment(.rem, 25), Segment(.light, 15), Segment(.wake, 5),
    ])

    public static let restless = SyntheticNight(segments: [
        Segment(.wake, 35), Segment(.light, 30), Segment(.deep, 25), Segment(.light, 30), Segment(.wake, 12),
        Segment(.light, 40), Segment(.rem, 15), Segment(.light, 30), Segment(.wake, 20), Segment(.light, 45),
        Segment(.rem, 20), Segment(.light, 25), Segment(.wake, 6),
    ], seed: 7)

    public var totalSeconds: Double { segments.reduce(0) { $0 + $1.minutes * 60 } }

    public struct Output: Sendable {
        public var frames: [FrameFeatures]
        public var events: [SoundEvent]
        public var truth: [SleepStage]   // per second
    }

    public func generate() -> Output {
        var rng = SeededRandom(seed: seed)
        var frames: [FrameFeatures] = []
        var truth: [SleepStage] = []
        let floor: Float = -62
        var t = 0.0
        var phase: Float = 0
        var period: Float = 4
        var movementLeft = 0

        for seg in segments {
            let seconds = Int(seg.minutes * 60)
            for _ in 0..<seconds {
                var f = FrameFeatures(t: t)
                f.noiseFloorDb = floor
                f.levelDb = floor + 1 + rng.gaussian() * 0.5
                f.peakDb = f.levelDb + 8
                f.flatness = 0.18 + rng.unit() * 0.05
                f.flux = 0.05

                // breathing envelope
                var amplitude: Float
                switch seg.stage {
                case .deep:
                    period = 4.2 + rng.gaussian() * 0.03
                    amplitude = 3
                case .light:
                    period = max(3, min(5, period + rng.gaussian() * 0.15))
                    amplitude = 2.2
                case .rem:
                    period = max(2.6, min(5.8, period + rng.gaussian() * 0.35))
                    amplitude = 1.5 + rng.unit() * 2
                case .wake:
                    period = max(2.5, min(5, period + rng.gaussian() * 0.3))
                    amplitude = 1.2
                }
                if seg.snoring { amplitude = 8 }
                var env: [Float] = []
                for _ in 0..<4 {
                    phase += 0.25 / period
                    env.append(floor - 8 + amplitude * sin(2 * Float.pi * phase) + rng.gaussian() * 0.4)
                }
                f.env = env

                // movement bursts
                if movementLeft == 0 {
                    let p: Float
                    switch seg.stage {
                    case .wake: p = 0.12
                    case .light: p = 1.0 / 240
                    case .rem: p = 1.0 / 2400
                    case .deep: p = 0
                    }
                    if rng.unit() < p {
                        movementLeft = seg.stage == .wake ? 3 + Int(rng.unit() * 6) : 1 + Int(rng.unit() * 3)
                    }
                }
                if movementLeft > 0 {
                    movementLeft -= 1
                    f.levelDb = floor + 10 + rng.unit() * 6
                    f.peakDb = f.levelDb + 10
                    f.flatness = 0.45 + rng.unit() * 0.15
                    f.onsets = 2
                    f.flux = 0.3
                }
                if seg.snoring {
                    f.snore = 0.75 + rng.unit() * 0.2
                    f.levelDb = max(f.levelDb, floor + 14)
                    f.flatness = 0.12
                }
                f.breathing = seg.stage == .wake ? 0.1 : 0.3
                frames.append(f)
                truth.append(seg.stage)
                t += 1
            }
        }

        // a few sound events for demo reports
        var events: [SoundEvent] = []
        var segStart = 0.0
        for seg in segments {
            let length = seg.minutes * 60
            if seg.snoring {
                var s = segStart + 20
                while s + 25 < segStart + length {
                    events.append(SoundEvent(group: .snore, label: "snoring", start: s, end: s + 18,
                                             peakDb: -40, meanConfidence: 0.8, waveform: Self.demoWaveform(&rng)))
                    s += 45
                }
            }
            segStart += length
        }
        let total = totalSeconds
        events.append(SoundEvent(group: .talk, label: "speech", start: total * 0.55, end: total * 0.55 + 6,
                                 peakDb: -35, meanConfidence: 0.72, waveform: Self.demoWaveform(&rng)))
        events.append(SoundEvent(group: .cough, label: "cough", start: total * 0.3, end: total * 0.3 + 2,
                                 peakDb: -30, meanConfidence: 0.8, waveform: Self.demoWaveform(&rng)))
        events.append(SoundEvent(group: .environment, label: "dog_bark", start: total * 0.8, end: total * 0.8 + 4,
                                 peakDb: -38, meanConfidence: 0.75, waveform: Self.demoWaveform(&rng)))
        events.sort { $0.start < $1.start }
        return Output(frames: frames, events: events, truth: truth)
    }

    static func demoWaveform(_ rng: inout SeededRandom) -> [Float] {
        (0..<64).map { i in
            let x = Float(i) / 63
            return min(1, max(0.05, sin(Float.pi * x) * (0.5 + rng.unit() * 0.5)))
        }
    }
}
