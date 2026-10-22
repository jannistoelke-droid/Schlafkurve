import AVFoundation
import Foundation

/// Owns the audio session and the engine for the whole night.
/// Rule: the session is configured and activated in the foreground (Start) and stays active.
final class AudioCaptureService {
    enum CaptureError: LocalizedError {
        case noInput
        var errorDescription: String? { "Kein Mikrofon verfügbar." }
    }

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let playerFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var observers: [NSObjectProtocol] = []
    private weak var pipeline: NightPipeline?
    private var fadeTimer: DispatchSourceTimer?
    private(set) var isCapturing = false
    private var lastRestartAttempt = Date.distantPast

    var log: ((String, [String: String]) -> Void)?

    var engineRunning: Bool { engine.isRunning }

    // MARK: session

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(mic)
        }
        try session.setActive(true)
        log?("session_active", ["route": routeDescription(), "rate": "\(session.sampleRate)"])
    }

    private func routeDescription() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let inputs = route.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = route.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        return "in:\(inputs) out:\(outputs)"
    }

    // MARK: lifecycle

    func start(pipeline: NightPipeline) throws {
        self.pipeline = pipeline
        try activateSession()
        buildGraph()
        try startEngine()
        addObservers()
        isCapturing = true
    }

    private func buildGraph() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.pipeline?.ingest(buffer)
        }
        engine.prepare()
        try engine.start()
        log?("engine_started", ["format": "\(format.sampleRate) Hz x\(format.channelCount)"])
    }

    func stop() {
        isCapturing = false
        stopPreAlarm()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log?("engine_stopped", [:])
    }

    /// Watchdog / foreground recovery. Returns true if the engine runs afterwards.
    @discardableResult
    func restartIfNeeded(reason: String) -> Bool {
        guard isCapturing else { return false }
        if engine.isRunning { return true }
        guard Date().timeIntervalSince(lastRestartAttempt) > 30 else { return false }
        lastRestartAttempt = Date()
        pipeline?.noteGapReason(reason)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try startEngine()
            log?("engine_restarted", ["reason": reason])
            return true
        } catch {
            log?("engine_restart_failed", ["reason": reason, "error": "\(error)"])
            return false
        }
    }

    // MARK: notifications

    private func addObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            self.log?("route_change", ["reason": "\(reason)", "route": self.routeDescription()])
            if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }), session.preferredInput?.portType != .builtInMic {
                try? session.setPreferredInput(mic)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            self?.handleMediaServicesReset()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? AVAudioEngine) === self.engine else { return }
            self.log?("engine_config_change", [:])
            self.pipeline?.noteGapReason("config_change")
            do { try self.startEngine() } catch { self.log?("engine_config_restart_failed", ["error": "\(error)"]) }
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            log?("interruption_began", [:])
            pipeline?.noteGapReason("interruption")
        case .ended:
            log?("interruption_ended", [:])
            lastRestartAttempt = .distantPast
            restartIfNeeded(reason: "interruption")
        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        log?("media_services_reset", [:])
        pipeline?.noteGapReason("media_reset")
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        do {
            try activateSession()
            buildGraph()
            try startEngine()
        } catch {
            log?("media_reset_restart_failed", ["error": "\(error)"])
        }
    }

    // MARK: gentle pre-alarm

    func startPreAlarm(duration: TimeInterval) {
        guard engine.isRunning, let buffer = Self.chime(format: playerFormat) else {
            log?("prealarm_skipped", ["engine": "\(engine.isRunning)"])
            return
        }
        player.stop()
        player.volume = 0.04
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
        log?("prealarm_started", ["duration": "\(Int(duration))"])
        let steps = max(1, Int(duration / 0.5))
        var step = 0
        fadeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            step += 1
            self.player.volume = min(1, 0.04 + 0.96 * Float(step) / Float(steps))
            if step >= steps { self.fadeTimer?.cancel() }
        }
        timer.resume()
        fadeTimer = timer
    }

    func stopPreAlarm() {
        fadeTimer?.cancel()
        fadeTimer = nil
        if player.isPlaying {
            player.stop()
            log?("prealarm_stopped", [:])
        }
    }

    /// A soft, slowly decaying three-tone chime (4 s, looped).
    static func chime(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let length = AVAudioFrameCount(rate * 4)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = length
        let notes: [(freq: Double, offset: Double)] = [(523.25, 0), (659.25, 0.45), (783.99, 0.9)]
        for i in 0..<Int(length) {
            let t = Double(i) / rate
            var v = 0.0
            for note in notes where t >= note.offset {
                let local = t - note.offset
                let envelope = min(1, local / 0.02) * exp(-local * 1.6)
                v += envelope * (sin(2 * .pi * note.freq * local) + 0.25 * sin(4 * .pi * note.freq * local))
            }
            data[i] = Float(v * 0.22)
        }
        return buffer
    }
}
