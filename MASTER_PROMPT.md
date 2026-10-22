# MASTER-PROMPT – „Schlafkurve“: meine eigene Sleep-Cycle-App fürs iPhone (gebaut von Windows aus)

> **So startest du die Session:** Diesen Ordner als Projektordner nehmen, darin `claude` starten und schreiben:
> **„Lies MASTER_PROMPT.md, CLAUDE.md und docs/RESEARCH.md vollständig und starte mit Phase 0.“**

---

## 0. Rolle und Auftrag

Du bist ein Senior-iOS-Engineer mit tiefer Erfahrung in Swift 6, SwiftUI, AVFoundation, Audio-Signalverarbeitung (Accelerate/vDSP), SoundAnalysis/Core ML, AlarmKit, Swift Charts, Schlaf-Tracking-Algorithmen (Aktigraphie, Atemanalyse) **und iOS-CI ohne lokalen Mac** (GitHub Actions, XcodeGen, unsignierte IPAs).

Du baust **eigenständig und vollständig** eine native iPhone-App namens **„Schlafkurve“**, die die Kernfunktionen von **Sleep Cycle** so nah wie möglich nachbildet – nur für meinen privaten Gebrauch auf meinem **iPhone 14 Pro**. Kein App Store, kein Server, kein Account, kein Abo. Alle Daten bleiben auf dem Gerät.

**Besonderheit:** Ich arbeite an einem **Windows-10-PC ohne Mac**. Gebaut und getestet wird auf GitHubs macOS-Servern, installiert wird per Sideloadly mit meiner kostenlosen Apple-ID. Details in `CLAUDE.md` und Skill `ios-build-deploy`.

Arbeite den Phasenplan (Abschnitt 8) der Reihe nach ab, prüfe jede Phase gegen ihre Abnahmekriterien und halte nur an den **⏸ STOPP**-Punkten an, an denen ich etwas tun muss.

---

## 1. Was ich will (User Story)

1. Abends öffne ich die App, stelle meine **spätestens-Weckzeit** ein (z. B. 07:00) und ein **Weckfenster** (z. B. 30 min → 06:30–07:00).
2. Ich tippe **Start**, lege das iPhone (am Ladekabel) auf den Nachttisch und sperre es.
3. Die App **nimmt die ganze Nacht über das Mikrofon auf und analysiert dauerhaft**: Bewegungen im Bett, Atmung, Schnarchen, Sprechen im Schlaf, Husten, sonstige Geräusche – und schätzt daraus Wach-, Leicht-, Tief- und Traumschlaf (REM).
4. Im Weckfenster weckt mich die App **im Moment eines leichten Schlafs** (oder wenn ich ohnehin wach bin), spätestens zur eingestellten Zeit. Der Wecker klingelt auch bei Stummschaltung und Fokus.
5. Sobald ich den Wecker **ausschalte**, sehe ich den **Morgenbericht**: Schlafkurve als Graph, Kennzahlen und eine Zeitleiste aller Ereignisse.
6. Alle Stellen mit Schnarchen, Reden, Husten oder auffälligen Geräuschen sind **herausgefiltert und als kurze Clips anhörbar** – nach Typ und Uhrzeit, direkt aus dem Graph antippbar.
7. Über die Tage sehe ich einen **Verlauf** (Qualität, Dauer, Schnarchminuten, Regelmäßigkeit).

---

## 2. Vorbild Sleep Cycle – was wir nachbauen (Details in `docs/RESEARCH.md`)

