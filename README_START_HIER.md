# Start hier – „Schlafkurve“ mit Claude Code bauen (Windows 10 + iPhone 14 Pro)

## Wie das ohne Mac funktioniert

iPhone-Apps lassen sich nur auf einem Mac kompilieren. Deshalb läuft es so:

```
Dein Windows-PC            GitHub (kostenloser Mac-Server)          Dein iPhone 14 Pro
Claude Code schreibt  ──▶  baut & testet die App,           ──▶   du installierst sie mit
den Code                   erzeugt eine .ipa-Datei                 Sideloadly + Apple-ID
```

Kostet nichts: GitHub-Builds sind für öffentliche Repos kostenlos, Sideloadly ist kostenlos, eine normale Apple-ID reicht.

## Was im Kit ist

| Datei | Wofür |
|---|---|
| `MASTER_PROMPT.md` | Der Auftrag: Ziel, Funktionen, Architektur, Phasenplan mit Abnahmekriterien |
| `CLAUDE.md` | Projektregeln, die Claude Code bei jedem Start liest |
| `.claude/skills/` | 7 Fach-Skills: Nacht-Audio, Geräuscherkennung, Schlafphasen, Smart Alarm, Bericht-UI, Bauen & Installieren, Morgen-Auswertung |
| `.github/workflows/ios.yml` | Bauanleitung für den Mac-Server von GitHub |
| `.claude/settings.json` | Erlaubt Claude Code, ohne Rückfrage zu testen, zu pushen und Builds abzuholen |
| `docs/RESEARCH.md` | Analyse von Sleep Cycle + alle technischen Fakten mit Quellen |

---

## 1. Einmalige Einrichtung (ca. 30–45 Minuten)

**Auf dem PC** (PowerShell öffnen):
1. **Claude Code** installieren: `irm https://claude.ai/install.ps1 | iex` – danach neues Fenster, `claude --version`. (Du brauchst ein Claude-Abo mit Claude Code, z. B. Pro oder Max.)
2. **Git für Windows**: `winget install --id Git.Git -e` – Claude Code nutzt dann Git Bash.
3. **GitHub-Konto** anlegen (kostenlos, github.com) und die **GitHub-CLI**: `winget install --id GitHub.cli -e`, dann `gh auth login`.
4. **iTunes und iCloud direkt von apple.com** installieren – **nicht** die Versionen aus dem Microsoft Store (falls vorhanden, vorher deinstallieren). iTunes einmal öffnen, iPhone per Kabel anschließen, „Diesem Computer vertrauen“.
5. **Sideloadly** von sideloadly.io installieren.
6. *Empfohlen, aber optional:* **Swift für Windows** – damit kann Claude die Schlafanalyse direkt auf deinem PC testen statt jedes Mal auf den Server zu warten. Braucht einige GB (Visual Studio Build Tools). Die genauen Befehle stehen in `.claude/skills/ios-build-deploy/SKILL.md`; Claude Code hilft dir dabei.
7. *Optional:* **Python** (`winget install --id Python.Python.3.12 -e`) für schnelle Daten-Grafiken beim Feintuning.

**Auf dem iPhone 14 Pro:**
- iOS 26 oder neuer (iOS 27 läuft auf dem 14 Pro).
- Deine Apple-ID muss schon mal auf einem iPhone angemeldet gewesen sein – ist bei dir der Fall.
- Den **Entwicklermodus** schaltest du erst nach der ersten Installation ein (Claude führt dich in Phase 0 hin).

**Projektordner:** z. B. `C:\Projekte\Schlafkurve` anlegen und den **kompletten** Kit-Inhalt hineinkopieren. Achtung: `.claude` und `.github` beginnen mit einem Punkt – im Explorer unter *Ansicht → Ausgeblendete Elemente* sichtbar machen und mitkopieren.

## 2. Session starten

```powershell
cd C:\Projekte\Schlafkurve
claude
```
Dann schreibst du:

> **Lies MASTER_PROMPT.md, CLAUDE.md und docs/RESEARCH.md vollständig und starte mit Phase 0.**

Nimm das stärkste verfügbare Modell. Claude arbeitet die Phasen 0–6 ab und hält an **⏸ STOPP**-Punkten an:

| Phase | Was du tust |
|---|---|
| 0 | Entscheiden: Repo öffentlich (empfohlen) oder privat. Erste `.ipa` mit Sideloadly installieren, Entwickler vertrauen, Entwicklermodus einschalten |
| 2 | Neue Version installieren, Testsession starten, iPhone 15 Minuten gesperrt liegen lassen, Daten exportieren |
| 3 | Absichtlich schnarchen, reden, husten, klatschen – Clips anhören, exportieren |
| 4 | Wecker-Tests: still liegen, Handy bewegen, App wegwischen, schlummern, Stummschalter an |

Nach jeder größeren Änderung baut GitHub die App neu (5–15 Minuten). Claude lädt die fertige `.ipa` in den Ordner `dist\`; du ziehst sie in Sideloadly und installierst sie **über die bestehende App** – deine Daten bleiben erhalten.

Wird die Session unterbrochen: „Mach bei Phase X weiter, lies vorher MASTER_PROMPT.md“ – der Fortschritt steckt in Git.

## 3. Daten vom iPhone auf den PC holen

In der App: Einstellungen → Diagnose → **Exportieren**. Dann entweder
- **per Kabel:** iTunes → iPhone-Symbol → **Dateifreigabe** → Schlafkurve → ZIP auf den Desktop ziehen, oder
- **per iCloud:** „In Dateien sichern“ → iCloud Drive → erscheint im iCloud-Drive-Ordner im Explorer.

Claude entpackt das nach `device-data\` – dieser Ordner wird **nie** zu GitHub hochgeladen.

## 4. Die erste echte Nacht

- iPhone **am Ladekabel**, auf dem Nachttisch, Unterseite (Mikrofon) Richtung Bett, ca. 0,5–1 m entfernt.
- **Flugmodus oder Schlaf-Fokus** an. Der Wecker klingelt trotzdem.
- Keine Musik-/Podcast-App laufen lassen, keine Bluetooth-Kopfhörer verbunden.
- In den ersten Nächten **Ganznacht-Aufnahme** einschalten (hilft beim Feintuning).
- Morgens: Bericht ansehen, Clips anhören, falsche Typen korrigieren, Nacht exportieren, in Claude Code **`/night-review`** tippen.

## 5. Alle 7 Tage neu installieren

Mit kostenloser Apple-ID läuft die App 7 Tage. Dann in Claude Code **`/ios-build-deploy refresh`** – Claude holt die aktuelle `.ipa`, du installierst sie mit Sideloadly über die alte App. **Die App nie löschen** und **immer dieselbe Apple-ID** nehmen, sonst sind die Nächte weg. Tipp: Kalender-Erinnerung. Sideloadly kann auch automatisch erneuern, wenn PC und iPhone im selben WLAN sind und der PC läuft.

## 6. Ehrliche Einschätzung

- **Machbar:** Aufnahme über Nacht, Schnarchen/Reden/Husten mit Clips, Smart-Wecker mit System-Alarm, Morgenbericht mit Graph, Verlauf. Ohne Mac dauert es länger als mit: Jeder Kompiliervorgang läuft über GitHub, Testen geht nur auf dem iPhone. Plane eher 2–3 Sessions statt einer.
- **Braucht echte Nächte:** Wie stabil und genau alles in *deinem* Schlafzimmer ist, zeigt sich erst nachts. Rechne mit 3–7 Nächten Feintuning per `/night-review`.
- **Schlafphasen sind Schätzungen:** Schnarchen und Sprechen erkennt Apples eingebaute Klangerkennung gut. Wach/Schlaf und leicht/tief reichen für einen guten Smart-Wecker; REM ist eine Annäherung.
- Kein Medizinprodukt, keine Diagnosen.

## 7. Falls es hakt

- **Sideloadly findet das iPhone nicht:** iTunes von apple.com (nicht Store), iPhone entsperren, Kabel tauschen, „Vertrauen“ bestätigen.
- **„Unbekannter Entwickler“ beim Öffnen:** Einstellungen → Allgemein → VPN & Geräteverwaltung → deiner Apple-ID vertrauen.
- **Build schlägt fehl:** Claude liest die Fehler selbst aus GitHub – einfach „CI ist rot, bitte reparieren“.
- **Wenn es dauerhaft zu zäh wird:** Ein gebrauchter Mac mini mit Apple-Chip macht alles deutlich schneller; das Kit funktioniert dann unverändert weiter (Hinweise im Skill `ios-build-deploy`).
