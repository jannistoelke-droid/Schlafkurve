import Foundation

public enum EpochBuilder {
    /// Groups per-second frames into 30 s epochs. `duration` (time in bed) makes trailing
    /// epochs without data appear as gaps.
    public static func build(frames: [FrameFeatures], duration: Double? = nil, tuning: Tuning = .standard) -> [EpochFeatures] {
        let length = tuning.staging.epochLength
        let lastT = frames.last.map { $0.t + 1 } ?? 0
        let total = max(duration ?? 0, lastT)
        let count = Int((total / length).rounded(.up))
        guard count > 0 else { return [] }

        var buckets = [[Int]](repeating: [], count: count)
        for (i, f) in frames.enumerated() {
            let e = Int(f.t / length)
            if e >= 0 && e < count { buckets[e].append(i) }
        }
        let moving = frames.map { MovementDetector.isMovement($0, tuning: tuning.movement) }

        var epochs: [EpochFeatures] = []
        epochs.reserveCapacity(count)
        var recentRates: [Float] = []
        for e in 0..<count {
            var ep = EpochFeatures(index: e, start: Double(e) * length)
            let idx = buckets[e]
            ep.frameCount = idx.count
            ep.gap = idx.count < tuning.staging.minFramesPerEpoch
            var aboveSum: Float = 0
            var previousMoving = false
            var previousCough = false
            for i in idx {
                let f = frames[i]
                let above = f.aboveFloorDb
                aboveSum += above
                ep.maxAboveFloorDb = max(ep.maxAboveFloorDb, above)
                if moving[i] {
                    ep.movementSeconds += 1
                    ep.movementEnergy += max(0, above)
                    if !previousMoving { ep.movementCount += 1 }
                }
                previousMoving = moving[i]
                if f.talk >= 0.5 && above >= tuning.events.minAboveFloorDb { ep.talkSeconds += 1 }
                if f.snore >= 0.5 { ep.snoreSeconds += 1 }
                let cough = f.cough >= 0.5
                if cough && !previousCough { ep.coughCount += 1 }
                previousCough = cough
                if f.environment >= 0.6 { ep.environmentSeconds += 1 }
            }
            ep.meanAboveFloorDb = idx.isEmpty ? 0 : aboveSum / Float(idx.count)

            if !ep.gap {
                let windowEnd = Double(e + 1) * length
                let windowStart = windowEnd - tuning.breathing.windowSeconds
                var env: [Float] = []
                var movementInWindow = 0
                var selfPlayback = false
                var w = e
                var collected: [[Int]] = []
                while w >= 0 && Double(w) * length >= windowStart - 0.001 {
                    collected.append(buckets[w])
                    w -= 1
                }
                for bucket in collected.reversed() {
                    for i in bucket where frames[i].t >= windowStart {
                        env.append(contentsOf: frames[i].env)
                        if moving[i] { movementInWindow += 1 }
                        if frames[i].selfPlayback { selfPlayback = true }
                    }
                }
                if !selfPlayback && movementInWindow <= tuning.breathing.maxMovementSeconds,
                   let b = BreathingAnalyzer.estimate(envelope: env, tuning: tuning.breathing) {
                    ep.breathRate = b.rate
                    ep.breathRegularity = b.regularity
                    recentRates.append(b.rate)
                    if recentRates.count > tuning.breathing.varianceEpochs { recentRates.removeFirst() }
                    if recentRates.count >= 3 {
                        let mean = recentRates.reduce(0, +) / Float(recentRates.count)
                        let v = recentRates.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(recentRates.count)
                        ep.breathRateVar = v.squareRoot()
                    }
                } else {
                    recentRates.removeAll()
                }
            }
            epochs.append(ep)
        }
        return epochs
    }
}

public struct StagingResult: Equatable, Sendable {
    public var stages: [SleepStage]
    public var z: [Float]
    public var depth: [Float]
    public var onsetIndex: Int?
}