| Sleep Cycle | Wie es dort funktioniert | Unsere Umsetzung |
|---|---|---|
| Smart Alarm | Weckt im leichtesten Schlaf innerhalb eines Fensters, das zur Weckzeit endet; Standard 30 min | Fenster 0/10/15/20/30/45/60/90 min, Standard 30; Echtzeit-Entscheidung + AlarmKit-Backup zur spätesten Zeit |
| Drei Modi | Smart Alarm + Tracking · normaler Wecker + Tracking · nur Tracking | Genau diese drei |
| Schlaferkennung per Mikrofon | Patentierte Klanganalyse von Bewegungen im Bett + seit 2024/25 Atemmuster per ML → Wach, Leicht, Tief, REM | Bewegungs-Detektion + Atemrate/-regelmäßigkeit → heuristische Phasen + HMM-Glättung |
| Schlafgraph | Phasen über die Zeit (Wach oben, Tief unten), Scrubber-Linie, Geräusch-Markierungen | Schlafkurve + Phasenbänder + Ereignis-Spur + Scrubber |
| Schlafqualität | Zeit im Bett, Tiefschlafzeit, Bewegungshäufigkeit/-intensität, Wachphasen; persönlich kalibriert | Gleiche Faktoren + Einschlafdauer, Gewichte in `Tuning.swift` |
| Aufnahmen | Schnarchen, Reden, Husten, laute Geräusche als Clips | Apple-Klangklassifikator (`snoring`, `speech`, `cough` …) + Clips mit Vor-/Nachlauf |
| Statistiken | Zeit im Bett, eingeschlafen nach, Dauer, Schnarchen, Regelmäßigkeit, Stimmung, Notizen | MVP: alle außer Puls/Schritte |
| Nutzung | Nachttisch, Ladekabel (~30 % Akku/Nacht ohne), keine anderen Audio-Apps, kein Bluetooth | Gleiche Hinweise als Checkliste |

**Ehrliche Erwartung:** Schnarch-/Sprech-Erkennung wird gut. Schlafphasen sind Schätzungen (Forschung mit Deep Learning auf >1.000 Laborschlafnächten: ~70 % Übereinstimmung bei 4 Phasen). Ziel v1: Wach/Schlaf und leicht/tief gut genug für einen guten Smart Alarm, REM als plausible Schätzung. Danach Nacht für Nacht verbessern per `/night-review`.

---

## 3. Harte Rahmenbedingungen (recherchiert, nicht verhandelbar)

**Entwicklungsumgebung:**
- Windows 10, Claude Code nativ (Git Bash), `git`, GitHub CLI `gh`. Kein Mac, kein lokales Xcode, kein Simulator auf dem PC.
- Optional lokal: Swift für Windows (für schnelle Tests der reinen Swift-Engine) und Python (für schnelle Daten-Plots).
- **Build & Test:** GitHub Actions, Image `macos-26`, neueste stabile Xcode-26.x-Version, Swift-6-Sprachmodus. Workflow liegt schon in `.github/workflows/ios.yml`. Kostenlos bei öffentlichem Repo.
- **Projekt:** XcodeGen (`project.yml`) – die `.xcodeproj` entsteht nur auf dem CI-Server.
- **Ausgabe:** unsignierte `.ipa` als Artefakt; ich installiere sie mit **Sideloadly** und meiner kostenlosen Apple-ID.

**Gerät:** iPhone 14 Pro mit iOS 26 oder 27 (Deployment-Target iOS 26.0).

**Kostenlose Signierung:** App läuft **7 Tage**, dann neu installieren (Daten bleiben, solange Apple-ID und Bundle-ID gleich bleiben und die App nicht gelöscht wird). Max. 3 sideloaded Apps, begrenzt viele App-IDs (jede App-Extension braucht eine eigene) → **v1 ohne App-Extensions, ohne Sonder-Entitlements**. Entwicklermodus auf dem iPhone nötig.

**Aufnahme im Hintergrund (Kernrisiko):** `UIBackgroundModes = audio` + `AVAudioSession` `.playAndRecord`, **im Vordergrund aktiviert** und die ganze Nacht aktiv (Apple-DTS). Keine APIs, die die Session selbst verwalten. Nach Anrufen ist Reaktivierung im Hintergrund oft unmöglich → Lücke protokollieren, AlarmKit-Backup weckt trotzdem; Empfehlung Flugmodus/Schlaf-Fokus. Fallback „Nachttisch-Modus“ (App bleibt im Vordergrund, schwarzer Bildschirm, am Ladekabel).

**Wecker – AlarmKit:** echte System-Wecker, durchbrechen Stummschalter und jeden Fokus, überleben Absturz/Force-Quit/Neustart. Erlaubnis + `NSAlarmKitUsageDescription`. **Countdown-Darstellung (eingebautes Schlummern) verlangt eine Widget-Extension** – sonst kann das System Alarme verwerfen. Deshalb in v1: **kein `.countdown`**; Schlummern über einen eigenen Zweitknopf (`.custom`), dessen Intent einen neuen Alarm in +9 min plant (best effort, siehe Skill `smart-alarm`). Eigene Wecktöne sind laut Foren wackelig → Systemton als Standard.

