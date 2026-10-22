# STATUS – Übergabe an Claude Code (Stand 22.10.2026)

> **Für Claude Code:** Lies diese Datei zuerst, dann `CLAUDE.md` und `MASTER_PROMPT.md`. Mach genau hier weiter.
> **Wochenlimit:** Der Nutzer will aufhören, bevor sein Wochenlimit **83 %** erreicht. Du kannst es nicht sehen.
> Halte nach **jeder Phase** an, committe, und bitte ihn, in Claude Code `/usage` zu tippen und dir den Wert zu nennen.

## 0. Erste Schritte (einmalig)
1. Standard-Branch umstellen (aktuell ist versehentlich `wip` der Standard):
   `gh repo edit jannistoelke-droid/Schlafkurve --default-branch main` und danach `git push origin --delete wip`
2. `gh auth status` muss den Nutzer zeigen. CI-Status: `gh run list -L 3`, `gh run watch <id> --exit-status`, Fehler: `gh run view <id> --log-failed`.
   Compilerfehler stehen zusätzlich als Annotations im Run (Workflow schreibt `error:`-Zeilen als `::error::`).

## 1. Fertig und getestet ✅
`Packages/SleepEngine` (reines Swift, CI-Job `engine` auf Linux grün):
- `FeatureExtractor` (eigene Radix-2-FFT, 32 Teilframes/s → `FrameFeatures` je Sekunde inkl. 4-Hz-Atemhüllkurve), `NoiseFloorTracker`
- `EventTracker` (Hysterese, Priorität, Mindestdauer, Split), `MovementDetector`, `BreathingAnalyzer`
- `EpochBuilder`, `Stager` (Aktivität, robuster z-Wert, Evidenz, HMM Viterbi/Forward, REM-Zuweisung, Tiefe-Kurve), `WakeDecider`
- `NightAnalyzer` + `QualityScorer` → `NightAnalysis`/`SleepSummary`, `FrameCodec` + `FrameWriter` (`frames.bin`)
- `SyntheticNight` (Tests, Demo-Bericht, Screenshots), `sleepreplay` CLI (`--frames`, `--synthetic`, `--list-labels` nur macOS)
- 20 Tests (`Tests/SleepEngineCoreTests`) – alle grün

## 2. Geschrieben, aber NOCH NIE KOMPILIERT ⚠️
Ohne Mac/Swift-Compiler geschrieben, sorgfältig, aber erwarte ein paar Compilerfehler → über CI beheben.
- `App/Services/AppModels.swift` – `SessionMode`, `SessionMeta`, `AppSettings` (UserDefaults-Keys + Defaults), `Fmt`, deutsche Titel
- `App/Services/DiagnosticsLog.swift` – `eventlog.jsonl` + `recent` für Debug
- `App/Services/SoundClassifier.swift` – `LabelMapping`, `ConfidenceStore`, `ClassifierObserver` (SNClassificationResult → Gruppen je Sekunde)
- `App/Services/ClipRecorder.swift` – 30-s-Ringpuffer, AAC-Clips mit Vor-/Nachlauf, 64er-Wellenform
- `App/Services/NightPipeline.swift` – 16-kHz-Konvertierung, Klassifikator, Features, Rauschboden, Events/Clips, Re-Anchoring bei Lücken, Live-Staging → `onEpoch`
- `App/Services/AudioCaptureService.swift` – Session (`.playAndRecord`/`.measurement`, nur im Vordergrund aktiviert), Engine/Tap, Unterbrechungen, Media-Reset, Config-Change, sanfter Vorlauf (Glocken-Ton, Fade)
- `App/Services/SessionStore.swift` – `SessionFiles` (Dateien, Analyse, ZIP-Export via NSFileCoordinator), `SessionDetail`, `SessionStore`, `ClipPlayer`
- `App/Services/SessionController.swift` – Start (Mikro/Alarm-Erlaubnis, Backup-Alarm zuerst), Live-Weckentscheidung, Vorlauf + Ersatzalarm, Stopp/Schlummern, Endauswertung, Watchdog/Heartbeat, Wiederherstellung abgebrochener Nächte
- `App/Alarm/AlarmService.swift` – AlarmKit (iOS-26-API `AlarmPresentation.Alert(title:secondaryButton:secondaryButtonBehavior:)`, kein Countdown), `StopSleepAlarmIntent`, `SnoozeSleepAlarmIntent`
- `App/SchlafkurveApp.swift` – `@main`, `Theme`, `Card`, `RootView` (Tabs, Nacht-Vollbild, Bericht-Sheet)

