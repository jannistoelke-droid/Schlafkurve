import XCTest
@testable import SleepEngineCore

final class FeatureExtractorTests: XCTestCase {
    func testSineVersusNoise() {
        let fx = FeatureExtractor()
        var sine = [Float](repeating: 0, count: 16_000 * 2)
        for i in sine.indices { sine[i] = 0.5 * sin(2 * Float.pi * 440 * Float(i) / 16_000) }
        let sineFrames = fx.process(sine)
        XCTAssertEqual(sineFrames.count, 2)
        XCTAssertEqual(sineFrames[1].levelDb, -9.03, accuracy: 1.0)
        XCTAssertLessThan(sineFrames[1].flatness, 0.1)

        let fx2 = FeatureExtractor()
        var rng = SeededRandom(seed: 1)
        let noise = (0..<(16_000 * 2)).map { _ in rng.gaussian() * 0.1 }
        let noiseFrames = fx2.process(noise)
        XCTAssertEqual(noiseFrames.count, 2)
        XCTAssertGreaterThan(noiseFrames[1].flatness, 0.3)
        XCTAssertEqual(noiseFrames[1].env.count, 4)
    }

    func testChunkedInputGivesSameResult() {
        var rng = SeededRandom(seed: 3)
        let samples = (0..<16_000).map { _ in rng.gaussian() * 0.05 }
        let a = FeatureExtractor().process(samples)
        let fx = FeatureExtractor()
        var b: [FrameFeatures] = []
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + 1_234)
            b += fx.process(Array(samples[i..<end]))
            i = end
        }
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(a[0].levelDb, b[0].levelDb, accuracy: 0.001)
        XCTAssertEqual(a[0].flatness, b[0].flatness, accuracy: 0.001)
    }

    func testNoiseFloorTracksLowPercentile() {
        var tracker = NoiseFloorTracker(capacity: 100, percentile: 0.1)
        var floor: Float = 0
        for i in 0..<100 { floor = tracker.push(i % 10 == 0 ? -20 : -60) }
        XCTAssertEqual(floor, -60, accuracy: 0.001)
    }
}

final class BreathingTests: XCTestCase {
    func testRegularBreathing() {
        var rng = SeededRandom(seed: 5)
        let env = (0..<240).map { i -> Float in -70 + 3 * sin(2 * Float.pi * Float(i) / 16) + rng.gaussian() * 0.3 }
        let b = BreathingAnalyzer.estimate(envelope: env)
        XCTAssertNotNil(b)
        XCTAssertEqual(b?.rate ?? 0, 15, accuracy: 1)
        XCTAssertGreaterThan(b?.regularity ?? 0, 0.6)
    }

    func testFlatEnvelopeGivesNil() {
        var rng = SeededRandom(seed: 6)
        let env = (0..<240).map { _ in -70 + rng.gaussian() * 0.1 }
        XCTAssertNil(BreathingAnalyzer.estimate(envelope: env))
    }
}

final class EventTrackerTests: XCTestCase {
    private func frame(_ t: Double, snore: Float = 0, talk: Float = 0, above: Float = 12) -> FrameFeatures {
        FrameFeatures(t: t, levelDb: -60 + above, peakDb: -50 + above, noiseFloorDb: -60, snore: snore, talk: talk)
    }