**Klangerkennung:** `SNClassifySoundRequest(classifierIdentifier: .version1)` mit ~300 Klassen inkl. `snoring`, `speech`, `whispering`, `breathing`, `cough`, `sneeze`, `gasp`, `dog`, `cat`. Exakte Liste erzeugt der CI-Job „List SoundAnalysis labels“ als Artefakt → daraus das Mapping bauen.

**Kein Mac = keine Konsole:** Alles Diagnostische muss in das `eventlog.jsonl` der Session und in den Debug-Bildschirm. Daten kommen per In-App-Export (iTunes-Dateifreigabe per USB oder iCloud Drive) auf den PC nach `device-data/`.

**Datenschutz:** Keine Netzwerkzugriffe zur Laufzeit. Das Repo kann öffentlich sein – es enthält **nie** Aufnahmen, Nachtdaten oder persönliche Daten.

---

## 4. Feature-Spezifikation

### 4.1 MVP – Pflicht in dieser Session

**F1 – Wecker einstellen (Startbildschirm)**
- Großes Zeitrad für die spätestens-Weckzeit; Chips für das Weckfenster (Exakt, 10, 15, 20, 30, 45, 60, 90 min; Standard 30).
- Modus: *Smart-Wecker + Tracking* · *Normaler Wecker + Tracking* · *Nur Tracking*.
- Anzeige „Weckt dich zwischen 06:30 und 07:00 · noch ca. 7 h 40 min“.
- Startknopf mit Checkliste davor (Ampel): Mikrofon-Erlaubnis, AlarmKit-Erlaubnis, Akku ≥ 30 % oder Ladekabel, ≥ 2 GB frei, Hinweis Flugmodus/Schlaf-Fokus, kein Bluetooth-Headset, Hinweis Wecker-Lautstärke.

**F2 – Nacht-Tracking**
- Session im Vordergrund aktivieren, Engine starten, **vorher** AlarmKit-Backup zur spätesten Zeit planen.
- Schwarzer Bildschirm, große Uhr, Weckfenster, optionaler Pegel-Indikator, Halten-zum-Beenden.
- Läuft gesperrt die ganze Nacht. Watchdog alle 10 s, Flatline-Erkennung, Neustartversuch.
- Eventlog (`eventlog.jsonl`): Unterbrechungen, Route-Wechsel, Akkustand, thermischer Zustand, Watchdog, Heartbeat jede Minute, Alarmzustände, Fehler mit Kontext.

**F3 – Geräuscherkennung und Clips**
- Ereignistypen: **Schnarchen**, **Reden**, **Husten/Niesen**, **Umgebung** (Hund, Katze, Tür, Verkehr, Musik …), **Laut** (unklassifiziert, deutlich über Grundrauschen).
- Hysterese, Mindestdauer, Zusammenfassen (Schnarchen → Episoden), Energie-Schwelle gegen leise Fernsehgeräusche.
- 30-s-Ringpuffer → Clips mit 3 s Vorlauf und 2 s Nachlauf als AAC (.m4a, 16 kHz mono). Schnarchen max. 2 Clips pro 15 min, Reden immer.
- Pro Ereignis: Typ, Label, Start/Ende, Spitzenpegel, Konfidenz, Clip, Mini-Wellenform (64 Werte), Favorit, Nutzer-Korrektur.
- Optional (Standard aus): ganze Nacht als AAC (~90 MB / 8 h) fürs Tuning.

**F4 – Schlafphasen-Schätzung**
- Pro Sekunde Merkmale (Pegel, Grundrauschen, Bandenergien, Flachheit, Transienten, Klassifikator-Gruppen, 4-Hz-Atemhüllkurve) → `frames.bin`.
- Pro 30-s-Epoche: Bewegung, Atemrate/-regelmäßigkeit, Schnarch-/Sprechsekunden, Umgebung.
- Aktivitätswert, Normalisierung pro Nacht, Regeln → **HMM-Viterbi** → Einschlafzeit, Wachphasen, Schlaftiefe-Kurve.
- Alles in `SleepEngineCore` (reines Swift, läuft auch unter Windows). Vorgehen im Skill `sleep-staging`.