public enum Stager {
    private static func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
    }

    /// Activity per epoch (log-compressed movement + talking).
    static func activity(_ epochs: [EpochFeatures], _ t: Tuning.Staging) -> [Float] {
        epochs.map { e in
            e.gap ? 0 : log1p(t.energyWeight * e.movementEnergy + t.movementWeight * Float(e.movementSeconds) + t.talkWeight * Float(e.talkSeconds))
        }
    }

    /// First epoch of the first quiet window = sleep onset.
    static func onset(_ epochs: [EpochFeatures], _ t: Tuning.Staging) -> Int? {
        let n = epochs.count
        guard n >= t.onsetEpochs else { return nil }
        for start in 0...(n - t.onsetEpochs) {
            var moving = 0
            var valid = 0
            var tooMuch = false
            for e in epochs[start..<(start + t.onsetEpochs)] where !e.gap {
                valid += 1
                if e.movementSeconds > 0 { moving += 1 }
                if e.movementSeconds >= t.onsetMaxMovementSeconds || e.talkSeconds > 2 { tooMuch = true }
            }
            if valid >= t.onsetEpochs / 2 && moving <= t.onsetMaxMovingEpochs && !tooMuch && !epochs[start].gap {
                // start at the first still epoch of the window
                var s = start
                while s < start + t.onsetEpochs - 1 && epochs[s].movementSeconds > 0 { s += 1 }
                return s
            }
        }
        return nil
    }

    public static func stage(_ epochs: [EpochFeatures], tuning: Tuning.Staging = Tuning.standard.staging, causal: Bool) -> StagingResult {
        let n = epochs.count
        guard n > 0 else { return StagingResult(stages: [], z: [], depth: [], onsetIndex: nil) }
        let a = activity(epochs, tuning)

        // 1. smoothed activity D and robust z-score
        let kernel = causal ? tuning.causalKernel : tuning.kernel
        let offsets = causal ? Array(-6...0) : Array(-4...2)
        var d = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var sum: Float = 0
            var weight: Float = 0
            for (k, off) in offsets.enumerated() {
                let j = i + off
                if j >= 0 && j < n && !epochs[j].gap {
                    sum += kernel[k] * a[j]
                    weight += kernel[k]
                }
            }
            d[i] = weight > 0 ? sum / weight : 0
        }
        let validD = (0..<n).filter { !epochs[$0].gap }.map { d[$0] }
        let med = median(validD)
        let mad = median(validD.map { abs($0 - med) })
        let scale = max(1.4826 * mad, tuning.minScale)
        let z = d.map { ($0 - med) / scale }

        let onsetIndex = onset(epochs, tuning)

        // 2. still runs (no movement, no talking)
        var stillRun = [Int](repeating: 0, count: n)
        var segmentLength = [Int](repeating: 0, count: n)
        var positionInSegment = [Int](repeating: 0, count: n)
        var cursor = 0
        while cursor < n {
            let still = !epochs[cursor].gap && epochs[cursor].movementSeconds == 0 && epochs[cursor].talkSeconds == 0
            if !still { cursor += 1; continue }
            var j = cursor
            while j < n && !epochs[j].gap && epochs[j].movementSeconds == 0 && epochs[j].talkSeconds == 0 { j += 1 }
            for k in cursor..<j {
                stillRun[k] = k - cursor + 1
                segmentLength[k] = j - cursor
                positionInSegment[k] = k - cursor
            }
            cursor = j
        }

        // 3. evidence for W, L, D
        var evidence = [[Float]](repeating: [0, 0, 0], count: n)
        for t in 0..<n {
            let e = epochs[t]
            if e.gap {
                evidence[t] = [1, 1, 1]
                continue
            }
            var w: Float
            if let o = onsetIndex, t >= o {
                if e.movementSeconds >= tuning.wakeMovementSeconds {
                    w = 0.95
                } else if e.talkSeconds >= 3 && e.movementSeconds >= 3 {
                    w = 0.9
                } else {
                    w = sigmoid((z[t] - tuning.wakeZ) / 0.4) * min(1, d[t] / tuning.wakeActivity)
                }
            } else {
                w = 0.9
            }

            var deep: Float = 0
            if let o = onsetIndex, t >= o {
                let hours = Double(t - o) * tuning.epochLength / 3600
                let circadian: Float = hours < 3 ? 1.2 : (hours < 5 ? 1.0 : 0.6)
                var base: Float
                if causal {
                    base = stillRun[t] >= tuning.deepMinStillEpochs ? 1 : Float(stillRun[t]) / Float(tuning.deepMinStillEpochs) * 0.4
                } else if segmentLength[t] >= tuning.deepMinStillEpochs {
                    base = positionInSegment[t] >= 4 ? 1 : 0.5
                } else {
                    base = Float(segmentLength[t]) / Float(tuning.deepMinStillEpochs) * 0.4
                }
                var breath: Float = 0.7
                if let reg = e.breathRegularity {
                    let v = e.breathRateVar ?? 0
                    if reg >= tuning.deepRegularity && v <= tuning.deepMaxRateVar { breath = 1.0 }
                    else if reg >= tuning.remIrregularity { breath = 0.6 }
                    else { breath = 0.25 }
                }
                deep = min(1, base * breath * circadian * 0.85)
            }
            let light = max(0.2, 1 - max(w, deep))
            evidence[t] = [w, light, deep]
        }

        // 4. HMM over W, L, D (Viterbi for final, forward filtering for live)
        let floor = tuning.emissionFloor
        func logp(_ x: Float) -> Float { log(max(x, 1e-9)) }
        var stages3 = [Int](repeating: 1, count: n)
        let logT = tuning.transitions.map { $0.map(logp) }
        if causal {
            var alpha = tuning.initial
            for t in 0..<n {
                if t > 0 {
                    var next: [Float] = [0, 0, 0]
                    for s in 0..<3 {
                        for p in 0..<3 { next[s] += alpha[p] * tuning.transitions[p][s] }
                    }
                    alpha = next
                }
                for s in 0..<3 { alpha[s] *= (evidence[t][s] + floor) }
                let sum = alpha.reduce(0, +)
                if sum > 0 { alpha = alpha.map { $0 / sum } } else { alpha = [1.0 / 3, 1.0 / 3, 1.0 / 3] }
                var best = 0
                for s in 1..<3 where alpha[s] > alpha[best] { best = s }
                stages3[t] = best
            }
        } else {
            var delta = (0..<3).map { logp(tuning.initial[$0]) + logp(evidence[0][$0] + floor) }
            var back = [[Int]](repeating: [0, 0, 0], count: n)
            if n > 1 {
                for t in 1..<n {
                    var next: [Float] = [0, 0, 0]
                    for s in 0..<3 {
                        var bestP = 0
                        var bestV = delta[0] + logT[0][s]
                        for p in 1..<3 {
                            let v = delta[p] + logT[p][s]
                            if v > bestV { bestV = v; bestP = p }
                        }
                        next[s] = bestV + logp(evidence[t][s] + floor)
                        back[t][s] = bestP
                    }
                    delta = next
                }
            }
            var last = 0
            for s in 1..<3 where delta[s] > delta[last] { last = s }
            stages3[n - 1] = last
            if n > 1 {
                for t in stride(from: n - 1, to: 0, by: -1) {
                    stages3[t - 1] = back[t][stages3[t]]
                }
            }
        }

        var stages = stages3.map { s -> SleepStage in s == 0 ? .wake : (s == 2 ? .deep : .light) }
        if let o = onsetIndex {
            for t in 0..<min(o, n) where !epochs[t].gap { stages[t] = .wake }
        } else if !causal {
            for t in 0..<n where !epochs[t].gap { stages[t] = .wake }
        }

        // 5. post rules
        if !causal {
            removeShortRuns(&stages, of: .deep, shorterThan: tuning.minDeepRun, replacement: .light)
            if let o = onsetIndex {
                for t in (o + 1)..<max(o + 1, n - 1) where stages[t] == .wake && stages[t - 1] != .wake && stages[t + 1] != .wake
                    && epochs[t].movementSeconds < tuning.wakeMovementSeconds {
                    stages[t] = .light
                }
                assignREM(&stages, epochs, onset: o, tuning: tuning)
            }
        }

        // 6. depth curve 0 (awake) … 1 (deep)
        var raw = [Float](repeating: 0, count: n)
        for t in 0..<n {
            raw[t] = tuning.depthStageWeight * stages[t].depthTarget + (1 - tuning.depthStageWeight) * (1 - sigmoid(z[t]))
        }
        let depth = gaussianSmooth(raw, sigma: tuning.depthSmoothSigma)
        return StagingResult(stages: stages, z: z, depth: depth, onsetIndex: onsetIndex)
    }

    static func removeShortRuns(_ stages: inout [SleepStage], of stage: SleepStage, shorterThan minLength: Int, replacement: SleepStage) {
        var i = 0
        while i < stages.count {
            guard stages[i] == stage else { i += 1; continue }
            var j = i
            while j < stages.count && stages[j] == stage { j += 1 }
            if j - i < minLength { for k in i..<j { stages[k] = replacement } }
            i = j
        }
    }

    /// REM is assigned to long stretches of still light sleep later in the night: with irregular
    /// breathing where breathing is measurable, otherwise shortly after deep sleep or late in the night.
    static func assignREM(_ stages: inout [SleepStage], _ epochs: [EpochFeatures], onset: Int, tuning: Tuning.Staging) {
        let n = stages.count
        let minStart = onset + Int(tuning.remMinMinutesAfterOnset * 60 / tuning.epochLength)
        var candidate = [Bool](repeating: false, count: n)
        var lastDeepEnd: Int?
        for t in 0..<n {
            if stages[t] == .deep { lastDeepEnd = t + 1; continue }
            let e = epochs[t]
            guard t >= minStart, stages[t] == .light, !e.gap, Float(e.movementSeconds) <= tuning.remMaxMeanMovementSeconds else { continue }
            if let reg = e.breathRegularity {
                candidate[t] = reg < tuning.remIrregularity || (e.breathRateVar ?? 0) > tuning.remRateVar
            } else {
                let hours = Double(t - onset) * tuning.epochLength / 3600
                let afterDeep = lastDeepEnd.map { t - $0 <= tuning.remAfterDeepWithinEpochs } ?? false
                candidate[t] = afterDeep || hours >= tuning.remLateNightHours
            }
        }
        // close single-epoch holes
        if n > 2 {
            for t in 1..<(n - 1) where !candidate[t] && candidate[t - 1] && candidate[t + 1] && stages[t] == .light {
                candidate[t] = true
            }
        }
        var i = 0
        while i < n {
            guard candidate[i] else { i += 1; continue }
            var j = i
            while j < n && candidate[j] { j += 1 }
            if j - i >= tuning.remMinRunEpochs {
                for k in (i + 1)..<j { stages[k] = .rem }
            }
            i = j
        }
    }

    static func gaussianSmooth(_ x: [Float], sigma: Float) -> [Float] {
        guard sigma > 0, x.count > 2 else { return x }
        let radius = Int((sigma * 3).rounded(.up))
        var weights: [Float] = []
        for k in -radius...radius { weights.append(exp(-Float(k * k) / (2 * sigma * sigma))) }
        var out = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            var s: Float = 0
            var w: Float = 0
            for k in -radius...radius {
                let j = i + k
                if j >= 0 && j < x.count {
                    s += weights[k + radius] * x[j]
                    w += weights[k + radius]
                }
            }
            out[i] = s / w
        }
        return out
    }

    /// Live view for the wake-up logic.
    public static func liveEpochs(_ epochs: [EpochFeatures], tuning: Tuning.Staging = Tuning.standard.staging) -> (epochs: [LiveEpoch], hasOnset: Bool) {
        let r = stage(epochs, tuning: tuning, causal: true)
        let live = epochs.indices.map { i in
            LiveEpoch(stage: r.stages[i], movementSeconds: epochs[i].movementSeconds, movementCount: epochs[i].movementCount,
                      z: r.z[i], environmentSeconds: epochs[i].environmentSeconds, gap: epochs[i].gap)
        }
        return (live, r.onsetIndex != nil)
    }
}

