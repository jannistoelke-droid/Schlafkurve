# Entscheidungen

Format: `## YYYY-MM-DD – Titel` · Entscheidung · Warum · Verworfene Alternativen.

## 2026-10-21 – Ausgangsentscheidungen aus der Recherche
- **Plattform:** natives SwiftUI, iOS 26.0+ (iPhone 14 Pro) – nötig für AlarmKit und SpeechAnalyzer. Cross-Platform-Frameworks verworfen: AlarmKit, AVAudioSession-Feinsteuerung und SoundAnalysis bräuchten ohnehin nativen Code.
- **Kein Mac:** Entwicklung unter Windows 10, Build/Test auf GitHub Actions (`macos-26`, neueste stabile Xcode 26.x), unsignierte IPA, Installation per Sideloadly mit kostenloser Apple-ID. Verworfen: macOS-VM auf dem PC (Lizenz, und Xcode 27 braucht Apple silicon), gemieteter Cloud-Mac (kostet), Expo/EAS (Geräte-Builds brauchen bezahlten Account, native APIs fehlen).
- **Repo öffentlich** (Empfehlung, Entscheidung in Phase 0): kostenlose macOS-Minuten; Repo enthält keine persönlichen Daten.
- **Projektdatei:** XcodeGen auf dem CI-Server – keine `.xcodeproj`-Pflege ohne Xcode.
- **Engine-Schnitt:** `SleepEngineCore` reines Swift (auch unter Windows testbar), `SleepEngineDSP`/`SleepEngineAudio` Apple-only.
- **Keine App-Extensions in v1:** jede Extension kostet bei kostenloser Signierung eine App-ID; deshalb kein AlarmKit-Countdown, Schlummern über `.custom`-Intent.
- **Wecker:** AlarmKit-Backup zur spätesten Zeit + Ersatzalarm bei Smart-Auslösung; sanfter Vorlauf über die laufende Audio-Session.
- **Erkennung:** Apples Klangklassifikator (`.version1`) + eigene DSP für Bewegung und Atmung.
- **Phasen:** transparente Heuristik + HMM; `frames.bin` ermöglicht Re-Analyse in der App und unter Windows.
- **Daten zurück auf den PC:** In-App-Export (iTunes-Dateifreigabe / iCloud Drive), nie über GitHub.

## 2026-10-22 – Umsetzung Engine + App-Services (Cloud-Session ohne Compiler)
- **Swift-5-Sprachmodus** statt Swift 6 strict concurrency: es gibt keinen lokalen Compiler, jeder Concurrency-Fehler kostet eine CI-Runde; für eine Einzelnutzer-App ohne Mehrwert.
- **FFT in reinem Swift** in `SleepEngineCore` statt Accelerate: portabel (Linux-CI, Windows), testbar, < 1 % CPU.
- **JSON-Dateien statt SwiftData**: weniger Makro-/Migrationsrisiko, Nächte bleiben als Ordner exportierbar.
- **REM-Zuweisung** nur im Endbericht: lange, ruhige Leichtschlaf-Abschnitte ≥ 60 min nach Einschlafen – mit unregelmäßiger Atmung, oder (ohne messbare Atmung) kurz nach Tiefschlaf bzw. spät in der Nacht.
- **CI**: Engine-Tests auf Ubuntu (schnell, jeder Push); iOS-Build nur auf `main`; IPA als Release `latest` (öffentlicher Download, Annotations für Compilerfehler).
