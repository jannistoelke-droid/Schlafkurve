---
name: sound-event-detection
description: Detect snoring, sleep-talking, coughing, environmental and loud noises in the night audio stream with Apple's SoundAnalysis classifier plus energy gating, turn frame-level confidences into events with hysteresis, and save short AAC clips with pre-roll. Use when working on the classifier wrapper, label mapping, EventTracker, ClipRecorder, clip retention, event relabelling, sleep-talk transcription or a custom Create ML sound model.
---

# Sound event detection and clips

## Classifier
```swift
import SoundAnalysis

let analyzer = SNAudioStreamAnalyzer(format: hwFormat)          // hardware tap format
let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
// Check request.windowDurationConstraint before changing windowDuration.
request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48_000)
request.overlapFactor = 0.5
try analyzer.add(request, withObserver: observer)   // observer: SNResultsObserving
// on the dedicated analysis queue:
analyzer.analyze(buffer, atAudioFramePosition: framePosition)
```
- Observer receives `SNClassificationResult` with `timeRange` and `classifications` (identifier + confidence). Use `classification(forIdentifier:)` for the labels we track; do not only take the top-1.
- Run the analyzer on its own serial queue; never call `analyze` from the tap block.
- The CI job "List SoundAnalysis labels" runs `sleepreplay --list-labels` (prints `knownClassifications` on the macOS runner) and uploads `soundanalysis-labels.txt` as an artifact – download it with `gh run download <id> -n soundanalysis-labels` and commit it to `docs/`. Build the mapping below **only from identifiers that exist in that list**; at runtime log a warning to the event log for any mapping entry that is missing on the device.
- The same wrapper works on macOS with `SNAudioFileAnalyzer(url:)` – the `sleepreplay --audio` mode uses it on CI, so keep the wrapper in `SleepEngineAudio` (sources wrapped in `#if canImport(SoundAnalysis)` so the package still builds on Windows). The `EventTracker` state machine itself is pure Swift and lives in `SleepEngineCore`.

## Label groups (verify every identifier against knownClassifications)
| Group (UI) | Candidate identifiers |
|---|---|
| Schnarchen (snore) | `snoring` |
| Reden (talk) | `speech`, `whispering`, `shout`, `yell`, `screaming`, `babble`, `laughter`, `giggling`, `chuckle_chortle`, `crying_sobbing` |
| Husten (cough) | `cough`, `sneeze`, `nose_blowing` (+ `throat_clearing` if present) |
| Atmung (breathing, feature only - not an event) | `breathing`, `gasp`, `sigh` |
| Umgebung (environment) | `dog*`, `cat*`, door/knock, vehicle/traffic, siren, music/singing, television if present, alarm/beep, rain/wind |
| Laut (loud, unclassified) | no confident label but level ≥ noiseFloor + `Tuning.events.loudAboveFloorDb` (default 18 dB) |

Keep the mapping in `SleepEngineAudio/LabelMapping.swift` as data, not scattered `if`s.

## Per-second fusion
For each 1 s frame produce `SoundFrame { snore, talk, cough, breathing, environment: Float, topLabel, levelDb, aboveFloorDb }` = max confidence of the group over classifier windows overlapping that second. Store these in `frames.bin` together with the DSP features (see `sleep-staging`).

## EventTracker (hysteresis state machine per group)
Defaults live in `Tuning.events`:
| Group | start ≥ | keep ≥ | min on-time | end after below | merge gap | min event | max clip |
|---|---|---|---|---|---|---|---|
| snore | 0.55 for 2 frames | 0.35 | 2 s | 4 s | 20 s → episode | 6 s | 30 s |
| talk | 0.60 for 1 frame | 0.40 | 0.8 s | 2 s | 5 s | 0.8 s | 60 s |
| cough | 0.60 for 1 frame | 0.40 | 0.3 s | 1 s | 3 s | 0.3 s | 10 s |
| environment | 0.70 for 2 frames | 0.50 | 1 s | 2 s | 10 s | 1 s | 20 s |
| loud | aboveFloor ≥ 18 dB, no confident label | – | 0.3 s | 1 s | 3 s | 0.3 s | 10 s |
- Energy gate: a frame only counts if `aboveFloorDb ≥ Tuning.events.minAboveFloorDb` (default 6 dB). Prevents faint TV/neighbour speech from becoming events.
- Sensitivity setting (niedrig/mittel/hoch) shifts start thresholds by +0.1 / 0 / -0.1 and the energy gate by +3 / 0 / -3 dB.
- Priority if several groups fire at once: talk > cough > snore > environment > loud (a snort during speech is speech).
- Snore episodes: consecutive snore events with gaps < 20 s merge into one episode; the report counts episodes and total snore seconds.
- Each finished event: `SoundEvent { id, group, topLabel, start, end, peakDb, meanConfidence, clipFile?, waveform[64], isFavorite, userGroup? }`.

## Clip recording
- 30 s ring buffer of 16 kHz mono Float32 (~1.9 MB) on the processing queue.
- On event start: open a clip writer, write the last `Tuning.clips.preRoll` (3 s) from the ring, then stream live samples until event end + `Tuning.clips.postRoll` (2 s) or `max clip` reached.
- Snore budget: at most 2 clips per 15-minute block, choose the loudest/most confident; the rest of the snore episode is still counted, just without audio.
- Talk: keep every clip. Cough/environment/loud: keep, subject to retention settings.
- Waveform: 64 peak values computed while writing, stored in the event (no re-decoding for list rows).
- File names `clips/<HHmmss>_<group>_<short-id>.m4a`. Never write clips with `.complete` file protection.
- Retention job (on app launch, foreground): delete clips older than the setting unless favourited; never delete `frames.bin` automatically.

## Relabelling and learning loop
- In the report the user can change an event's group (or mark "falsch – nichts"). Store `userGroup`; statistics use `userGroup ?? group`.
- `/night-review` uses these corrections to compute per-group precision and to tune thresholds.
- Later: export labelled clips as `dataset/<label>/*.wav` → Create ML Sound Classifier on the Mac → add the `.mlmodel` and run it via `SNClassifySoundRequest(mlModel:)` alongside or instead of `.version1`. Keep the classifier behind a protocol so this swap is one line.

## Sleep-talk transcription (later phase)
- After the session ended and the app is in the foreground: run `SpeechAnalyzer` with a `SpeechTranscriber` for `de_DE` (check `SpeechTranscriber.supportedLocales`/`installedLocales`, download the asset via the system once) over each talk clip. Store the transcript on the event, label it "experimentell".
- Never run speech recognition during the night (it may manage the audio session and costs energy).

## Tests
- Unit tests for EventTracker with scripted confidence sequences (start/keep/end/merge/priority/energy gate).
- Integration test in `sleepreplay`: run on a recorded test session (user snores/talks/coughs on purpose in Phase 3) and assert the expected event counts within tolerance.
