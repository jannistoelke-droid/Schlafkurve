---
name: ios-overnight-audio
description: How to capture and analyse microphone audio on iPhone for a whole night while the phone is locked - AVAudioSession setup, background audio mode, AVAudioEngine tap, format conversion, ring buffer, interruptions, watchdog, file protection, energy. Use when writing or debugging AudioCaptureService, NightPipeline, ClipRecorder plumbing, the night screen, or any "recording stops in the background" problem.
---

# Overnight audio capture on iOS

Goal: one continuous, gap-aware audio stream from the built-in microphone from "Start" until the alarm is stopped, with the phone locked, on charger, for 6-10 hours.

## The rules that keep the app alive (Apple DTS guidance, 2026)
1. `UIBackgroundModes` contains `audio` (set in `project.yml` Info.plist properties).
2. Configure **and activate** the `AVAudioSession` **while the app is in the foreground** (inside the Start button action). An app with the audio background mode and an *active* session may run indefinitely; `backgroundTimeRemaining` reports infinity.
3. Keep the session active all night. Do not call `setActive(false)` until the session ends.
4. Do not use higher-level APIs that activate/deactivate the shared session on their own while tracking (e.g. system players, speech recognisers, anything that "manages the audio session for you"). Transcription and clip playback happen after the night.
5. Do **not** use `beginBackgroundTask` tricks, silent-audio hacks, VoIP/CallKit or location to stay alive. DTS calls them unnecessary or harmful. If the process dies, read the crash log / `runningboardd` messages instead of piling on workarounds.
6. If the app still gets killed in testing: check memory growth (jetsam), CPU in background (CPU-resource kills), and the crash log reason before changing the session setup.

## Session configuration
```swift
import AVFAudio

func configureSessionInForeground() throws {
    let s = AVAudioSession.sharedInstance()
    // .playAndRecord: we record all night AND play the gentle pre-alarm through the same session.
    // .defaultToSpeaker: otherwise playback goes to the earpiece receiver.
    // .mixWithOthers: other apps' playback mixes instead of interrupting us.
    // No Bluetooth options: always the built-in mic.
    try s.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
    if let builtIn = s.availableInputs?.first(where: { $0.portType == .builtInMic }) {
        try s.setPreferredInput(builtIn)
    }
    try s.setActive(true)
}
```
- `.measurement` minimises system processing (AGC etc.), which keeps levels comparable across the night. If the pre-alarm is too quiet in `.measurement`, switch only the mode with `setMode(.default)` right before playing – no deactivation. Record the result of this test in `docs/DECISIONS.md`.
- Verify option names against the current SDK (e.g. the Bluetooth option was renamed to `.allowBluetoothHFP` in iOS 26 – we do not use it anyway).
- Request mic permission with `AVAudioApplication.requestRecordPermission()` on the setup screen, never at night.

## Engine graph
```
inputNode (hardware format, usually 48 kHz mono) ── tap ──▶ hand-off
playerNode (pre-alarm sound) ──▶ mainMixerNode ──▶ outputNode
```
```swift
let input = engine.inputNode
let hwFormat = input.outputFormat(forBus: 0)
input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [pipeline] buffer, when in
    pipeline.ingest(buffer, at: when)   // copies samples, enqueues, returns immediately
}
engine.prepare()
try engine.start()
```
- The tap block must not allocate heavily, lock for long, log per buffer, or `await`. Copy into a pooled `AVAudioPCMBuffer` (or a preallocated ring) and dispatch to one **serial processing queue**.
- On the processing queue: (a) feed the original-format buffer to `SNAudioStreamAnalyzer.analyze(_:atAudioFramePosition:)` (see `sound-event-detection`; keep that analyzer on its own serial queue), (b) convert to 16 kHz mono Float32 with one long-lived `AVAudioConverter`, (c) push into the 30 s clip ring buffer, (d) accumulate 1 s frames for feature extraction.
- Keep a monotonically increasing `framePosition` (samples since start) – it drives timestamps and the analyzer.