    func testSnoreEventLifecycle() {
        var tracker = EventTracker()
        var updates: [EventTracker.Update] = []
        for t in 0..<20 { updates += tracker.process(frame(Double(t), snore: t >= 2 && t < 12 ? 0.8 : 0)) }
        let started = updates.compactMap { u -> SoundGroup? in if case .started(_, let g, _) = u { return g }; return nil }
        let finished = updates.compactMap { u -> SoundEvent? in if case .finished(let e) = u { return e }; return nil }
        XCTAssertEqual(started, [.snore])
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?.start ?? -1, 2, accuracy: 0.01)
        XCTAssertEqual(finished.first?.end ?? -1, 12, accuracy: 0.01)
    }

    func testShortBlipIsCancelled() {
        var tracker = EventTracker()
        var updates: [EventTracker.Update] = []
        for t in 0..<10 { updates += tracker.process(frame(Double(t), snore: t >= 2 && t < 4 ? 0.8 : 0)) }
        XCTAssertTrue(updates.contains { if case .cancelled = $0 { return true }; return false })
        XCTAssertFalse(updates.contains { if case .finished = $0 { return true }; return false })
    }

    func testQuietSoundsAreIgnored() {
        var tracker = EventTracker()
        var updates: [EventTracker.Update] = []
        for t in 0..<10 { updates += tracker.process(frame(Double(t), talk: 0.9, above: 2)) }
        XCTAssertTrue(updates.isEmpty)
    }

    func testTalkPreemptsSnore() {
        var tracker = EventTracker()
        var updates: [EventTracker.Update] = []
        for t in 0..<30 {
            let talk: Float = t >= 10 && t < 15 ? 0.9 : 0
            updates += tracker.process(frame(Double(t), snore: t < 20 ? 0.8 : 0, talk: talk))
        }
        let groups = updates.compactMap { u -> SoundGroup? in if case .started(_, let g, _) = u { return g }; return nil }
        XCTAssertEqual(groups.prefix(2), [.snore, .talk])
    }
}

final class CodecTests: XCTestCase {
    func testRoundTrip() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var f = FrameFeatures(t: 12, levelDb: -40, peakDb: -30, noiseFloorDb: -55, flatness: 0.4, env: [1, 2, 3, 4], snore: 0.7, flags: 1)
        f.environment = 0.2
        var data = FrameCodec.header(startDate: start)
        data.append(FrameCodec.encode(f))
        data.append(FrameCodec.encode(f))
        let decoded = try FrameCodec.decode(data)
        XCTAssertEqual(decoded.startDate, start)
        XCTAssertEqual(decoded.frames.count, 2)
        XCTAssertEqual(decoded.frames[0], f)
    }
}

final class StagingTests: XCTestCase {
    func testTypicalNight() {
        let night = SyntheticNight.typical.generate()
        let analysis = NightAnalyzer.analyze(frames: night.frames, events: night.events, timeInBed: SyntheticNight.typical.totalSeconds)
        let s = analysis.summary
        let onsetMinutes = (s.onset ?? -60) / 60
        XCTAssertGreaterThanOrEqual(onsetMinutes, 14, "onset \(onsetMinutes)")
        XCTAssertLessThanOrEqual(onsetMinutes, 32, "onset \(onsetMinutes)")

        // truth per epoch = stage of the epoch's middle second
        let truth = analysis.epochs.map { night.truth[min(night.truth.count - 1, Int($0.start) + 15)] }
        let deepTruth = truth.indices.filter { truth[$0] == .deep }
        let deepHits = deepTruth.filter { analysis.stages[$0] == .deep }.count
        XCTAssertGreaterThanOrEqual(Double(deepHits), 0.6 * Double(deepTruth.count), "deep \(deepHits)/\(deepTruth.count)")

        let lastTen = analysis.stages.suffix(10)
        XCTAssertGreaterThanOrEqual(lastTen.filter { $0 == .wake }.count, 5)

        XCTAssertGreaterThan(s.remSeconds, 0)
        XCTAssertGreaterThan(s.lightSeconds, 0)
        XCTAssertGreaterThan(s.asleep, 4 * 3600)
        XCTAssertLessThan(s.asleep, 6.5 * 3600)
        XCTAssertGreaterThanOrEqual(s.awakenings, 1)
        XCTAssertTrue((0...100).contains(s.quality))
        XCTAssertGreaterThanOrEqual(s.snoreEpisodes, 2)
        XCTAssertEqual(analysis.depth.count, analysis.epochs.count)
    }

