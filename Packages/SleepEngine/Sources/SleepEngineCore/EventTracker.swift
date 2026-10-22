import Foundation

/// Hysteresis state machine turning per-second classifier confidences into sound events.
public struct EventTracker {
    public enum Update: Equatable {
        case started(UUID, SoundGroup, Double)
        case finished(SoundEvent)
        case cancelled(UUID)
    }

    private struct Active {
        var id: UUID
        var group: SoundGroup
        var start: Double
        var lastAbove: Double
        var peak: Float
        var confidenceSum: Float
        var confidenceCount: Int
    }

    private let tuning: Tuning.Events
    private let sensitivity: Sensitivity
    private var active: Active?
    private var pending: [SoundGroup: Int] = [:]
    private let groupsByPriority = SoundGroup.allCases.sorted { $0.priority < $1.priority }

    public init(tuning: Tuning.Events = Tuning.standard.events, sensitivity: Sensitivity = .medium) {
        self.tuning = tuning
        self.sensitivity = sensitivity
    }

    public var activeEventID: UUID? { active?.id }

    private func confidence(_ group: SoundGroup, _ f: FrameFeatures) -> Float {
        if group == .loud {
            let loud = f.aboveFloorDb >= tuning.loudAboveFloorDb + sensitivity.decibelShift
                && f.maxClassifiedConfidence < tuning.loudMaxClassifiedConfidence
            return loud ? 1 : 0
        }
        return f.confidence(for: group)
    }

    private func startThreshold(_ group: SoundGroup) -> Float {
        let p = tuning.params(group)
        return group == .loud ? p.start : p.start + sensitivity.confidenceShift
    }

    public mutating func process(_ f: FrameFeatures) -> [Update] {
        var updates: [Update] = []
        if f.selfPlayback {
            if let a = active { updates.append(close(a, end: a.lastAbove + 1)) }
            active = nil
            pending.removeAll()
            return updates
        }
        let gate = tuning.minAboveFloorDb + sensitivity.decibelShift
        let above = f.aboveFloorDb

        for g in groupsByPriority {
            if confidence(g, f) >= startThreshold(g) && above >= gate {
                pending[g, default: 0] += 1
            } else {
                pending[g] = 0
            }
        }
        let ready = groupsByPriority.first { pending[$0, default: 0] >= tuning.params($0).startFrames }

        if var a = active {
            let p = tuning.params(a.group)
            let c = confidence(a.group, f)
            if c >= p.keep && above >= gate - 3 {
                a.lastAbove = f.t
                a.peak = max(a.peak, f.peakDb)
                a.confidenceSum += c
                a.confidenceCount += 1
            }
            if let r = ready, r.priority < a.group.priority {
                updates.append(close(a, end: max(a.lastAbove + 1, f.t)))
                active = nil
            } else if f.t - a.lastAbove >= p.endAfter {
                updates.append(close(a, end: a.lastAbove + 1))
                active = nil
            } else if f.t + 1 - a.start >= p.maxDuration {
                updates.append(close(a, end: f.t + 1))
                active = nil
            } else {
                active = a
            }
        }

        if active == nil, let g = ready {
            let p = tuning.params(g)
            let start = f.t - Double(p.startFrames - 1)
            let a = Active(id: UUID(), group: g, start: start, lastAbove: f.t, peak: f.peakDb,
                           confidenceSum: confidence(g, f), confidenceCount: 1)
            active = a
            pending[g] = 0
            updates.append(.started(a.id, g, start))
        }
        return updates
    }

    /// Ends a running event (e.g. at the end of the session).
    public mutating func flush() -> [Update] {
        guard let a = active else { return [] }
        active = nil
        pending.removeAll()
        return [close(a, end: a.lastAbove + 1)]
    }

    private func close(_ a: Active, end: Double) -> Update {
        let p = tuning.params(a.group)
        if end - a.start < p.minDuration { return .cancelled(a.id) }
        let event = SoundEvent(id: a.id, group: a.group, label: a.group.rawValue, start: a.start, end: end,
                               peakDb: a.peak, meanConfidence: a.confidenceSum / Float(max(a.confidenceCount, 1)))
        return .finished(event)
    }
}

public enum MovementDetector {
    /// A movement sound (sheets, mattress, turning over) is broadband, clearly above the
    /// floor and not something the classifier recognises as speech, snoring etc.
    public static func isMovement(_ f: FrameFeatures, tuning: Tuning.Movement = Tuning.standard.movement) -> Bool {
        if f.selfPlayback { return false }
        return f.flatness >= tuning.minFlatness
            && f.aboveFloorDb >= tuning.minAboveFloorDb
            && f.maxClassifiedConfidence < tuning.maxClassifiedConfidence
    }
}

public struct BreathingEstimate: Equatable, Sendable {
    public var rate: Float        // breaths per minute
    public var regularity: Float  // 0…1, normalised autocorrelation at the breathing period
}

public enum BreathingAnalyzer {
    /// Estimates breathing rate from the 4 Hz band envelope (dB). Returns nil if no
    /// clear periodicity is present (common when the phone is far away).
    public static func estimate(envelope: [Float], tuning: Tuning.Breathing = Tuning.standard.breathing) -> BreathingEstimate? {
        let fs = tuning.envelopeRate
        let n = envelope.count
        guard n >= Int(fs * 40) else { return nil }
        // high-pass: subtract a centred 4 s moving average
        let half = Int(fs * 2)
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n - 1, i + half)
            var sum: Float = 0
            for j in lo...hi { sum += envelope[j] }
            x[i] = envelope[i] - sum / Float(hi - lo + 1)
        }
        var variance: Float = 0
        for v in x { variance += v * v }
        variance /= Float(n)
        let std = variance.squareRoot()
        guard std >= tuning.minModulationDb else { return nil }
        for i in 0..<n { x[i] /= std }

        let minLag = Int(tuning.minPeriod * fs)
        let maxLag = min(Int(tuning.maxPeriod * fs), n / 3)
        guard maxLag > minLag + 2 else { return nil }
        var r = [Float](repeating: 0, count: maxLag + 2)
        for lag in (minLag - 1)...(maxLag + 1) {
            var s: Float = 0
            for i in 0..<(n - lag) { s += x[i] * x[i + lag] }
            r[lag] = s / Float(n - lag)
        }
        var best = minLag
        for lag in minLag...maxLag where r[lag] > r[best] { best = lag }
        let bestValue = r[best]
        guard bestValue >= tuning.minRegularity else { return nil }
        // prefer the first local maximum close to the best one (avoid picking a multiple of the period)
        var chosen = best
        for lag in minLag...maxLag {
            if r[lag] >= r[lag - 1] && r[lag] >= r[lag + 1] && r[lag] >= 0.85 * bestValue {
                chosen = lag
                break
            }
        }
        var period = Float(chosen)
        let denom = r[chosen - 1] - 2 * r[chosen] + r[chosen + 1]
        if abs(denom) > 1e-6 {
            let delta = 0.5 * (r[chosen - 1] - r[chosen + 1]) / denom
            if abs(delta) < 1 { period += delta }
        }
        let seconds = period / fs
        guard seconds > 0 else { return nil }
        return BreathingEstimate(rate: 60 / seconds, regularity: min(1, max(0, r[chosen])))
    }
}