## Time base
- At start store `anchorDate = Date()` and `anchorSample = 0`. Timestamp of any sample = `anchorDate + (sample - anchorSample) / sampleRate`.
- After an interruption or engine restart, insert a gap record and re-anchor with a fresh `Date()`; never assume continuity across a restart.

## Interruptions and other notifications
Observe and log each to `eventlog.jsonl`:
- `AVAudioSession.interruptionNotification`: on `.began` record gap start (engine stops). On `.ended` try `setActive(true)` + `engine.start()`. In the background this can fail with "session activation failed" after a phone call – log it, keep the AlarmKit backup as safety, and retry when the app returns to the foreground (`scenePhase == .active`).
- `AVAudioSession.mediaServicesWereResetNotification`: rebuild engine + session (only possible in foreground → if in background, log, mark gap, retry later).
- `AVAudioEngineConfigurationChange` (`.AVAudioEngineConfigurationChange`): re-install tap with the new format and restart.
- `AVAudioSession.routeChangeNotification`: re-assert built-in mic as preferred input.
- `UIApplication.didReceiveMemoryWarningNotification`, `ProcessInfo.thermalStateDidChangeNotification`, battery level every 15 min (`UIDevice.current.isBatteryMonitoringEnabled = true`).

## Watchdog / flat-line detection
- Every 10 s on a timer (DispatchSourceTimer on a utility queue, not the main run loop): check `lastBufferHostTime`. If no buffer for > 30 s → log `flatline`, mark gap, attempt engine restart once per minute.
- Also flag "digital silence" (all-zero samples for > 60 s) as a data-quality problem, not as quiet sleep.
- Heartbeat line in the event log every 60 s: buffer age, frames written, events so far, battery, thermal state, free disk.

## Storage while locked
- Write into `Application Support/Sessions/<id>/`. Create the folder in the foreground at Start.
- File protection must stay at the default `completeUntilFirstUserAuthentication`. Never `FileProtectionType.complete` – writes would fail once the phone locks.
- Append-only writers with small periodic flushes (frames every 60 s, events on close). On crash at most one minute of features is lost.
- Clips: `AVAudioFile(forWriting:settings:)` with `kAudioFormatMPEG4AAC`, 16 kHz, mono, ~32 kbps; close the file when the clip ends.
- Optional full-night file: one AAC writer fed from the 16 kHz stream (~24 kbps ≈ 86 MB / 8 h). Refuse if free space < 2 GB.

## Energy and CPU
- Sleep Cycle states about 30 % battery per night without a charger – recommend the charger, warn at < 30 % when not charging.
- No SwiftUI updates while `scenePhase != .active` (pause timers/observers that drive the night screen).
- FFT sizes power of two, reuse `vDSP` setups, no per-frame allocations.
- There is no Mac, so no Instruments: log process CPU time (`getrusage(RUSAGE_SELF)` delta per minute), battery level and thermal state in every heartbeat line, and compare battery drain per hour across test sessions. Note the numbers in `docs/DECISIONS.md`.

## Night screen
- Pure black background, large clock, alarm window, small level meter (toggleable), hold-to-stop.
- "Nachttisch-Modus": `UIApplication.shared.isIdleTimerDisabled = true` only while charging, brightness hint, screen content minimal. This is the fallback if background capture ever proves unreliable on a given iOS version.

## Testing checklist (device only – the simulator does not reproduce background behaviour; results come back via the in-app export, see `ios-build-deploy`)
1. Start test session, lock phone, wait 15 min, unlock: no gap, heartbeat every 60 s.
2. During a session play music from another app: we keep recording (mixWithOthers).
3. Call the phone (or trigger Siri) during a session: gap is logged, recording resumes or AlarmKit backup still fires.
4. Plug/unplug charger and headphones: input stays built-in mic.
5. Run 60 min locked: memory flat in the heartbeat lines.
