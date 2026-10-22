# Recherche & Analyse – Sleep Cycle nachbauen (Stand: 21.10.2026)

Dieses Dokument fasst zusammen, wie Sleep Cycle funktioniert, was die Forschung zu Schlafphasen aus Geräuschen sagt und welche iOS-Rahmenbedingungen gelten. Es ist die Grundlage für `MASTER_PROMPT.md` und die Skills.

---

## 1. Sleep Cycle – Funktionsanalyse

### 1.1 Smart Alarm
- Weckt im leichtesten Schlafmoment innerhalb eines **Weckfensters, das zur eingestellten Weckzeit endet**. Standard sind 30 Minuten. Der Support nennt heute 10–30 min, eine Feature-Seite 10–45 min; ältere App-Versionen boten „sofort“ bis 90 min.
- Drei Varianten beim Stellen: Smart Alarm mit Tracking, normaler Wecker ohne Fenster (mit Tracking), nur Tracking ohne Wecker.
- Schlummern früher per Doppeltippen/Schütteln, Vibration als Backup, sanfte Weckklänge, Philips-Hue-Sonnenaufgang.
- Grundlage: eigenes Patent für den „vorteilhaftesten Weckmoment“ in einem Zeitintervall.

### 1.2 Schlaferkennung per Mikrofon
- Kern ist das Patent **US 8,493,220**: Ein Gerät neben dem Schlafenden analysiert statistische Eigenschaften der **Geräusche, die durch Bewegungen entstehen**, und teilt in ruhigen Tiefschlaf, leichten Schlaf mit Weckreaktionen und Wachphasen ein. Laut Patent ist der Schlafzyklus abends regelmäßiger, gegen Morgen häufen sich Bewegungen und Phasenwechsel, REM liegt überwiegend in den letzten Stunden.
- Laut Sleep Cycle hört die Analyse Bettzeug-Rascheln mit etwa 30 cm Genauigkeit; das Handy liegt auf dem Nachttisch oder Boden statt im Bett.
- **Seit 2024/25 „Sleep Stages“**: Kombination aus **Atemmustern und Bewegungsgeräuschen** per KI/ML → Wach, Leicht, Tief und Traum/REM. Zunächst nur iOS und englische App-Sprache. Wenig/keine Bewegungsgeräusche werden als Tiefschlaf gedeutet, Bewegung + Geräusche als Leichtschlaf.
- Datenbasis laut Hersteller: über 3 Milliarden Schlafsessions.

### 1.3 Schlafgraph und Statistik
- Zeitachse mit Phasen; im Graph eine verschiebbare vertikale Linie, an der man sieht, in welcher Phase ein Geräusch auftrat.
- Statistiken: Schlafqualität, Regelmäßigkeit (Zubettgeh-/Aufwachzeit), Zeit im Bett, „eingeschlafen nach“, Schlafdauer, Schnarchen, Puls (Watch), Schritte, Aufwach-Stimmung, Schlafnotizen (Koffein, Sport, Alkohol, Stress …).
- Die Lücke zwischen Zeit im Bett und Schlafzeit wird als Hinweis auf Schlafeffizienz erklärt.

### 1.4 Schlafqualität
Laut Support berechnet aus vier Größen: Zeit im Bett, Zeit im Tiefschlaf, Häufigkeit und Intensität der Bewegungen, Anzahl erkannter Wachphasen. Persönlich: Kalibrierung in der ersten Nacht, wird mit der Zeit genauer.

### 1.5 Aufnahmen
- Schnarchen, Husten, Schlafgespräche, laute Partner, Haustiere, Verkehr – als Clips zum Anhören am Morgen; „Who's Snoring?“ soll unterscheiden, ob man selbst oder der Partner schnarcht (nicht in unserem Umfang).
- In der kostenlosen Version teils nur Schnarcherkennung ohne Wiedergabe – Wiedergabe ist Premium.