## 3. Fehlt noch ❌ (nächste Arbeit, in dieser Reihenfolge)
1. **Views** in `App/Features/` (RootView verweist schon darauf): `SetupView` (Wecker: Zeitrad, Fenster-Chips, Modus, Zusammenfassung, Checkliste, Start), `NightView` (schwarz, Uhr, Status, Pegel, 1,5-s-Halten zum Beenden, „Guten Morgen“-Knopf wenn `wakeTriggered`), `ReportView(sessionID:)` (Kopf, Swift-Charts-Schlafkurve + Phasenbänder + Ereignis-Spur + Scrubber, Kacheln, Aufnahmen-Liste mit `ClipPlayer`, Stimmung/Notizen), `HistoryView`, `StatsView`, `SettingsView` (inkl. Testsession, Export via `ShareLink`, Neu-Analyse, Debug-Zugang), `DebugView`. Vorgaben: Skill `sleep-report-ui`.
2. App-Icon (`App/Assets.xcassets/AppIcon.appiconset`, 1024er PNG) und dann `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in `project.yml` wieder eintragen.
3. Push auf `main` → CI `ios` grün bekommen → IPA laden → Nutzer installiert mit Sideloadly (Phase-0-STOPP aus MASTER_PROMPT).
4. Gerätetests Phase 2–4 laut `MASTER_PROMPT.md`.
5. `scripts/ci-screenshots.sh` + Demo-Startargumente (`-demoReport`, `-demoTab`) für den Screenshot-Job; `README.md` für den Nutzer.

## 4. Schnittstellen, die die Views nutzen sollen
- `SessionController.shared` (`@Observable`, im Environment): `phase`, `current`, `liveLevel`, `liveLabel`, `liveStage`, `captureOK`, `wakeTriggered`, `wokeReason`, `pendingReportID`, `lastError`, `debugLines`; `startNight(test:)`, `stopNight()`, `requestNotificationPermission()`, `batteryText()`, `freeMegabytes()`
- `SessionStore.shared`: `sessions`, `finishedSessions`, `isBusy`, `detail(_:)`, `updateEdit(sessionID:eventID:_:)`, `refreshSummary(_:)`, `save(_:)`, `delete(_:)`, `export(_:)`, `exportAll()`, `reanalyzeAll()`
- `ClipPlayer.shared`: `toggle(id:url:)`, `playingID`, `progress`, `stop()`
- `AlarmService.shared`: `isAuthorized`, `isDenied`, `requestAuthorization()`
- `AppSettings.Key.*` für `@AppStorage` (gleiche Defaults wie in `AppSettings`), `AppSettings.nextWakeDate()`
- `Theme.color(_ stage:)`, `Theme.color(_ group:)`, `Card`, `Fmt.time/duration/day`, `SleepStage.title`, `SoundGroup.title/symbol`, `WakeReason.title`
- Demo-Daten: `SyntheticNight.typical.generate()` + `NightAnalyzer.analyze(...)`

## 5. Bewusste Abweichungen vom ursprünglichen Plan (siehe docs/DECISIONS.md)
- **Swift-5-Sprachmodus** (Paket + App) statt Swift 6 strict concurrency – ohne lokalen Compiler kostet jeder Concurrency-Fehler eine CI-Runde.
- **JSON-Dateien statt SwiftData** (`session.json` mit Zusammenfassung, `analysis.json`, `events.jsonl`, `edits.json`).
- **Keine Accelerate/Paket-Module DSP/Audio**: FFT in reinem Swift in `SleepEngineCore` (läuft überall, auf Linux getestet); AVFoundation/SoundAnalysis-Code liegt in `App/Services`.
- **CI**: Job `engine` auf Ubuntu (jeder Push), Job `ios` auf macOS (nur `main`/manuell). Die IPA wird als Release **`latest`** veröffentlicht:
  https://github.com/jannistoelke-droid/Schlafkurve/releases/download/latest/Schlafkurve.ipa (öffentlicher Download für den Nutzer).