public enum WakeDecision: Equatable, Sendable {
    case wait
    case wakeNow(WakeReason)
}

public struct WakeDecider: Sendable {
    public let tuning: Tuning.Wake

    public init(tuning: Tuning.Wake = Tuning.standard.wake) { self.tuning = tuning }

    public func evaluate(now: Date, latest: Date, window: TimeInterval, recent: [LiveEpoch], hasOnset: Bool) -> WakeDecision {
        if now >= latest { return .wakeNow(.deadline) }
        if now < latest.addingTimeInterval(-window) { return .wait }
        guard let last = recent.last, !last.gap else { return .wait }
        if last.stage == .wake && last.movementSeconds >= tuning.awakeMovementSeconds {
            return .wakeNow(.awakeDetected)
        }
        guard hasOnset, recent.count >= tuning.lightEpochs else { return .wait }
        let lastLight = recent.suffix(tuning.lightEpochs)
        let noDeep = !recent.suffix(tuning.noDeepEpochs).contains { $0.stage == .deep }
        let allLight = lastLight.allSatisfy { $0.stage != .deep && !$0.gap }
        let movement = lastLight.reduce(0) { $0 + $1.movementCount } >= 1 && last.environmentSeconds <= tuning.maxEnvironmentSeconds
        if allLight && noDeep && (movement || last.z >= tuning.zThreshold) {
            return .wakeNow(.smartLightSleep)
        }
        return .wait
    }
}