### 1.6 Nutzungshinweise des Herstellers
- Ladekabel empfohlen: im Schnitt **~30 % Akku pro Nacht**; Akku-Warnung einstellbar.
- Bei Flatlines/Abstürzen: andere Audio-Apps schließen, Bluetooth-Geräte trennen (Apple Watch ausgenommen), mindestens 5 GB frei.
- Flugmodus ist möglich, wenn man das Handy nicht nah am Kopf haben will.

### 1.7 Preis (Motivation)
Premium-In-App-Käufe sind im US-App-Store mit rund 40–44 US-$ gelistet.

---

## 2. Forschung: Schlafphasen aus Geräuschen

| Studie | Ansatz | Ergebnis |
|---|---|---|
| Dafna et al., Scientific Reports 2018 | Atem- und Bewegungsgeräusche, berührungslose Mikrofone, 250 Laborpatienten, kleine neuronale Netze | 87 % Übereinstimmung pro 30-s-Epoche für Wach / NREM / REM (Kappa 0,7) |
| Hong et al., Nature and Science of Sleep 2022 | End-to-end Deep Learning auf Mel-Spektrogrammen von Mikrofonchips (1.154 Laboraufnahmen + 327 Smartphone-Nächte) | ~70 % für 4 Klassen (Wach, Leicht, Tief, REM), 68 % extern auf Smartphone-Aufnahmen |
| JMIR 2023 (gleiche Gruppe) | Transfer-Learning auf Heimaufnahmen mit Smartphones | Sound-basiertes Staging zu Hause machbar |

**Folgerung für uns:** Atmung (Rate, Regelmäßigkeit) und Bewegung sind die tragenden Signale. Ohne großes Trainingsdatenset ist eine transparente Heuristik mit HMM-Glättung der richtige Start; mit eigenen Nächten (und optional Apple-Watch-Referenz) wird nachjustiert. Typische Anteile laut Sleep Cycle: Tief ~10–20 %, REM ~10–25 %, Rest überwiegend Leichtschlaf.

---

## 3. iOS-Rahmenbedingungen (Herbst 2026)

### 3.1 Toolchain
- **Xcode 27** seit 14.09.2026, enthält **Swift 6.4** und die 27er-SDKs, braucht **macOS Tahoe 26.6+ auf Apple silicon**. iOS 27 ist seit demselben Tag verfügbar und läuft weiterhin auf iPhone 11 und neuer – also auch auf dem **iPhone 14 Pro**.
- Für dieses Projekt reicht das **iOS-26-SDK** (AlarmKit, SpeechAnalyzer, SoundAnalysis, Swift Charts, SwiftData). Das ist wichtig, weil der Build auf GitHubs Servern läuft (siehe 3.7).

### 3.2 Aufnahme im Hintergrund
- Ein Entwickler berichtete im Mai 2026 von Abbrüchen nach ~50 s im Hintergrund unter iOS 26.5. Apples DTS-Antwort: Nötig sind nur der Hintergrundmodus „audio“ und eine **im Vordergrund aktivierte, aktive Audio-Session**; Kategorie `.playAndRecord` ist passend. Höhere APIs, die die Session selbst verwalten, vermeiden. Solange die Session aktiv ist, darf die App unbegrenzt laufen; bei Abbrüchen Crashlog und Systemlog (runningboardd) auswerten. CallKit-Tricks sind weder erlaubt noch nötig. Apples Beispielprojekt zur Stereo-Aufnahme lief im Test im Hintergrund problemlos.
- Bekanntes Problem: Nach einem **Telefonanruf** lässt sich die Session im Hintergrund oft nicht wieder aktivieren, erst wenn die App wieder geöffnet wird.
- Praxisartikel zu Nacht-Audio: Zeitstempel an einer festen Uhr verankern und nach Unterbrechungen neu verankern; „stille Strecken“ als Datenqualitätsproblem markieren statt als ruhigen Schlaf.

