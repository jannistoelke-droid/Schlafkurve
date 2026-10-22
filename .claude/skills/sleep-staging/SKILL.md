---
name: sleep-staging
description: Algorithms for estimating sleep stages (wake, light, deep, REM) from bedside phone audio - per-second DSP features, movement detection, breathing rate and regularity, 30 s epochs, activity scoring, rule-based staging with HMM/Viterbi smoothing, sleep onset, awakenings, sleep-depth curve and sleep quality score. Use when working in SleepEngineCore on features, EpochBuilder, Stager, QualityScorer, Tuning, the synthetic-night tests or the re-analysis mode of sleepreplay.
---

# Sleep staging from sound

## What the evidence supports (set expectations in code comments and UI)
- Sleep Cycle's original patent classifies sleep from the **statistical properties of movement sounds** into calm deep sleep, light sleep with arousals, and awake periods. Since 2024/25 Sleep Cycle adds **breathing patterns** to estimate REM.
- Research: audio-only deep learning reaches roughly 70 % epoch agreement for 4 classes (wake/light/deep/REM) on smartphone-grade microphones (Hong et al., Nat Sci Sleep 2022); simpler networks reached 87 % for 3 macro stages (wake/NREM/REM) in a lab (Dafna et al., Sci Rep 2018).
- Our v1 is a transparent heuristic + HMM. Optimise for: correct sleep onset, correct awakenings, plausible deep blocks early in the night, and a reliable light/wake signal inside the alarm window. REM is a labelled estimate.

## Pipeline
```
16 kHz mono ─▶ FrameFeatures (every 1 s) ─▶ frames.bin
FrameFeatures + SoundFrame ─▶ MovementDetector, BreathingAnalyzer
                           ─▶ EpochFeatures (every 30 s)
EpochFeatures ─▶ ActivityScore ─▶ per-night normalisation ─▶ stage evidence
stage evidence ─▶ HMM / Viterbi ─▶ stages[], depth curve, onset, awakenings ─▶ QualityScorer
```
Live mode (during the night) runs the same code on the epochs so far (causal, only past data) to feed the WakeDecider. Final mode (after stop) re-runs everything over the whole night (non-causal smoothing allowed). Both live in `SleepEngineCore` and must be deterministic.

## 1. FrameFeatures (1 s, from 16 kHz audio – computed in `SleepEngineDSP` with vDSP, Apple only)
Analysis window 2048 samples, hop 512 (≈31 frames/s) aggregated into 1 s:
- `levelDb`: RMS in dBFS; `peakDb`
- `noiseFloorDb`: rolling 10th percentile of `levelDb` over the last 300 s (live) / centred window (final)
- `aboveFloorDb = levelDb - noiseFloorDb`
- band energies (dB): 60–250, 250–1000, 1000–4000, 4000–8000 Hz
- `flatness`: spectral flatness (geometric/arithmetic mean), 250–8000 Hz
- `flux`: mean positive spectral flux; `onsetCount`: sub-frames with flux above adaptive threshold
- `envelope`: **4 Hz** series of 100–1500 Hz band energy (4 values per second, stored in frames.bin). Everything after this point – including breathing – works only on frames.bin data, so live analysis, in-app re-analysis and `sleepreplay --frames` on Windows give identical results.
- classifier group confidences from `sound-event-detection` (snore, talk, cough, breathing, environment)
Binary layout of `frames.bin`: fixed-size little-endian records with a small header (version, sampleRate, start time). Write a reader in the package; version the format.

## 2. MovementDetector
A movement sound (bed sheets, mattress, body turning) is: broadband (`flatness ≥ 0.35`), above floor by ≥ 6 dB, duration 0.3–8 s, onset-rich, and **not** confidently snore/talk/cough/environment (group conf < 0.4).
Output per second: `movement: Bool`, `movementEnergy = max(0, aboveFloorDb)` when movement.
Long continuous movement (> 30 s) usually means awake / getting up.

## 3. BreathingAnalyzer
- Sliding 60 s window, hop 30 s, over the 4 Hz envelope (high-pass to remove slow drift, then normalise). Pure Swift autocorrelation – 240 samples per window is cheap without Accelerate.
- Autocorrelation; search lags 2.0–7.0 s (≈ 8.5–30 breaths/min). If snoring is present, the snore pulse train gives a clean period – prefer it.
- `breathRate = 60 / lagPeak`, `breathRegularity = normalised ACF peak height` (0–1), `breathRateVar` = std of breathRate over the last 5 windows.
- If the envelope is too weak (< 2 dB modulation) or movement occupies > 20 % of the window → `breathRate = nil` (unknown, not zero).

## 4. EpochFeatures (30 s, aligned to session start)
`movementSeconds, movementCount, movementEnergySum, maxAboveFloorDb, breathRate?, breathRegularity?, breathRateVar?, snoreSeconds, talkSeconds, coughCount, environmentSeconds, gap: Bool`.
Epochs overlapping a data gap get `gap = true` and are excluded from statistics.