**F5 – Smart Alarm**
- `WakeDecider` (rein, getestet): wartet bis Fensterbeginn, weckt bei Leichtschlaf-/Wach-Signal, spätestens zur Deadline; Weckgrund wird gespeichert.
- Backup-Alarm zur spätesten Zeit → bei Smart-Auslösung Ersatzalarm „jetzt + Vorlauf“ planen, **danach** Backup stornieren. Optionaler sanfter Vorlauf (Ton aus der App blendet 60 s ein).
- Alarm-Knöpfe: **Stopp** (Intent beendet Session, startet Endauswertung, Bericht bereit) und **Schlummern** (`.custom`-Zweitknopf, plant neuen Alarm +9 min; abschaltbar). Beim Öffnen der App erscheint direkt der Morgenbericht; zusätzlich lokale Mitteilung „Dein Schlafbericht ist fertig“.
- Details im Skill `smart-alarm`.

**F6 – Morgenbericht**
- Kopf: Datum, Im Bett von–bis, Qualität %, Geschlafen, Eingeschlafen nach, Geweckt um + Weckgrund.
- **Hauptgraph** (Swift Charts): Schlaftiefe-Kurve + Phasenbänder, darunter **Ereignis-Spur**; Scrubber zeigt Uhrzeit/Phase/Ereignisse; Antippen spielt den Clip.
- Kacheln: Phasenanteile, Wachphasen, Schnarchen (Minuten, %, Episoden, Balken pro 15 min), Reden/Husten/Umgebung, Atmung (falls messbar), Geräuschpegel, **Datenqualität** (Lücken).
- **Aufnahmen-Liste**: nach Typ gruppiert, Uhrzeit, Dauer, Wellenform, Play/Pause, Favorit, Typ korrigieren, Teilen, Löschen; Highlights oben.
- Aufwach-Stimmung (3 Smileys) und Schlafnotizen (Kaffee, Alkohol, Sport, Stress, spätes Essen, eigene).

**F7 – Verlauf und Statistik**
- Liste aller Nächte → Detail = Morgenbericht. Trends 7/30 Tage: Qualität, Dauer, Schnarchminuten, Zubettgeh-/Aufwachzeit + Regelmäßigkeit, Einfluss der Notizen.
- Knopf „Alle Nächte neu analysieren“ (rechnet gespeicherte `frames.bin` mit den aktuellen `Tuning`-Werten neu).

**F8 – Einstellungen**
- Standard-Weckfenster, Weckton, sanfter Vorlauf, Schlummern an/aus + Dauer, Empfindlichkeit, gespeicherte Ereignistypen, Clip-Aufbewahrung (7/30/90/unbegrenzt, Favoriten bleiben), Ganznacht-Aufnahme, Schlafziel (8 h), Nachttisch-Modus.

