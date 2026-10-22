# Schlafkurve – project memory for Claude Code

Personal, non-commercial iPhone app that replicates the core of **Sleep Cycle**: set a latest wake-up time plus a wake window, tap Start, record and analyse sound all night, wake the user in a light phase, and show a morning report with a sleep graph and playable clips of snoring, sleep-talking, coughing and other noises. Single user (iPhone 14 Pro), no App Store, no backend, no accounts.

The full product brief and the phase plan live in `MASTER_PROMPT.md`. Background research lives in `docs/RESEARCH.md`. Read both before starting a phase.

## The build setup is unusual – read this first
- The user works on **Windows 10**. There is **no Mac and no local Xcode**. Claude Code runs natively on Windows (Git Bash or PowerShell).
- Every iOS compile, test and package step runs on **GitHub Actions macOS runners** (`.github/workflows/ios.yml`). Loop: edit → commit → push → `gh run watch` → read failures → fix.
- CI produces an **unsigned .ipa** artifact. The user signs and installs it with **Sideloadly** (free Apple ID) on Windows. Re-install every 7 days.
- Pure-Swift engine code (`SleepEngineCore`) also builds and tests **locally on Windows** if the Swift for Windows toolchain is installed (`swift test --package-path Packages/SleepEngine`). Use that fast loop for algorithms; only Apple-framework code needs CI.
- Data from the iPhone comes back as in-app ZIP exports (iTunes file sharing over USB or iCloud Drive) into `device-data/` – never via GitHub.

## Stack (fixed)
- Newest **stable** Xcode on the `macos-26` runner (26.x today; Xcode 27 only when GA on runners), Swift 6 language mode, strict concurrency, `swift-tools-version: 6.0` in Package.swift
- iOS deployment target **26.0** (AlarmKit, SpeechAnalyzer), iPhone only, portrait
- SwiftUI, Swift Charts, SwiftData, AVFoundation/AVFAudio, SoundAnalysis, Accelerate, AlarmKit, AppIntents, OSLog
- **No app extensions in v1** (each extension costs a free-account App ID and complicates sideloading). **No entitlements** beyond what free signing provides.
- **No third-party dependencies** in the app. No network calls at runtime. No analytics.
- Project file generated with **XcodeGen** from `project.yml` on CI (never commit `.xcodeproj`)

## Layout
```
project.yml                  XcodeGen spec (targets, Info.plist keys)
.github/workflows/ios.yml    CI: engine tests, simulator compile, unsigned IPA, optional screenshots
App/                         iOS app (SwiftUI views, services, platform glue)
  Services/                  AudioCaptureService, NightPipeline, ClipRecorder, AlarmService,
                             SessionController, DiagnosticsLog, Persistence, Exporter
  Features/                  Setup, Night, Report, History, Settings, Debug
Packages/SleepEngine/
  Sources/SleepEngineCore    PURE Swift + Foundation only (builds on Windows): models, Tuning,
                             frames.bin codec, EpochBuilder, MovementDetector, BreathingAnalyzer,
                             Stager (rules + HMM), WakeDecider, QualityScorer, SyntheticNight
  Sources/SleepEngineDSP     Accelerate FFT → FrameFeatures (Apple only, wrapped in #if canImport(Accelerate))
  Sources/SleepEngineAudio   AVFoundation + SoundAnalysis: conversion, classifier, label mapping,
                             EventTracker glue, clip writer (#if canImport(SoundAnalysis))
  Sources/sleepreplay        CLI: --frames mode runs everywhere (Windows too); --audio / --list-labels macOS only
  Tests/                     Core tests run on Windows + CI; DSP/Audio tests only on CI
docs/                        RESEARCH.md, DECISIONS.md, NIGHT_LOG.md
device-data/                 exported nights from the iPhone (gitignored – private!)
```

## Commands
- Local engine tests (Windows, if Swift installed): `swift test --package-path Packages/SleepEngine`
- Local re-analysis: `swift run --package-path Packages/SleepEngine sleepreplay --frames "device-data/<night>/frames.bin" --report`
- CI: `git push` → `gh run list -L 3` → `gh run watch <id> --exit-status` → on failure `gh run view <id> --log-failed` (grep `error:` with context, never dump whole logs)
- Get the app: `gh run download <id> --pattern "Schlafkurve-ipa-*" --dir dist/` → user installs `dist/**/*.ipa` with Sideloadly
- Manual CI run (e.g. screenshots): `gh workflow run ios.yml -f screenshots=true`

## Hard rules
1. **Audio session is activated only in the foreground** (on Start) and stays active all night. No high-level APIs that manage the session during tracking. Details: skill `ios-overnight-audio`.
2. Nothing heavy on the audio tap thread: copy, enqueue to a serial processing queue, return.
3. Files written at night keep the default protection class (`completeUntilFirstUserAuthentication`), never `.complete`.
4. The AlarmKit **backup alarm at the latest wake time is scheduled before tracking starts** and only cancelled after a replacement alarm was scheduled successfully.
5. All thresholds live in `SleepEngineCore/Tuning.swift`. No magic numbers elsewhere.
6. Keep `frames.bin` for every night so any night can be re-analysed (also on Windows).
7. Data gaps are recorded and shown as "Datenlücke" – never shown as quiet sleep.
8. Not a medical device: no diagnoses; experimental metrics are labelled "experimentell".
9. **CI round trips are expensive (5–15 min each).** Batch related changes, check Apple API signatures in the docs *before* pushing (`https://developer.apple.com/documentation/<framework>/<symbol>.md` via WebFetch), run local Core tests first, add `[skip ci]` to docs-only commits. Never guess an API and "see if CI accepts it".
10. Keep `main` green. Commit at the end of each phase. Never commit anything from `device-data/` or audio files – the repo may be public.

## Conventions
- UI language German (de_DE); code, comments, identifiers, commit messages English.
- `@MainActor` for UI and SessionController; audio/DSP on dedicated queues; cross-thread state via `Synchronization.Mutex`/`Atomic`.
- `Logger(subsystem: "app.schlafkurve", category: ...)` plus the per-session `eventlog.jsonl` (the only log the user can retrieve without a Mac).
- Time base: wall-clock anchor at session start + sample counter; re-anchor after every interruption.
- Record non-obvious choices in `docs/DECISIONS.md`.

## Skills in this repo
`ios-overnight-audio` · `sound-event-detection` · `sleep-staging` · `smart-alarm` · `sleep-report-ui` · `ios-build-deploy` (CI + Sideloadly; user can run `/ios-build-deploy refresh`) · `night-review` (user runs `/night-review` after a real night)
