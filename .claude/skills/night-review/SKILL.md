---
name: night-review
description: Morning-after review of a real night recorded with Schlafkurve - pull the session from the iPhone, check data quality and gaps, compare detections with what the user heard and felt, tune thresholds in Tuning.swift, re-run all stored nights and log the result. Run only when the user types /night-review.
disable-model-invocation: true
argument-hint: "[session-folder-name, default: newest]"
---

# /night-review – tune the app with real nights

Goal of every review: the app gets measurably better on the user's real bedroom, and nothing silently breaks.

## 1. Ask the user (short, in German, one message)
- Wann ungefähr ins Bett / eingeschlafen? Nachts wach gewesen (wann, wie lange)?
- Wie wach/erholt beim Wecken (1–5)? Hat der Smart-Wecker sich "richtig" angefühlt?
- Hat jemand Schnarchen/Reden bemerkt? Partner, Haustier, Fenster offen, Ventilator?
- Hast du im Bericht Clips angehört und Typen korrigiert? (bitte vorher machen)
- Apple Watch getragen? (dann deren Schlafphasen als Vergleich nutzen)

## 2. Pull the data
The user exports the night in the app (Einstellungen → Diagnose → Exportieren) and copies the ZIP via iTunes-Dateifreigabe or iCloud Drive (skill `ios-build-deploy`, section pull). Unzip into `device-data/<session-folder>/` (gitignored, never commit). Session = `$ARGUMENTS` or the newest folder.

## 3. Data quality first
- `eventlog.jsonl`: interruptions, flatlines, engine restarts, memory warnings, thermal state, battery curve, alarm lifecycle (scheduled → alerting → stopped/snoozed).
- Gaps total and where. Any gap ≥ 1 min is a bug or an external cause – find out which before tuning anything.
- If the app was killed: ask the user for the crash/analytics entry (Einstellungen → Datenschutz & Sicherheit → Analyse & Verbesserungen → Analysedaten → `Schlafkurve…`, as text) and fix the cause before touching thresholds.

## 4. Detection accuracy
- List events: time, group, confidence, peakDb, userGroup. Per group: precision = confirmed / (confirmed + corrected-away). Note obvious misses the user remembers.
- Typical fixes: raise energy gate when far-away TV/traffic leaks in; lower snore start threshold if quiet snoring is missed; add labels to the environment group; tighten talk threshold if the partner's speech is picked up.

## 5. Staging and wake-up
- `swift run --package-path Packages/SleepEngine sleepreplay --frames <frames.bin> --report` (runs on Windows with Swift for Windows) → onset, awakenings, stage minutes, depth curve as text/HTML. Without local Swift: quick Python plots of `epochs.json`, and the in-app "Alle Nächte neu analysieren" after the next build.
- Compare with the user's account (onset, awake periods) and, if the user wore an Apple Watch, its sleep stages (Health-App → Profil → Alle Gesundheitsdaten exportieren → convert the sleep records for that night to CSV → `--reference`).
- Check the wake decision: which rule fired, epochs before it, how it felt.

## 6. Tune
- Change only `Tuning.swift`, one hypothesis at a time, with a comment `// night-review YYYY-MM-DD: reason`.
- Re-run **all** stored nights: `sleepreplay --frames device-data/ --compare` and show before/after per night. Reject changes that fix tonight but break earlier nights.
- Tests must stay green; if a bug was found, add a regression test that reproduces the pattern with `SyntheticNight` (no real night data in the repo – it may be public).

## 7. Log and ship
- Append to `docs/NIGHT_LOG.md`: date, data quality, user notes, findings, changes, before/after numbers.
- Commit "night-review YYYY-MM-DD: …" (never include `device-data/`). If app code changed: push, wait for green CI, download the IPA and have the user re-install it with Sideloadly (this also resets the 7-day clock).
- End with 2–3 concrete things for the user to try tonight (e.g. phone position, full-night recording on/off).