### 3.3 AlarmKit (iOS 26+)
- Systemwecker für Drittanbieter-Apps: feste oder relative Zeitpläne, Countdown, Live Activity auf Sperrbildschirm/Dynamic Island, Stopp- und Zusatzknopf über App Intents. Erlaubnis durch den Nutzer nötig.
- Apple-FAQ: geplante Alarme überstehen Absturz, Force-Quit und Neustart; durchbrechen **alle** Fokus-Modi; Hardwaretasten stoppen den Alarm; beim Stoppen läuft der `stopIntent`; versteckte oder per Face ID gesperrte Apps können keine Alarme nutzen; Limit nicht fest, aber `maximumLimitReached` möglich.
- Countdown/eingebautes Schlummern braucht eine Widget-Extension mit `ActivityConfiguration(for: AlarmAttributes<…>)` (Konsequenz für uns: siehe 3.7).
- Eigene Töne über `AlertSound.named` wurden in den Foren über mehrere iOS-26-Versionen als unzuverlässig gemeldet (Systemton statt eigenem Ton, oder nur einmalige Wiedergabe) → Standardton als Basis.
- iOS 27 bringt eine eigene Lautstärke für Wecker/Timer (Einstellungen → Töne & Haptik).

### 3.4 Klangerkennung
- `SNClassifySoundRequest` mit `.version1`: eingebaute ~300 Klassen, u. a. speech, whispering, shout, laughter, sigh, **breathing, snoring, gasp, cough, sneeze**, dog, cat. Liste zur Laufzeit über `knownClassifications`.
- Live per `SNAudioStreamAnalyzer`, Dateien per `SNAudioFileAnalyzer` (auch auf macOS → Mac-Tuning-Tool).
- Eigene Modelle über Create ML trainierbar und per `SNClassifySoundRequest(mlModel:)` nutzbar.

