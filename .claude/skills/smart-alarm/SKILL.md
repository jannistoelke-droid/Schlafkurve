---
name: smart-alarm
description: Smart wake-up logic and its AlarmKit integration - wake window, WakeDecider rules, backup alarm at the latest time, replacement alarm when light sleep is detected, gentle pre-alarm through the app's audio session, snooze without an app extension via a custom secondary button, stop intent that ends the session and opens the morning report, plus edge cases and device tests. Use when working on WakeDecider, AlarmService, alarm intents (stop, snooze) or any wake-up bug.
---

# Smart alarm

## Behaviour (mirrors Sleep Cycle)
- User sets the **latest** wake time `T` and a window `W` (0 = exact, 10, 15, 20, 30 default, 45, 60, 90 min). The window ends at `T`.
- Modes: smart + tracking · regular alarm + tracking (W = 0) · tracking only (no alarm).
- Inside `[T-W, T)` the app wakes the user as soon as it sees light sleep or wakefulness; otherwise it rings at `T`.
- The wake reason is stored: `.smartLightSleep`, `.awakeDetected`, `.deadline`, `.manualStop`, `.backupFired` (app was dead).

## WakeDecider (pure, in SleepEngineCore, unit-tested)
```swift
public enum WakeDecision: Equatable { case wait, wakeNow(WakeReason) }

public struct WakeDecider {
    public init(config: Tuning.Wake)
    public func evaluate(now: Date, latest: Date, window: TimeInterval,
                         recent: [LiveEpoch]) -> WakeDecision
}
```
Rules (defaults in `Tuning.wake`):
1. `now < latest - window` → `.wait`. `now ≥ latest` → `.wakeNow(.deadline)`.
2. Last epoch stage = wake with movementSeconds ≥ 5 → `.wakeNow(.awakeDetected)`.
3. Last 2 epochs both in {light, wake} **and** (movementCount over last 2 epochs ≥ 1 **or** z of last epoch ≥ 0.5) **and** no deep epoch in the last 3 → `.wakeNow(.smartLightSleep)`.
4. Guard against noise: movement that coincides with an environment event (dog, traffic) does not count for rule 3.
5. If the user never fell asleep (no onset) → behave like rule 2/deadline only.
Evaluate once per completed epoch (every 30 s) on the processing queue; hop to the main actor only to trigger AlarmService.

## AlarmKit facts to respect
- iOS 26+, `import AlarmKit`, Info.plist `NSAlarmKitUsageDescription`. Ask permission on the setup screen (`AlarmManager.shared.requestAuthorization()`); check `authorizationState`.
- Alarms break through silent mode and **all** Focus modes, persist through app crash, force quit and reboot once scheduled.
- `Alarm.Schedule.fixed(Date)` = one-shot absolute time (does not move with time-zone changes – fine for one night).
- Apple: AlarmKit **expects a widget extension if an app supports a countdown presentation**, otherwise the system may dismiss alarms and fail to alert. v1 has **no extensions** (free-account App-ID budget, sideloading) → never use `countdownDuration` / `.countdown`. The alerting UI itself is system-rendered and needs no extension.
- Secondary button behaviours: `.countdown` (built-in repeat/snooze – needs the extension, not used) and `.custom` (runs our `secondaryIntent`). Snooze in v1 = `.custom` button „Schlummern“ whose `LiveActivityIntent` schedules a new one-shot alarm at now + snooze, then stops the alerting one. Developers report this works in the background but is not documented as guaranteed → schedule first, stop second, idempotent per alarm ID, and offer the setting „Schlummern aus“.
- The stop intent's `perform()` runs when the alarm is dismissed (button, swipe or hardware button).
- Custom sounds via `AlertConfiguration.AlertSound.named("…")` from the main bundle have been reported flaky (system default plays, or file plays once). Default to `.default`; offer the custom tone as a setting and verify on device.
- Apps that are hidden or locked behind Face ID cannot use AlarmKit (tell the user).
- No fixed limit on alarm count, but `maximumLimitReached` can occur – we only ever hold 1–2 alarms.

