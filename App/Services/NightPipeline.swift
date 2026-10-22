import AVFoundation
import Foundation
import SleepEngineCore
import SoundAnalysis

/// Everything that happens to the audio during the night, off the main thread:
/// conversion to 16 kHz → classifier + features + clips → frames.bin / events.jsonl → live staging.
final class NightPipeline {
    struct Config {
        var folder: URL
        var start: Date
        var sensitivity: Sensitivity
        var fullNightAudio: Bool
        var tuning: Tuning = .standard
    }

    static let sampleRate: Double = 16_000
    private let finalizeLag = 3

    let config: Config
    private let log: DiagnosticsLog
    private let queue = DispatchQueue(label: "app.schlafkurve.pipeline", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "app.schlafkurve.analysis", qos: .userInitiated)
    private let processingFormat: AVAudioFormat

    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var extractor = FeatureExtractor()
    private var floorTracker = NoiseFloorTracker()
    private var tracker: EventTracker
    private let clips: ClipRecorder
    private let writer: FrameWriter
    private var nightFile: AVAudioFile?
    private var eventsHandle: FileHandle?
    private let confidences = ConfidenceStore()
    private var analyzer: SNAudioStreamAnalyzer?
    private var observer: ClassifierObserver?

    // timing: stream samples (16 kHz, monotonic) ↔ wall-clock seconds since session start
    private var streamSample: Int64 = 0
    private var extractorStartSample: Int64 = 0
    private var anchorSecond = 0
    private var secondsSinceAnchor = 0
    private let anchorLock = NSLock()
    private var anchors: [(sample: Int64, second: Int)] = [(0, 0)]
    private var pendingFrames: [Int: FrameFeatures] = [:]
    private var sampleAtSecond: [Int: Int64] = [:]
    private var lastFinalizedSecond = -1

    private var frames: [FrameFeatures] = []
    private var currentEpoch = 0
    private var pendingEvents: [UUID: SoundEvent] = [:]
    private var snoreClipsPerBlock: [Int: Int] = [:]
    private var topLabels: [Int: String] = [:]
    private var selfPlaybackUntilSecond = -1
    private var finished = false
    private(set) var gaps: [DataGap] = []
    private var pendingGapReason: String?

    // counters for heartbeat / debug (read from other threads – approximate is fine)
    private let statsLock = NSLock()
    private var _lastBufferDate = Date()
    private var _eventCount = 0
    private var _framesWritten = 0

    var onEpoch: (([LiveEpoch], Bool) -> Void)?
    var onSecond: ((Float, String) -> Void)?

    init(config: Config, log: DiagnosticsLog) throws {
        self.config = config
        self.log = log
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "Schlafkurve", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audioformat nicht verfügbar"])
        }
        processingFormat = format
        tracker = EventTracker(tuning: config.tuning.events, sensitivity: config.sensitivity)
        clips = ClipRecorder(format: format, ringSeconds: config.tuning.clips.ringSeconds)
        writer = try FrameWriter(url: config.folder.appendingPathComponent("frames.bin"), startDate: config.start)

