import Foundation
import SleepEngineCore

/// Chart-ready data derived from one night (times as Dates, gaps split out).
struct ReportModel {
    struct StageRun: Identifiable {
        var id: Int
        var stage: SleepStage
        var start: Date
        var end: Date
    }

    struct Span: Identifiable {
        var id: Int
        var start: Date
        var end: Date
    }

    /// One point of a line that is interrupted at data gaps (`segment` changes after each gap).
    struct Point: Identifiable {
        var id: Int
        var time: Date
        var value: Double
        var segment: Int
    }

    struct Bucket: Identifiable {
        var id: Int
        var start: Date
        var end: Date
        var minutes: Double
    }

    let start: Date
    let end: Date
    let stages: [SleepStage]
    let epochGap: [Bool]
    let stageRuns: [StageRun]
    let gaps: [Span]
    /// Wakefulness 0 (deep) … 1 (awake) = 1 - depth, downsampled to ≤ 400 points.
    let wakefulness: [Point]
    let noise: [Point]
    let breathing: [Point]

    static let epoch = NightAnalysis.epochLength

    init(meta: SessionMeta, analysis: NightAnalysis?) {
        start = meta.startDate
        let fallbackEnd = meta.startDate.addingTimeInterval(meta.summary?.timeInBed ?? 0)
        end = max(meta.endDate ?? fallbackEnd, meta.startDate.addingTimeInterval(60))
        guard let analysis else {
            stages = []; epochGap = []; stageRuns = []; gaps = []; wakefulness = []; noise = []; breathing = []
            return
        }
        let epochs = analysis.epochs
        let n = min(epochs.count, analysis.stages.count)
        stages = Array(analysis.stages.prefix(n))
        epochGap = epochs.prefix(n).map(\.gap)
        let start = self.start
        let end = self.end
        func epochDate(_ i: Int) -> Date { min(start.addingTimeInterval(Double(i) * Self.epoch), end) }

        var runs: [StageRun] = []
        var gapSpans: [Span] = []
        var i = 0
        while i < n {
            var j = i
            if epochGap[i] {
                while j + 1 < n && epochGap[j + 1] { j += 1 }
                gapSpans.append(Span(id: gapSpans.count, start: epochDate(i), end: epochDate(j + 1)))
            } else {
                while j + 1 < n && !epochGap[j + 1] && stages[j + 1] == stages[i] { j += 1 }
                runs.append(StageRun(id: runs.count, stage: stages[i], start: epochDate(i), end: epochDate(j + 1)))
            }
            i = j + 1
        }
        stageRuns = runs
        gaps = gapSpans

        let depth = analysis.depth
        let step = max(1, Int((Double(min(depth.count, n)) / 400).rounded(.up)))
        var points: [Point] = []
        var noisePoints: [Point] = []
        var breathPoints: [Point] = []
        var segment = 0
        var previousGap = false
        for k in 0..<n {
            if epochGap[k] {
                if !previousGap { segment += 1 }
                previousGap = true
                continue
            }
            previousGap = false
            let t = start.addingTimeInterval((Double(k) + 0.5) * Self.epoch)
            if k < depth.count && k % step == 0 {
                points.append(Point(id: k, time: t, value: Double(1 - depth[k]), segment: segment))
            }
            if k % step == 0 {
                noisePoints.append(Point(id: k, time: t, value: Double(epochs[k].meanAboveFloorDb), segment: segment))
            }
            if let rate = epochs[k].breathRate {
                breathPoints.append(Point(id: k, time: t, value: Double(rate), segment: segment))
            }
        }
        wakefulness = points
        noise = noisePoints
        breathing = breathPoints
    }

    func date(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    /// Stage at a point in time, nil inside a gap or outside the analysed range.
    func stage(at time: Date) -> SleepStage? {
        let i = Int(time.timeIntervalSince(start) / Self.epoch)
        guard i >= 0, i < stages.count, !epochGap[i] else { return nil }
        return stages[i]
    }

    func isGap(at time: Date) -> Bool {
        let i = Int(time.timeIntervalSince(start) / Self.epoch)
        return i >= 0 && i < epochGap.count && epochGap[i]
    }

    /// Snoring minutes per 15-minute bucket.
    func snoreBuckets(_ events: [SoundEvent]) -> [Bucket] {
        let size = 900.0
        let total = end.timeIntervalSince(start)
        let count = max(1, Int((total / size).rounded(.up)))
        var minutes = [Double](repeating: 0, count: count)
        for e in events where e.group == .snore {
            var t = e.start
            while t < e.end {
                let b = Int(t / size)
                let bucketEnd = Double(b + 1) * size
                let slice = min(e.end, bucketEnd) - t
                if b >= 0 && b < count { minutes[b] += slice / 60 }
                t = bucketEnd
            }
        }
        return minutes.enumerated().map { i, m in
            Bucket(id: i, start: date(Double(i) * size), end: min(date(Double(i + 1) * size), end), minutes: m)
        }
    }
}