## Code sketch (verify every signature against the iOS 27 SDK docs before use)
```swift
// App/Alarm/ (no extension in v1)
struct SleepAlarmMetadata: AlarmMetadata { var sessionID: UUID }

// App/Services/AlarmService.swift
@MainActor final class AlarmService {
    private(set) var backupID: UUID?
    private(set) var activeID: UUID?

    func scheduleBackup(at latest: Date, session: UUID) async throws {
        let id = UUID()
        _ = try await AlarmManager.shared.schedule(id: id, configuration: makeConfig(.fixed(latest), session: session, id: id))
        backupID = id
    }

    /// Smart trigger: schedule replacement first, cancel backup only if that succeeded.
    func fireNow(preAlarm seconds: TimeInterval, session: UUID) async throws {
        let id = UUID()
        _ = try await AlarmManager.shared.schedule(id: id, configuration: makeConfig(.fixed(.now + max(seconds, 2)), session: session, id: id))
        activeID = id
        if let b = backupID { try? AlarmManager.shared.cancel(id: b); backupID = nil }
    }

    private func makeConfig(_ schedule: Alarm.Schedule, session: UUID, id: UUID)
        -> AlarmManager.AlarmConfiguration<SleepAlarmMetadata> {
        // Alert presentation: AlarmPresentation.Alert(title: "Guten Morgen", stopButton: …,
        //   secondaryButton: snoozeEnabled ? AlarmButton(text: "Schlummern", …) : nil,
        //   secondaryButtonBehavior: snoozeEnabled ? .custom : nil)      // never .countdown in v1
        // Attributes: AlarmAttributes(presentation: AlarmPresentation(alert: alert),
        //   metadata: SleepAlarmMetadata(sessionID: session), tintColor: .indigo)
        // stopIntent: StopSleepAlarmIntent(alarmID: id.uuidString)
        // secondaryIntent: snoozeEnabled ? SnoozeSleepAlarmIntent(alarmID: id.uuidString) : nil
        // countdownDuration: nil · sound: .default (or the user's custom tone)
        // Build with AlarmManager.AlarmConfiguration(countdownDuration:schedule:attributes:stopIntent:secondaryIntent:sound:)
        // after checking the current initialisers in the SDK docs.
        preconditionFailure("sketch – implement as described above")
    }
}
```
```swift
// App/Alarm/StopSleepAlarmIntent.swift
struct StopSleepAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Wecker stoppen"
    @Parameter(title: "Alarm") var alarmID: String
    init() {}
    init(alarmID: String) { self.alarmID = alarmID }
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) { try? AlarmManager.shared.stop(id: id) }
        await SessionController.shared.finish(reason: .alarmStopped)   // ends capture, final analysis, report ready
        return .result()
    }
}
```
- `SessionController.finish` must be idempotent (stop intent, manual stop and `alarmUpdates` observation can all call it).
- `SnoozeSleepAlarmIntent` (LiveActivityIntent, background mode): `perform()` → `AlarmService.scheduleSnooze(minutes:)` (new `.fixed(now + snooze)` alarm with the same buttons) → only on success `AlarmManager.shared.stop(id:)` the alerting one → log both. Guard against double execution per alarm ID.
- Also observe `AlarmManager.shared.alarmUpdates` to log `scheduled/alerting/dismissed` into the event log and to recover state after relaunch (an alarm missing from the stream is no longer scheduled).
- After finishing: post a normal local notification "Dein Schlafbericht ist fertig" (needs only the standard notification permission) and set `pendingReportSessionID` so the app opens straight into the report.

## Gentle pre-alarm (optional setting, default on, 60 s)
- At the smart trigger the app plays a soft looping sound through its **already active** session via an `AVAudioPlayerNode` on the capture engine, fading 0 → 1 over the pre-alarm time, then AlarmKit takes over at `now + preAlarm`.
- Output must go to the speaker (`.defaultToSpeaker`). The app cannot set the system volume – show a hint on the setup screen to keep alarm/media volume up (iOS 27 has a separate alarm volume).
- Stop the pre-alarm player when the AlarmKit alert starts (observe `alarmUpdates` → `.alerting`) or when the user stops.
- During pre-alarm and after the alert begins, ignore our own playback in the analysis (mark frames as `selfPlayback`).

## Edge cases
- Start after the latest time already passed today → interpret as tomorrow; show the resolved date/time on the setup screen.
- Window larger than time until `T` → window starts now.
- Backup scheduling fails (no permission) → block Start in alarm modes, offer "Nur Tracking" or fix permission.
- Audio pipeline dies mid-night → backup still fires; report shows data gap and wake reason `.backupFired`.
- User stops tracking manually before the window → cancel all our alarms (confirm dialog), finish session.
- DST change during the night: `.fixed(Date)` is absolute; compute `T` from local components at setup time.
- Snooze: do not resume smart decisions; keep capturing for the report until the final stop. If the snooze intent fails, the original alarm keeps alerting – acceptable, the user can stop it.
- Tracking-only mode: no alarms; the session ends when the user taps Stop.

## Device tests (Phase 4)
Use the test session (latest = now + 10 min, window 5 min):
1. Lie still → rings at deadline, reason `.deadline`.
2. Rustle/handle the phone inside the window → rings early, reason `.smartLightSleep` or `.awakeDetected`.
3. Kill the app from the app switcher after Start → backup rings at the latest time.
4. Snooze once (new alarm rings after the snooze time), then stop → report opens, event log shows snooze scheduling + dismissal.
5. Silent switch on + Sleep Focus on → alarm still rings.