    func testGapsAreNotSleep() {
        var night = SyntheticNight.typical.generate()
        // remove one hour in the middle
        night.frames.removeAll { $0.t > 10_000 && $0.t < 13_600 }
        let analysis = NightAnalyzer.analyze(frames: night.frames, events: [], timeInBed: SyntheticNight.typical.totalSeconds)
        XCTAssertGreaterThanOrEqual(analysis.summary.gapSeconds, 3_500)
        XCTAssertLessThan(analysis.summary.analysedSeconds, SyntheticNight.typical.totalSeconds - 3_500)
    }

    func testGainInvariance() {
        let night = SyntheticNight.typical.generate()
        let louder = night.frames.map { f -> FrameFeatures in
            var g = f
            g.levelDb += 12; g.peakDb += 12; g.noiseFloorDb += 12
            g.env = f.env.map { $0 + 12 }
            return g
        }
        let a = NightAnalyzer.analyze(frames: night.frames, events: [], timeInBed: SyntheticNight.typical.totalSeconds)
        let b = NightAnalyzer.analyze(frames: louder, events: [], timeInBed: SyntheticNight.typical.totalSeconds)
        XCTAssertEqual(a.stages.count, b.stages.count)
        let same = zip(a.stages, b.stages).filter { $0 == $1 }.count
        XCTAssertGreaterThanOrEqual(Double(same), 0.98 * Double(a.stages.count))
    }

    func testEmptyNight() {
        let a = NightAnalyzer.analyze(frames: [], events: [], timeInBed: 0)
        XCTAssertTrue(a.epochs.isEmpty)
        XCTAssertEqual(a.summary.quality, 0)
    }

    func testLiveStagingRuns() {
        let night = SyntheticNight.typical.generate()
        let frames = Array(night.frames.prefix(3 * 3600))
        let epochs = EpochBuilder.build(frames: frames)
        let live = Stager.liveEpochs(epochs)
        XCTAssertEqual(live.epochs.count, epochs.count)
        XCTAssertTrue(live.hasOnset)
    }
}

final class WakeDeciderTests: XCTestCase {
    let latest = Date(timeIntervalSince1970: 1_800_030_000)
    let decider = WakeDecider()

    private func epoch(_ stage: SleepStage, moves: Int = 0, seconds: Int = 0, z: Float = 0) -> LiveEpoch {
        LiveEpoch(stage: stage, movementSeconds: seconds, movementCount: moves, z: z, environmentSeconds: 0, gap: false)
    }

    func testWaitsBeforeWindow() {
        let r = decider.evaluate(now: latest.addingTimeInterval(-3600), latest: latest, window: 1800,
                                 recent: [epoch(.wake, moves: 3, seconds: 20)], hasOnset: true)
        XCTAssertEqual(r, .wait)
    }

    func testDeadline() {
        XCTAssertEqual(decider.evaluate(now: latest, latest: latest, window: 1800, recent: [], hasOnset: true), .wakeNow(.deadline))
    }

    func testLightSleepWithMovementWakes() {
        let r = decider.evaluate(now: latest.addingTimeInterval(-600), latest: latest, window: 1800,
                                 recent: [epoch(.light), epoch(.light), epoch(.light, moves: 1, seconds: 2)], hasOnset: true)
        XCTAssertEqual(r, .wakeNow(.smartLightSleep))
    }

    func testDeepSleepWaits() {
        let r = decider.evaluate(now: latest.addingTimeInterval(-600), latest: latest, window: 1800,
                                 recent: [epoch(.deep), epoch(.deep), epoch(.light, moves: 1, seconds: 2)], hasOnset: true)
        XCTAssertEqual(r, .wait)
    }

    func testAwake() {
        let r = decider.evaluate(now: latest.addingTimeInterval(-600), latest: latest, window: 1800,
                                 recent: [epoch(.deep), epoch(.wake, moves: 2, seconds: 12)], hasOnset: true)
        XCTAssertEqual(r, .wakeNow(.awakeDetected))
    }
}