        let eventsURL = config.folder.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: eventsURL.path) {
            FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        }
        eventsHandle = try? FileHandle(forWritingTo: eventsURL)
        _ = try? eventsHandle?.seekToEnd()

        if config.fullNightAudio {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1]
            nightFile = try? AVAudioFile(forWriting: config.folder.appendingPathComponent("night.m4a"), settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
        }

        clips.onFinished = { [weak self] finished in self?.clipFinished(finished) }
        clips.onError = { [weak self] message in self?.log.log("clip_error", ["error": message]) }
        setUpClassifier()
    }

    private func setUpClassifier() {
        let analyzer = SNAudioStreamAnalyzer(format: processingFormat)
        let observer = ClassifierObserver(store: confidences, sampleRate: Self.sampleRate) { [weak self] sample in
            self?.second(forSample: sample) ?? 0
        }
        observer.onError = { [weak self] message in self?.log.log("classifier_error", ["error": message]) }
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.overlapFactor = 0.5
            try analyzer.add(request, withObserver: observer)
            self.analyzer = analyzer
            self.observer = observer
            let mapped = request.knownClassifications.filter { LabelMapping.group(for: $0) != .other }
            log.log("classifier_ready", ["labels": "\(request.knownClassifications.count)", "mapped": "\(mapped.count)",
                                         "missing": LabelMapping.snore.union(LabelMapping.talk).union(LabelMapping.cough)
                                            .subtracting(request.knownClassifications).sorted().joined(separator: ",")])
        } catch {
            log.log("classifier_failed", ["error": "\(error)"])
        }
    }

    private func second(forSample sample: Int64) -> Int {
        anchorLock.lock()
        defer { anchorLock.unlock() }
        let anchor = anchors.last { $0.sample <= sample } ?? anchors[0]
        return anchor.second + Int((sample - anchor.sample) / Int64(Self.sampleRate))
    }

    // MARK: input (audio thread)

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        let captured = Date()
        statsLock.lock()
        _lastBufferDate = captured
        statsLock.unlock()
        queue.async { [weak self] in self?.process(copy, captured: captured) }
    }

    var secondsSinceLastBuffer: TimeInterval {
        statsLock.lock()
        defer { statsLock.unlock() }
        return Date().timeIntervalSince(_lastBufferDate)
    }

    var stats: (frames: Int, events: Int) {
        statsLock.lock()
        defer { statsLock.unlock() }
        return (_framesWritten, _eventCount)
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, let src = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let dst = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let stride = buffer.stride
        for c in 0..<(buffer.format.isInterleaved ? 1 : channels) {
            dst[c].update(from: src[c], count: frames * (buffer.format.isInterleaved ? stride : 1))
        }
        return copy
    }

    /// Marks our own pre-alarm playback so it is not analysed as sleep sounds.
    func markSelfPlayback(until date: Date) {
        queue.async { [weak self] in
            guard let self else { return }
            self.selfPlaybackUntilSecond = Int(date.timeIntervalSince(self.config.start)) + 1
        }
    }

    func noteGapReason(_ reason: String) {
        queue.async { [weak self] in self?.pendingGapReason = reason }
    }

    // MARK: processing (pipeline queue)

    private func process(_ input: AVAudioPCMBuffer, captured: Date) {
        guard !finished else { return }
        guard let out = convert(input) else { return }
        let n = Int(out.frameLength)
        guard n > 0, let channel = out.floatChannelData?[0] else { return }

        // wall clock vs. sample clock: re-anchor after stalls, interruptions or suspension
        let bufferStart = captured.addingTimeInterval(-Double(n) / Self.sampleRate)
        let expected = config.start.addingTimeInterval(Double(anchorSecond) + Double(streamSample - extractorStartSample) / Self.sampleRate)
        let drift = bufferStart.timeIntervalSince(expected)
        if drift > 5 || drift < -5 { reanchor(reason: pendingGapReason ?? "stall", drift: drift, wallNow: bufferStart) }

        let samples = Array(UnsafeBufferPointer(start: channel, count: n))
        let startIndex = streamSample
        streamSample += Int64(n)

        if let analyzer {
            analysisQueue.async { analyzer.analyze(out, atAudioFramePosition: startIndex) }
        }
        clips.append(samples, startIndex: startIndex)
        if let nightFile { try? nightFile.write(from: out) }

        for frame in extractor.process(samples) {
            let second = anchorSecond + secondsSinceAnchor
            sampleAtSecond[second] = extractorStartSample + Int64(secondsSinceAnchor) * Int64(Self.sampleRate)
            secondsSinceAnchor += 1
            pendingFrames[second] = frame
            for s in pendingFrames.keys.sorted() where s <= second - finalizeLag { finalize(s) }
        }
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converterInput != input.format {
            converter = AVAudioConverter(from: input.format, to: processingFormat)
            converterInput = input.format
            log.log("converter", ["from": "\(input.format.sampleRate) Hz x\(input.format.channelCount)"])
        }
        guard let converter else { return nil }
        let ratio = processingFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            log.log("convert_failed", ["error": "\(String(describing: error))"])
            return nil
        }
        return out
    }

    private func reanchor(reason: String, drift: Double, wallNow: Date) {
        for s in pendingFrames.keys.sorted() { finalize(s) }
        for update in tracker.flush() { handle(update) }
        let lastSecond = max(lastFinalizedSecond, 0)
        let newSecond = max(Int(wallNow.timeIntervalSince(config.start)), lastSecond + 1)
        if newSecond - lastSecond > 2 {
            gaps.append(DataGap(start: Double(lastSecond + 1), end: Double(newSecond), reason: reason))
        }
        log.log("reanchor", ["reason": reason, "drift": String(format: "%.1f", drift), "from": "\(lastSecond)", "to": "\(newSecond)"])
        pendingGapReason = nil
        extractor = FeatureExtractor()
        anchorSecond = newSecond
        secondsSinceAnchor = 0
        extractorStartSample = streamSample
        anchorLock.lock()
        anchors.append((streamSample, newSecond))
        anchorLock.unlock()
    }

    private func finalize(_ s: Int) {
        guard var f = pendingFrames.removeValue(forKey: s) else { return }
        let c = confidences.take(second: s)
        f.t = Double(s)
        f.snore = c.snore
        f.talk = c.talk
        f.cough = c.cough
        f.breathing = c.breathing
        f.environment = c.environment
        f.noiseFloorDb = floorTracker.push(f.levelDb)
        if s <= selfPlaybackUntilSecond { f.flags |= 1 }
        topLabels[s] = c.topLabel
        topLabels.removeValue(forKey: s - 600)
        sampleAtSecond.removeValue(forKey: s - 600)
        frames.append(f)
        writer.append(f)
        lastFinalizedSecond = s
        statsLock.lock()
        _framesWritten += 1
        statsLock.unlock()
        onSecond?(f.aboveFloorDb, c.topLabel)

        for update in tracker.process(f) { handle(update) }

        let epoch = s / Int(config.tuning.staging.epochLength)
        if epoch > currentEpoch {
            currentEpoch = epoch
            emitLiveEpochs()
        }
    }

    private func emitLiveEpochs() {
        let completed = frames.filter { $0.t < Double(currentEpoch) * config.tuning.staging.epochLength }
        guard !completed.isEmpty else { return }
        let epochs = EpochBuilder.build(frames: completed, duration: Double(currentEpoch) * config.tuning.staging.epochLength, tuning: config.tuning)
        let live = Stager.liveEpochs(epochs, tuning: config.tuning.staging)
        onEpoch?(live.epochs, live.hasOnset)
    }

    private func handle(_ update: EventTracker.Update) {
        switch update {
        case let .started(id, group, start):
            guard AppSettings.storesClips(for: group) else { return }
            if group == .snore {
                let block = Int(start / config.tuning.clips.snoreBlockSeconds)
                let used = snoreClipsPerBlock[block, default: 0]
                guard used < config.tuning.clips.snoreClipsPerBlock else { return }
                snoreClipsPerBlock[block] = used + 1
            }
            guard let startSample = sampleAtSecond[Int(start)] else { return }
            let from = startSample - Int64(config.tuning.clips.preRoll * Self.sampleRate)
            let name = String(format: "%05d_%@_%@.m4a", Int(start), group.rawValue, String(id.uuidString.prefix(6)))
            clips.start(id: id, from: from, url: config.folder.appendingPathComponent("clips").appendingPathComponent(name))
        case var .finished(event):
            event.label = dominantLabel(for: event)
            if clips.isActive(event.id) {
                pendingEvents[event.id] = event
                let endSecond = Int(event.end) - 1
                let endSample = (sampleAtSecond[endSecond] ?? streamSample) + Int64(Self.sampleRate)
                    + Int64(config.tuning.clips.postRoll * Self.sampleRate)
                clips.stop(id: event.id, at: endSample)
            } else {
                write(event)
            }
        case let .cancelled(id):
            clips.cancel(id: id)
        }
    }

    private func dominantLabel(for event: SoundEvent) -> String {
        var counts: [String: Int] = [:]
        var s = Int(event.start)
        while s < Int(event.end) {
            if let label = topLabels[s], !label.isEmpty { counts[label, default: 0] += 1 }
            s += 1
        }
        return counts.max { $0.value < $1.value }?.key ?? event.group.rawValue
    }

    private func clipFinished(_ f: ClipRecorder.Finished) {
        guard var event = pendingEvents.removeValue(forKey: f.id) else { return }
        event.clipFile = "clips/" + f.fileName
        event.waveform = f.waveform
        write(event)
    }

    private func write(_ event: SoundEvent) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        try? eventsHandle?.write(contentsOf: data + Data("\n".utf8))
        statsLock.lock()
        _eventCount += 1
        statsLock.unlock()
        log.log("event", ["group": event.group.rawValue, "label": event.label, "start": "\(Int(event.start))",
                          "duration": String(format: "%.1f", event.duration), "clip": event.clipFile ?? "-"])
    }

    /// Flushes everything to disk. Call once when the night is over.
    func finish() {
        analysisQueue.sync { analyzer?.completeAnalysis() }
        queue.sync {
            guard !finished else { return }
            for s in pendingFrames.keys.sorted() { finalize(s) }
            for update in tracker.flush() { handle(update) }
            clips.finishAll()
            for (_, event) in pendingEvents { write(event) }
            pendingEvents.removeAll()
            writer.close()
            nightFile = nil
            try? eventsHandle?.close()
            eventsHandle = nil
            finished = true
        }
    }
}