## 5. Activity score (Cole–Kripke style)
```
a[t] = log1p(w1*movementEnergySum[t] + w2*movementSeconds[t] + w3*talkSeconds[t])
D[t] = Σ k_i * a[t+i]   for i in -4…+2   (final mode)   |   i in -6…0 (live mode)
kernel default: [0.04, 0.06, 0.10, 0.20, 0.35, 0.15, 0.10] (normalised)
z[t] = (D[t] - median(D)) / (1.4826 * MAD(D) + ε)        per night (live: night-so-far, min 30 epochs, else population defaults)
```
Per-night normalisation matters: phone distance and room acoustics change absolute levels every night.

## 6. Stage evidence (soft scores 0–1 per stage, all thresholds in `Tuning.staging`)
- **Wake**: `σ((z - 1.0)/0.3)`; boosted to ≥ 0.9 if movementSeconds ≥ 20 or (talkSeconds ≥ 3 and movementSeconds ≥ 3); everything before sleep onset is wake.
- **Deep**: requires ≥ 10 min (20 epochs) without movement ending at t, `breathRegularity ≥ 0.6`, `breathRateVar ≤ 1.0`; score scaled by a circadian prior that is higher in the first 3 h after onset (×1.2) and lower after 5 h (×0.6). Snoring is allowed in deep sleep.
- **REM**: low movement (z ≤ 0) but **irregular** breathing (`breathRegularity < 0.45` or `breathRateVar > 2.0`), at least 60 min after onset, prior increasing towards morning (×0.6 in first 2 h, ×1.3 after 5 h). Little or no snoring raises REM slightly.
- **Light**: `1 - max(others)` floor 0.2 – the default state.
- Unknown breathing (`nil`) → deep and REM evidence fall back to movement-only rules with lower confidence (deep needs 15 min stillness then).

## 7. HMM smoothing (Viterbi)
States W, L, D, R. Emissions = normalised evidence scores. Transition matrix per 30 s epoch (defaults, rows sum to 1):
| from \\ to | W | L | D | R |
|---|---|---|---|---|
| W | 0.88 | 0.11 | 0.00 | 0.01 |
| L | 0.04 | 0.90 | 0.04 | 0.02 |
| D | 0.01 | 0.07 | 0.92 | 0.00 |
| R | 0.03 | 0.05 | 0.00 | 0.92 |
- No W→D and no D→R direct transitions (physiology: deep is entered via light; REM follows light).
- Post-rules: minimum run length 2 epochs for W inside sleep (shorter → light), deep blocks < 3 epochs → light.
- Live mode: forward algorithm (filtering) for the latest epoch; final mode: full Viterbi.

## 8. Derived metrics
- **Sleep onset**: first epoch that starts a 10-minute window with ≤ 1 movement epoch and z ≤ 0. `latency = onset - sessionStart`.
- **Final awakening**: last transition to sustained W (≥ 3 epochs) before the end, or the alarm time.
- **Asleep time** = epochs in L/D/R between onset and final awakening (excluding gaps).
- **Awakenings** = W runs ≥ 2 epochs after onset.
- **Depth curve** (Sleep Cycle style wave, 0 = awake … 1 = deep): `depth = smooth( 0.6*(1 - σ(z)) + 0.4*breathRegularity )`, Gaussian smoothing σ = 3 epochs, clamped; drawn with W at top.
- Stage shares in minutes and percent; reference ranges for the info sheet: deep ~10–20 %, REM ~10–25 % of the night (Sleep Cycle's own explainer).

## 9. Sleep quality score (0–100), modelled on Sleep Cycle's factors
Sleep Cycle uses time in bed, time in deep sleep, frequency/intensity of movements and the number of awake moments, calibrated personally. v1:
```
duration   = clamp(asleepMin / goalMin, 0, 1)          * 40
deep       = clamp(deepShare / 0.18, 0, 1)             * 20
continuity = clamp(1 - awakenings / 6, 0, 1)           * 15
calm       = clamp(1 - movementRatePerHour / 40, 0, 1) * 15
latency    = (latencyMin <= 15 ? 1 : latencyMin <= 30 ? 0.6 : 0.3) * 10
score = round(sum)
```
After ≥ 7 nights add a personal mode: show the percentile of tonight versus own history next to the absolute score.

## 10. Testing
- `SyntheticNight` generator (seeded): pink-noise floor, breathing envelope with configurable rate/regularity per segment, rustle bursts (broadband 0.5–4 s), snore pulse trains, speech-like bursts. Script a night: 15 min awake with movement → onset → 40 min deep (regular breathing, no movement) → light → REM (irregular breathing, still) … → light at 06:40 with movement.
- Assertions: onset within ±2 epochs, deep block detected ≥ 70 % of its epochs, REM block ≥ 50 %, awakenings counted, WakeDecider fires in the light segment.
- Property tests: invariance to a constant gain change (+12 dB) thanks to normalisation; no crash on empty/short sessions; gaps never counted as sleep.
- `sleepreplay --frames <frames.bin> --compare` re-runs staging with current `Tuning` and prints per-stage minutes before/after plus the epoch-level agreement with the previous run (and with an Apple-Watch hypnogram if one is supplied as CSV).