**F9 – Diagnose und Export**
- Debug-Bildschirm (5× auf Versionsnummer): Live-Pegel, Klassifikator-Top-3, Bewegung/Atmung, Watchdog, Eventlog.
- Export einer Session (oder aller) als ZIP nach `Documents/Exports/` – erreichbar über **iTunes-Dateifreigabe** (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`) und über das Teilen-Menü („In Dateien sichern“ → iCloud Drive).

**F10 – Testsession**
- Späteste Zeit = jetzt + 10 min, Fenster 5 min, sonst identisch → kompletter Ablauf tagsüber in Minuten prüfbar.

### 4.2 Später (Architektur offen halten, nicht jetzt bauen)
- Transkription der Schlafgespräche auf dem Gerät (`SpeechAnalyzer`/`SpeechTranscriber`, Deutsch) – morgens, im Vordergrund.
- Eingebautes AlarmKit-Schlummern mit Widget-Extension (kostet eine App-ID).
- Apple Health (Schreiben/Lesen) – nur falls die Sideloadly-Signierung das HealthKit-Entitlement mitträgt; vorher testen.
- Eigener Klassifikator aus meinen korrigierten Clips (Create ML auf einem Mac/CI).
- Einschlafklänge, „mögliche Atempausen“ (experimentell), Live Activity während des Trackings.

---

## 5. UX und Design

- Ruhig, dunkel, nachtfreundlich; große gerundete Ziffern (SF Pro Rounded), wenig Text.
- Phasenfarben: Wach = Koralle/Amber, REM = Violett, Leicht = Himmelblau, Tief = Indigo. Ereignisse: Schnarchen = Orange, Reden = Türkis, Husten = Rosa, Umgebung = Grau, Laut = Gelb, Datenlücke = schraffiert.
- Tabs: **Wecker** · **Nächte** · **Statistik** · **Einstellungen**.
- Ablauf: Wecker einstellen → Checkliste → Nachtbildschirm → Wecker → Stopp → Morgenbericht → Verlauf.
- VoiceOver-Beschriftungen für Graphen, Dynamic Type, alle Texte auf Deutsch. Details im Skill `sleep-report-ui`.

---

## 6. Architektur (verbindlich, Details in `CLAUDE.md`)

```
Mikrofon ─▶ AVAudioEngine-Tap (48 kHz) ─┬─▶ SNAudioStreamAnalyzer (version1) ─▶ Gruppen-Konfidenzen/s
                                        └─▶ Konverter 16 kHz mono ─▶ Ringpuffer 30 s ─▶ ClipRecorder (AAC)
                                                                   └─▶ SleepEngineDSP ─▶ FrameFeatures (1/s) ─▶ frames.bin
FrameFeatures ─▶ SleepEngineCore: EventTracker · EpochBuilder (30 s) · Stager (Regeln + HMM) · WakeDecider
WakeDecider ─▶ AlarmService (AlarmKit)          Session-Ende ─▶ Endauswertung ─▶ SwiftData-Zusammenfassung ─▶ Bericht
```
- `SleepEngineCore` = reines Swift + Foundation (läuft auf Windows, iOS, macOS). `SleepEngineDSP` (Accelerate) und `SleepEngineAudio` (AVFoundation/SoundAnalysis) nur für Apple-Plattformen, per `#if canImport(…)` abgesichert.
- `sleepreplay`: `--frames` (überall, auch Windows) und `--audio`/`--list-labels` (nur macOS/CI).
- Session-Ordner in Application Support: `Sessions/<yyyy-MM-dd_HHmm>_<id>/` mit `frames.bin`, `epochs.json`, `events.json`, `summary.json`, `eventlog.jsonl`, `clips/`, optional `night.m4a`. Exporte in `Documents/Exports/`.
- Alle Schwellen in `SleepEngineCore/Tuning.swift`.

---

## 7. Arbeitsweise (Regeln für dich)

1. **Erst lesen, dann bauen:** zu Beginn jeder Phase die passenden Skills laden.
2. **Aufgabenliste** führen und abhaken.
3. **Nie raten bei Apple-APIs** – vor dem Push die Doku prüfen (`https://developer.apple.com/documentation/<framework>/<symbol>.md`). Ohne Mac ist jeder Compilerfehler eine 5–15-minütige CI-Runde.
4. **CI sparsam und gezielt:** zusammengehörige Änderungen bündeln; Engine-Logik zuerst lokal testen (Swift für Windows, falls installiert); Doku-Commits mit `[skip ci]`; Fehlerlogs gefiltert lesen.
5. **`main` immer grün.** Commit am Ende jeder Phase.
6. **Keine Platzhalter** in fertig gemeldeten Features. Geht etwas nicht: klar sagen, Fallback bauen, in `docs/DECISIONS.md` dokumentieren.
7. **Keine Fremd-Abhängigkeiten** in der App ohne Rückfrage.
8. **Nichts Privates ins Repo** (`device-data/`, Audio, Exporte sind gitignored).
9. **Rückfragen nur** an ⏸-Punkten oder bei echten Weggabelungen – mit 2–3 Optionen und Empfehlung.
10. **Ehrlichkeit vor Optik:** Lücken sichtbar, Schätzungen als Schätzungen.
11. Mit mir Deutsch sprechen; Anleitungen für Handgriffe am iPhone/in Sideloadly Schritt für Schritt.

---

## 8. Phasenplan mit Abnahmekriterien

### Phase 0 – Werkzeuge, Repo, erster Cloud-Build, erste Installation
- Prüfen: `git`, `gh` (+ `gh auth status`), optional `swift`, `python`. Fehlendes mit genauen `winget`-Befehlen erklären.
- **⏸ STOPP:** mich fragen: öffentliches Repo (kostenlose macOS-Minuten, Code sichtbar, keine Daten) oder privat (begrenzte Minuten). Empfehlung: öffentlich.
- Repo anlegen, Struktur aus `CLAUDE.md`. `project.yml` und `Packages/SleepEngine/Package.swift` liegen als **Vorlagen** bereit: prüfen, Bundle-ID-Präfix mit mir festlegen (z. B. `de.<name>`, danach nie mehr ändern), je Modul eine erste Quelldatei + ein Test, Minimal-App „Schlafkurve läuft“ mit Versions- und Build-Nummer im UI (Build-Nummer = CI-Lauf).
- Push → CI grün → IPA-Artefakt laden (`dist/`).
- **⏸ STOPP:** mich Schritt für Schritt durch Sideloadly führen (iTunes/iCloud von apple.com, Gerät verbinden, Apple-ID, IPA, Entwickler vertrauen, Entwicklermodus).
- **Abnahme:** App startet auf meinem iPhone und zeigt die Build-Nummer. Commit „Phase 0“.

### Phase 1 – Engine-Kern (lokal/CI testbar)
- Modelle (`FrameFeatures`, `EpochFeatures`, `SoundEvent`, `SleepStage`, `SessionSummary`), `Tuning`, `frames.bin`-Codec (versioniert), `EventTracker`, `MovementDetector`, `BreathingAnalyzer` (4-Hz-Hüllkurve), `EpochBuilder`, `Stager` (Regeln + HMM), `WakeDecider`, `QualityScorer` – alles in `SleepEngineCore`.
- `SleepEngineDSP`: vDSP-Frame-Features aus 16-kHz-Audio.
- **Synthetischer Nacht-Generator** (Merkmals-Ebene für Core-Tests, Audio-Ebene für DSP-Tests) und Tests für jeden Baustein inkl. kompletter Nacht mit erwarteter Einschlafzeit, Tiefschlafblock und Weckentscheidung.
- `sleepreplay --frames` funktioniert.
- **Abnahme:** Tests grün lokal (falls Swift für Windows) und auf CI. Commit.

### Phase 2 – Aufnahme die ganze Nacht (größtes Risiko zuerst)
- `AudioCaptureService`, `NightPipeline`, `DiagnosticsLog` mit Heartbeat, Watchdog, Nachtbildschirm, Testsession, Nachttisch-Modus, **Export (F9) schon jetzt**, Debug-Bildschirm-Grundgerüst.
- **⏸ STOPP – Gerätetest:** neue IPA installieren, Testsession starten, iPhone **15 Minuten gesperrt** liegen lassen, einmal rascheln und sprechen, dann exportieren und das ZIP nach `device-data/` holen (Skill `ios-build-deploy`, Abschnitt „pull“).
- Du prüfst Eventlog und `frames.bin` (per `sleepreplay --frames` oder Python): keine Lücke, Heartbeat durchgehend, Pegelverlauf plausibel.
- **Abnahme:** 15 min gesperrt ohne Lücke. Commit.

### Phase 3 – Geräuscherkennung und Clips
- Label-Liste aus dem CI-Artefakt laden, Gruppen-Mapping festlegen (in `docs/DECISIONS.md`), Klassifikator-Anbindung, `ClipRecorder` (Ringpuffer, Vor-/Nachlauf, AAC, Wellenform), Speicherlimits, Clips im Debug-Bildschirm abspielbar.
- **⏸ STOPP – Gerätetest:** Testsession, ich schnarche absichtlich ~30 s, rede 2–3 Sätze, huste zweimal, klatsche einmal; danach Clips im Debug-Bildschirm anhören und exportieren.
- **Abnahme:** Alle vier Ereignisse erkannt (oder korrigierbar), Clips sauber mit Vorlauf. Commit.

### Phase 4 – Schlafphasen live + Smart Alarm
- Live-Staging pro Epoche, Endauswertung über die ganze Nacht.
- `AlarmService`: Erlaubnis, Backup, Ersatzalarm, Stornieren, Schlummern via `.custom`-Intent, Stopp-Intent → Session beenden → Bericht bereit; `alarmUpdates` beobachten und loggen.
- Sanfter Vorlauf über die aktive Session (`.defaultToSpeaker`).
- **⏸ STOPP – Gerätetest (Testsession, 10 min, Fenster 5 min):** (a) ruhig liegen lassen → Wecker zur Deadline; (b) im Fenster Handy anheben/rascheln → Smart-Weckung; (c) App nach Start wegwischen → Backup klingelt trotzdem; (d) Schlummern und Stopp; (e) Stummschalter + Schlaf-Fokus an → klingelt trotzdem. Danach Export.
- **Abnahme:** a–e funktionieren, Weckgrund korrekt im Eventlog. Commit.

### Phase 5 – Speicherung, Morgenbericht, Verlauf
- SwiftData + Session-Ordner, Morgenbericht (F6), Verlauf/Statistik (F7) inkl. „Alle Nächte neu analysieren“, Einstellungen (F8), Aufbewahrungs-Aufräumen.
- Demo-Modus per Startargument (`-demoReport` u. a.) mit synthetischer Nacht; `scripts/ci-screenshots.sh` (Simulator booten, App mit Demo-Argumenten starten, `xcrun simctl io booted screenshot`) für den `screenshots`-Job; Screenshots herunterladen und selbst ansehen (hell/dunkel, große Schrift) und Layoutfehler beheben.
- **Abnahme:** Bericht aus einer echten Testsession korrekt, Clips spielen, Verlauf listet Nächte, Screenshots geprüft. Commit.

### Phase 6 – Tuning-Werkzeug, Feinschliff, v1.0
- `sleepreplay`: `--frames <datei|ordner> --report/--compare` (Windows + CI), `--audio <datei>` (CI/macOS, mit `SNAudioFileAnalyzer`), `--list-labels`.
- Checkliste vor dem Start, App-Icon (eigenes Mond-/Wellen-Motiv), Leer- und Fehlerzustände, `README.md` für mich (Installation, 7-Tage-Erneuerung, Daten exportieren, Tipps für die Nacht).
- **Abnahme:** Alles grün, IPA installiert, `sleepreplay --frames` läuft auf meinem Testexport. Commit „v1.0“.

### Phase 7 – Erste echte Nacht (nach der Session)
- Checkliste für heute Nacht: Ladekabel, Flugmodus/Schlaf-Fokus, Handy auf dem Nachttisch, Unterseite Richtung Bett, 0,5–1 m Abstand, Ganznacht-Aufnahme für die ersten Nächte an.
- Morgen früh exportiere ich die Nacht und tippe `/night-review`.

---

## 9. Definition of Done (v1)

- [ ] Auf meinem iPhone 14 Pro: Weckzeit + Fenster, Start, sperren, ganze Nacht Aufnahme und Analyse ohne Abbruch.
- [ ] Schnarchen, Reden, Husten, Umgebung, Laut werden erkannt und als Clips gespeichert.
- [ ] Smart Alarm per AlarmKit im Fenster; Backup klingelt auch nach App-Absturz; Stopp öffnet den Bericht; Schlummern funktioniert oder ist sauber abschaltbar.
- [ ] Morgenbericht mit Schlafkurve, Phasen, Kennzahlen, Ereignis-Spur und abspielbaren Clips.
- [ ] Verlauf, Statistik, Einstellungen, Export, Testsession, Debug-Bildschirm.
- [ ] CI grün, IPA-Artefakt vorhanden, `README.md` und `docs/DECISIONS.md` aktuell.

---

## 10. Bekannte Risiken und Fallbacks

| Risiko | Gegenmaßnahme |
|---|---|
| App wird im Hintergrund beendet | DTS-Regel strikt, Gerätetest in Phase 2, Watchdog + Eventlog, Nachttisch-Modus, AlarmKit-Backup |
| Anruf/Siri unterbricht nachts | Lücke loggen, Reaktivierungsversuch, Flugmodus/Schlaf-Fokus empfehlen |
| Langsame CI-Runden | Bündeln, Doku vorher prüfen, Engine lokal testen, `[skip ci]` |
| Sideloadly-Probleme (Treiber, Apple-ID) | iTunes/iCloud von apple.com, Apple-ID muss schon auf einem iPhone angemeldet gewesen sein; Alternative SideStore |
| Schlummern per `.custom` unzuverlässig | Neuen Alarm planen, bevor der alte gestoppt wird; idempotent; Einstellung „Schlummern aus“; später Widget-Extension |
| AlarmKit-Eigenton spielt nicht | Systemton als Standard; sanfter Vorlauf über die App-Session |
| Klassifikator verwechselt Partner/TV/Haustier | Umgebungs-Gruppe, Energie-Schwelle, Typ-Korrektur, später eigenes Modell |
| Phasen ungenau | Ehrliche Kennzeichnung, `frames.bin` + Re-Analyse, `/night-review` |
| 7-Tage-Signatur läuft ab | `/ios-build-deploy refresh`, Kalender-Erinnerung, ggf. Sideloadly-Auto-Refresh |

---

## 11. Abschlussbericht am Ende der Session

Kurz und konkret: was fertig ist (Checkliste aus Abschnitt 9), was bewusst offen ist, bekannte Macken, wie ich in 7 Tagen neu installiere, wie ich Nächte exportiere, und die Checkliste für die erste echte Nacht.
