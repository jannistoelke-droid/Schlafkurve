import Foundation

/// Every threshold and weight of the engine lives here (CLAUDE.md rule 5).
/// Changes made during /night-review get a dated comment.
public struct Tuning: Sendable {
    public static let engineVersion = 1
    public static let standard = Tuning()

    public var events = Events()
    public var clips = Clips()
    public var movement = Movement()
    public var breathing = Breathing()
    public var staging = Staging()
    public var wake = Wake()
    public var quality = Quality()

    public init() {}

    public struct GroupParams: Sendable {
        public var start: Float          // confidence needed to start
        public var keep: Float           // confidence needed to continue
        public var startFrames: Int      // consecutive seconds above `start`
        public var minDuration: Double   // shorter events are discarded
        public var endAfter: Double      // seconds below `keep` that end the event
        public var maxDuration: Double   // events are split after this
    }

    public struct Events: Sendable {
        public var snore = GroupParams(start: 0.55, keep: 0.35, startFrames: 2, minDuration: 4, endAfter: 4, maxDuration: 30)
        public var talk = GroupParams(start: 0.60, keep: 0.40, startFrames: 1, minDuration: 1, endAfter: 2, maxDuration: 60)
        public var cough = GroupParams(start: 0.60, keep: 0.40, startFrames: 1, minDuration: 1, endAfter: 1, maxDuration: 10)
        public var environment = GroupParams(start: 0.70, keep: 0.50, startFrames: 2, minDuration: 2, endAfter: 2, maxDuration: 20)
        public var loud = GroupParams(start: 1, keep: 1, startFrames: 1, minDuration: 1, endAfter: 1, maxDuration: 10)
        /// A frame only counts if it is this many dB above the noise floor.
        public var minAboveFloorDb: Float = 6
        /// Unclassified sounds this far above the floor become "loud" events.
        public var loudAboveFloorDb: Float = 18
        /// "Loud" requires that no classifier group is more confident than this.
        public var loudMaxClassifiedConfidence: Float = 0.3
        /// Snore events closer than this are merged into one episode.
        public var snoreEpisodeGap: Double = 30

        public func params(_ g: SoundGroup) -> GroupParams {
            switch g {
            case .snore: return snore
            case .talk: return talk
            case .cough: return cough
            case .environment: return environment
            case .loud: return loud
            }
        }
    }

    public struct Clips: Sendable {
        public var preRoll: Double = 3
        public var postRoll: Double = 2
        public var snoreClipsPerBlock = 2
        public var snoreBlockSeconds: Double = 900
        public var ringSeconds: Double = 30
    }

    public struct Movement: Sendable {
        public var minFlatness: Float = 0.3
        public var minAboveFloorDb: Float = 6
        public var maxClassifiedConfidence: Float = 0.4
    }

    public struct Breathing: Sendable {
        public var envelopeRate: Float = 4
        public var windowSeconds: Double = 60
        public var minPeriod: Float = 2.0
        public var maxPeriod: Float = 7.0
        public var minModulationDb: Float = 0.8
        public var minRegularity: Float = 0.2
        public var maxMovementSeconds = 12
        public var varianceEpochs = 5
    }

    public struct Staging: Sendable {
        public var epochLength: Double = 30
        public var minFramesPerEpoch = 20
        // activity a = log1p(w1*energy + w2*movementSeconds + w3*talkSeconds)
        public var energyWeight: Float = 0.05
        public var movementWeight: Float = 0.5
        public var talkWeight: Float = 0.3
        /// Kernel weights for offsets -4…+2 (final) and -6…0 (live).
        public var kernel: [Float] = [0.04, 0.06, 0.10, 0.20, 0.35, 0.15, 0.10]
        public var causalKernel: [Float] = [0.03, 0.04, 0.06, 0.10, 0.17, 0.25, 0.35]
        public var minScale: Float = 0.15
        // wake evidence
        public var wakeZ: Float = 1.0
        public var wakeActivity: Float = 0.8
        public var wakeMovementSeconds = 20
        // sleep onset: first window of `onsetEpochs` with at most `onsetMaxMovingEpochs` moving epochs
        public var onsetEpochs = 20
        public var onsetMaxMovingEpochs = 2
        public var onsetMaxMovementSeconds = 10
        // deep evidence
        public var deepMinStillEpochs = 20
        public var deepRegularity: Float = 0.6
        public var deepMaxRateVar: Float = 1.0
        // REM assignment (final mode)
        public var remMinMinutesAfterOnset: Double = 60
        public var remMinRunEpochs = 10
        public var remMaxMeanMovementSeconds: Float = 1.0
        public var remIrregularity: Float = 0.45
        public var remRateVar: Float = 2.0
        public var remAfterDeepWithinEpochs = 80
        public var remLateNightHours: Double = 3
        // HMM (W, L, D) transition probabilities per epoch, rows sum to 1
        public var transitions: [[Float]] = [
            [0.90, 0.10, 0.00],
            [0.04, 0.91, 0.05],
            [0.01, 0.07, 0.92],
        ]
        public var initial: [Float] = [0.9, 0.1, 0.0]
        public var emissionFloor: Float = 0.02
        public var minDeepRun = 3
        // depth curve
        public var depthStageWeight: Float = 0.75
        public var depthSmoothSigma: Float = 1.5
    }

    public struct Wake: Sendable {
        public var awakeMovementSeconds = 5
        public var lightEpochs = 2
        public var noDeepEpochs = 3
        public var zThreshold: Float = 0.5
        public var maxEnvironmentSeconds = 5
    }

    public struct Quality: Sendable {
        public var durationWeight: Double = 40
        public var deepWeight: Double = 20
        public var continuityWeight: Double = 15
        public var calmWeight: Double = 15
        public var latencyWeight: Double = 10
        public var targetDeepShare: Double = 0.18
        public var awakeningsForZero: Double = 6
        public var movementsPerHourForZero: Double = 40
    }
}
