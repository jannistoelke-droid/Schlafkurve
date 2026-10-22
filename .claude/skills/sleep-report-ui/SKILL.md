---
name: sleep-report-ui
description: SwiftUI and Swift Charts design for the sleep app - night theme, alarm setup screen, night screen, morning report with sleep-depth curve, hypnogram bands, event lane, scrubber and clip playback, recordings list, history and trend charts, settings, accessibility. Use when building or changing any screen, chart, colour or layout in the app.
---

# Report and UI

## Design tokens (`App/Design/Theme.swift`)
- Dark by default (night use). Background `#0B1020`, surface `#141A2E`, elevated `#1C2440`, text primary `#E8ECF8`, secondary `#9AA4C2`, hairline `#2A3352`.
- Stage colours: Wach `#FF8A65` (coral), REM/Traum `#B388FF` (violet), Leicht `#64B5F6` (sky), Tief `#3949AB` (indigo).
- Event colours: Schnarchen `#FFA726`, Reden `#26C6DA`, Husten `#F06292`, Umgebung `#90A4AE`, Laut `#FFEE58`, Datenlücke = diagonal hatch in secondary text colour at 30 %.
- Numbers in `.system(.largeTitle, design: .rounded).monospacedDigit()`. Corner radius 20 for cards, 12 for chips. Spacing grid 4/8/16/24.
- Never rely on colour alone: every stage/event also has an SF Symbol (`sun.max`, `sparkles`, `cloud`, `moon.zzz`, `zzz`, `text.bubble`, `lungs`, `pawprint`, `speaker.wave.3`).
- Respect Dynamic Type and Reduce Motion.

## Screens
1. **Wecker (setup)**: large time picker (wheel or circular dial) for the latest time; window chips; mode segmented control; summary line "Weckt dich zwischen 06:30 und 07:00 · noch ca. 7 h 40 min"; preflight checklist with green/yellow/red rows (mic, AlarmKit, battery/charger, free space, focus hint, Bluetooth); big Start button.
2. **Nacht**: pure black, clock (thin rounded font, dimmed), window text, optional tiny level meter, hold-to-stop control (1.5 s) with haptic, status dot (green = capturing, yellow = recovering, red = gap). No animations while locked.
3. **Morgenbericht** (scroll view of cards):
   - Header: date, "Im Bett 23:12 – 06:41", quality ring (0–100 %), asleep duration, latency, wake time + reason text.
   - Main chart card (see below).
   - Stage share bar (stacked horizontal) + minutes per stage.
   - Snoring card: total minutes, % of night, episodes, bar chart per 15 min.
   - Event counts row (Reden, Husten, Umgebung, Laut) → tap scrolls to recordings.
   - Breathing card (avg breaths/min, mini line over the night) – hidden if unknown.
   - Noise card: level over the night (relative dB above floor).
   - Data quality card: gaps with reason and duration; hidden if none.
   - Recordings section: highlights, then grouped list.
   - Mood (3 faces) + note tags chips → saved on tap.
4. **Nächte (history)**: list rows with date, duration, quality, snore minutes, mini depth sparkline; swipe to delete; tap → report.
5. **Statistik**: 7/30-day toggles; charts for quality, asleep time (bar), snore minutes (bar), bedtime and wake time (point + range, regularity as std dev), notes impact (average quality with vs without tag, only when ≥ 3 nights each).
6. **Einstellungen**: sections Wecken, Erkennung, Speicher, Ziele, Diagnose (hidden debug entry), Über (version, "kein Medizinprodukt").

## Main chart (Swift Charts, iOS 26+)
Single `Chart` with a shared time x-axis (session start → end), plus a separate event lane below sharing the same x-scale.
```swift
Chart {
    // 1. stage bands as background
    ForEach(stageRuns) { run in
        RectangleMark(xStart: .value("Start", run.start), xEnd: .value("Ende", run.end),
                      yStart: .value("", 0), yEnd: .value("", 1))
            .foregroundStyle(run.stage.color.opacity(0.18))
    }
    // 2. depth curve (awake at top → plot 1 - depth)
    ForEach(depthPoints) { p in
        AreaMark(x: .value("Zeit", p.time), y: .value("Wachheit", 1 - p.depth))
            .interpolationMethod(.catmullRom)
            .foregroundStyle(.linearGradient(colors: [Theme.wake.opacity(0.35), Theme.deep.opacity(0.05)], startPoint: .top, endPoint: .bottom))
        LineMark(x: .value("Zeit", p.time), y: .value("Wachheit", 1 - p.depth))
            .interpolationMethod(.catmullRom).lineStyle(.init(lineWidth: 2))
    }
    // 3. gaps
    ForEach(gaps) { g in RectangleMark(xStart: .value("", g.start), xEnd: .value("", g.end)).foregroundStyle(.gray.opacity(0.25)) }
    // 4. scrubber
    if let t = selectedTime { RuleMark(x: .value("Auswahl", t)).foregroundStyle(.white.opacity(0.6)) }
}
.chartYScale(domain: 0...1)
.chartYAxis { AxisMarks(values: [0.05, 0.35, 0.65, 0.95]) { v in AxisValueLabel { Text(label(for: v)) } } } // Tief/Leicht/REM/Wach
.chartXAxis { AxisMarks(values: .stride(by: .hour)) { AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
.chartXSelection(value: $selectedTime)
.frame(height: 220)
```
- Event lane: second `Chart` (height 44) with `PointMark` per event (symbol + colour per group, size by peakDb) and `BarMark`s for snore episodes; same `chartXScale(domain:)` as the main chart. Tap → nearest event within 2 min → play its clip; long-press → popover with time, type, duration, relabel menu.
- Scrubber overlay text: "03:12 · Tiefschlaf · Schnarchen" using the selected time.
- Accessibility: implement `AXChartDescriptorRepresentable` for the main chart (stage per hour as series) and give each event mark an accessibility label.
- Downsample the depth curve to ≤ 400 points for drawing; keep full resolution in data.

## Clip playback
- Report is only shown after the session finished, so playback may use its own session config: set category `.playback` when the report appears, deactivate when leaving. Never touch the session while a night session is running (guard on `SessionController.isTracking`).
- One shared `ClipPlayer` (`@Observable`, AVAudioPlayer) so starting a clip stops the previous one; progress ring in the row; play/pause also from the event lane.
- Row: time (HH:mm), group icon, duration, 64-bar waveform (`Canvas`), play button, favourite star, menu (Typ ändern, Teilen via `ShareLink` of the .m4a, Löschen).
- Transcript line under talk clips when available (later phase), labelled "experimentell".

## Demo data and screenshots (no Mac → no live SwiftUI previews)
- `DemoData` built from `SyntheticNight` (snoring night, restless night, night with gaps, empty history), selectable via launch arguments: `-demoReport snoring|restless|gaps`, `-demoTab history|stats|settings|setup|night`, `-uiDark YES|NO`, `-contentSize XXXL`.
- `scripts/ci-screenshots.sh <outdir>`: build for the simulator, boot an available iPhone simulator (`xcrun simctl list devices available -j`), install, launch with each argument set, wait 3 s, `xcrun simctl io booted screenshot <outdir>/<name>.png`. Triggered via `gh workflow run ios.yml -f screenshots=true`; download with `gh run download <id> -n screenshots-<n>` and look at every PNG (Read tool) before finishing a UI phase. Fix clipping, overlaps, unreadable contrast, truncated German strings.
- Keep `#Preview` blocks anyway (cheap, useful if a Mac ever appears).