### 3.5 Spracherkennung (spätere Phase)
- `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26+) laufen komplett auf dem Gerät; Deutsch (de_DE, de_AT, de_CH) wird unterstützt; Sprachmodell lädt das System einmalig.

### 3.6 Kostenlos signieren
- Mit kostenloser Apple-ID (Personal Team) laufen selbst gebaute Apps **7 Tage**; Profile laufen ab, Neuinstallation nötig.
- Laut Apples Capability-Tabelle sind mit kostenlosem Konto u. a. **Background Modes, HealthKit, App Groups** möglich; Push, iCloud, In-App-Kauf nicht. Achtung: Beim Neu-Signieren über SideStore können Berechtigungen wie HealthKit fehlen.
- Begrenzungen: 3 aktive Apps, begrenzte Zahl neuer App-IDs pro Woche.
- Alternative ohne Mac zum Erneuern: **SideStore** + LocalDevVPN (Open Source, AGPL) signiert auf dem iPhone neu.

### 3.7 Ohne Mac: Bauen in der Cloud, Installieren von Windows
- **Problem:** iOS-Apps lassen sich nur mit Xcode auf macOS bauen; Xcode 27 läuft nur auf Apple silicon. Eine macOS-VM auf einem Windows-PC scheidet damit (und lizenzrechtlich) aus.
- **GitHub Actions:** Laut GitHub ist die Nutzung der Standard-Runner für **öffentliche Repositories kostenlos**; private Repos haben im Free-Plan 2.000 inkludierte Minuten, macOS-Minuten werden zu einem deutlich höheren Satz abgerechnet. Das Image `macos-26` ist seit Sommer 2026 Standard (`macos-latest`) mit Xcode 26.x; Xcode 27 gibt es als separates Image `xcode-27` (zuletzt als Vorschau gekennzeichnet). Homebrew ist vorinstalliert (XcodeGen per `brew install`).
- **Unsignierte IPA:** `xcodebuild archive … CODE_SIGNING_ALLOWED=NO`, dann `Products/Applications/<App>.app` in einen Ordner `Payload` legen und als `.ipa` zippen.
- **Sideloadly (Windows):** signiert eine IPA mit einer normalen Apple-ID und installiert sie per USB/WLAN. Braucht iTunes und iCloud **von Apples Website** (nicht aus dem Microsoft Store) und eine Apple-ID, die schon auf einem iOS-Gerät angemeldet war. Kostenlose Apple-IDs: 7-Tage-Zertifikat, max. 3 sideloaded Apps; ein Daemon kann vor Ablauf automatisch erneuern. Entwicklermodus (iOS 16+) nötig. Zum Erneuern über die bestehende App installieren – nicht löschen, sonst sind die Daten weg.
- **App-IDs:** Bis zu 10 gleichzeitig, jede verfällt nach einer Woche; jede App-Extension braucht eine eigene → v1 bewusst ohne Extensions.
- **AlarmKit ohne Extension:** Apple schreibt, AlarmKit erwartet eine Widget-Extension, sobald eine App eine Countdown-Darstellung unterstützt – sonst kann das System Alarme verwerfen. Ohne Countdown reicht die systemeigene Alarm-Oberfläche. Zweitknopf-Verhalten `.custom` führt einen eigenen Intent aus; Entwickler nutzen das für eigenes Schlummern (neuen Alarm planen), Apple garantiert das Verhalten aber nicht ausdrücklich.
- **Alternative zum Erneuern ohne PC:** SideStore, installierbar mit `iloader` (Windows-Anleitung vorhanden, nutzt iTunes für die USB-Verbindung).
- **Swift unter Windows:** offizielle Toolchain per `winget` (aktuell Swift 6.4.1), benötigt die Visual-Studio-2022-Build-Tools. Damit lassen sich reine Swift-Pakete (unsere Schlafanalyse) lokal testen; Apple-Frameworks (AVFoundation, SoundAnalysis, Accelerate) gibt es dort nicht.
- **Claude Code** läuft nativ auf Windows 10 (ab Version 1809); Git für Windows wird empfohlen, damit das Bash-Werkzeug verfügbar ist.

---

## 4. Claude-Code-Setup

- **Skills** = Ordner mit `SKILL.md` (YAML-Frontmatter + Anleitung) unter `.claude/skills/<name>/`. Die Beschreibung ist immer im Kontext; der Inhalt lädt nur bei Bedarf. Empfehlung: unter 500 Zeilen, Details in Zusatzdateien. `disable-model-invocation: true` → nur per `/name` aufrufbar.
- **CLAUDE.md** = immer geladene Projektfakten; Abläufe gehören in Skills.
- **XcodeBuildMCP** und **Apples Xcode-MCP** (`xcrun mcpbridge`) wären auf einem Mac die ideale Ergänzung – unter Windows nicht nutzbar, deshalb nicht im Kit konfiguriert. Ersatz: GitHub-CLI (`gh run watch`, `gh run view --log-failed`, `gh run download`).
- Optionale Community-Skill-Sammlung **dpearson2699/swift-ios-skills** (u. a. alarmkit, swift-charts) – nur gezielt einzelne Skills übernehmen, nicht alle 100 (kostet Kontext); Inhalte vorher prüfen.

---

## Quellen
- Sleep Cycle – Smart Alarm: https://sleepcycle.com/the-app/smart-alarm · https://support.sleepcycle.com/hc/en-us/articles/7858323091356-What-is-the-Smart-Alarm-Clock · https://www.sleepcycle.com/features/smart-alarm-clock/
- Sleep Cycle – Funktionsweise & Patent: https://sleepcycle.com/how-it-works · https://sleepcycle.com/the-app/tracking · https://patents.google.com/patent/US8493220 · https://patents.justia.com/inventor/vaino-virtanen
- Sleep Cycle – Sound-Analyse (Android-Launch, 30-cm-Angabe): https://www.sleepcycle.com/news/sound-analysis-android/
- Sleep Cycle – Sleep Stages: https://sleepcycle.com/newsroom/press-release/discover-your-dream-patterns-with-sleep-cycle-the-worlds-first-technology-to-combine-breathing-patterns-and-movement-to-analyze-sleep-stages · https://www.sleepcycle.com/features/sleep-stages-graph/ · https://www.sleepcycle.com/features/track-sleep-cycle-stages/
- Sleep Cycle – Statistik & Qualität: https://www.sleepcycle.com/features/statistics/ · https://support.sleepcycle.com/hc/en-us/articles/206704659-How-is-Sleep-Quality-calculated-
- Sleep Cycle – Aufnahmen: https://sleepcycle.com/the-app/sounds · https://support.sleepcycle.com/hc/en-us/articles/7858653607580-About-Sleep-Tracking
- Sleep Cycle – Akku, Platzierung, Fehler: https://support.sleepcycle.com/hc/en-us/articles/206704539-Do-I-have-to-keep-the-charger-connected-all-night · https://support.sleepcycle.com/hc/en-us/articles/207388465-Phone-Placement-with-the-Sleep-Cycle-App · https://support.sleepcycle.com/hc/en-us/articles/12221769465116-I-have-an-iPhone-and-get-flatlines-or-crashes
- Sleep Cycle – App Store: https://apps.apple.com/app/sleep-cycle-smart-alarm-clock/id320606217
- Studien: https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6128888/ · https://pmc.ncbi.nlm.nih.gov/articles/PMC9241996 · https://jmir.org/2023/1/e46216
- Hintergrundaufnahme (DTS-Antwort): https://developer.apple.com/forums/thread/826462 · Anruf-Problem: https://developer.apple.com/forums/thread/813278 · Praxisnotizen: https://dev.to/sleeptrace/field-notes-why-background-audio-on-ios-fails-silently-at-3am-1l2j
- AlarmKit: https://developer.apple.com/videos/play/wwdc2025/230 · https://developer.apple.com/forums/thread/797158 · https://developer.apple.com/documentation/alarmkit/alarmmanager/schedule(id:configuration:) · Töne: https://developer.apple.com/forums/thread/797172 · https://developer.apple.com/forums/thread/836432 · Widget-Extension: https://wwdcnotes.com/documentation/wwdc25-230-wake-up-to-the-alarmkit-api/
- iOS 27 Weckerlautstärke: https://techcrunch.com/2026/06/09/ios-27-features-we-didnt-see-on-stage/
- SoundAnalysis: https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest · Labelliste: https://gist.github.com/ktustanowski/ccb66f95967b7f0541d4a7cf948db6bf
- SpeechAnalyzer: https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide · https://blog.addpipe.com/apple-speechanalyzer-api/
- Xcode 27: https://blakecrosley.com/blog/xcode-27-release · https://mjtsai.com/blog/2026/09/15/xcode-27/
- Kostenlose Signierung: https://developer.apple.com/help/account/reference/supported-capabilities-ios/ · https://learn.microsoft.com/th-th/previous-versions/xamarin/ios/get-started/installation/device-provisioning/free-provisioning · SideStore: https://github.com/SideStore/SideStore
- Ohne Mac: GitHub-Actions-Abrechnung: https://docs.github.com/en/billing/concepts/product-billing/github-actions · Runner-Images: https://github.com/actions/runner-images/issues/14167 · https://github.com/actions/runner-images/issues/14404 · Unsignierte IPA: https://github.com/MrKai77/Export-unsigned-ipa-files · Sideloadly: https://github.com/qnblackcat/uYouPlus/wiki/Sideloadly-(macOS-&-Windows) · https://hamradio.my/sideloadly-the-ultimate-ios-sideloading-tool-without-jailbreak/ · App-IDs: https://faq.altstore.io/altstore-classic/app-ids · iloader: https://github.com/nab138/iloader · Swift für Windows: https://swift.org/install/windows/ · AlarmKit-Beispiel (Extension-Hinweis, `.custom`): https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit · Schlummern per Intent: https://developer.apple.com/forums/thread/849075 · iOS-27-Geräte: https://appleinsider.com/articles/26/06/08/ios-27-keeps-iphone-11-and-newer-compatibility · Claude Code auf Windows: https://code.claude.com/docs/en/setup
- Claude Code Skills: https://code.claude.com/docs/en/skills.md · XcodeBuildMCP: https://mcp.directory/blog/xcodebuildmcp-complete-guide-2026 · Xcode-MCP: https://blakecrosley.com/de/blog/xcode-mcp-claude-code · Community-Skills: https://github.com/dpearson2699/swift-ios-skills
