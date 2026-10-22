---
name: ios-build-deploy
description: Build, test and ship the Schlafkurve iPhone app from a Windows PC without a Mac - GitHub Actions macOS CI (XcodeGen, engine tests, simulator compile check, unsigned IPA, screenshots), the gh CLI loop, local Swift-for-Windows engine tests, installing the IPA with Sideloadly and a free Apple ID, the 7-day refresh, and getting night data back from the iPhone. Use for any build, CI failure, installation, signing, "app expired" or data-transfer task, and when the user types /ios-build-deploy.
argument-hint: "[status|build|install|refresh|pull]"
---

# Build and deploy from Windows (no Mac)

```
Windows PC (Claude Code, git, gh)  ──push──▶  GitHub Actions macos-26 runner
                                               swift test · xcodegen · xcodebuild · unsigned .ipa
Windows PC  ◀──gh run download──  artifact Schlafkurve-ipa-<n>
Windows PC (Sideloadly + free Apple ID) ──USB/Wi-Fi──▶ iPhone 14 Pro
iPhone (in-app ZIP export) ──iTunes file sharing / iCloud Drive──▶ device-data/ on the PC
```

## Prerequisites (check, do not assume)
Run in Git Bash (or PowerShell equivalents):
```bash
git --version && gh --version && gh auth status   # GitHub CLI: winget install --id GitHub.cli ; gh auth login
swift --version || echo "optional: Swift for Windows not installed"
python --version || echo "optional: Python for quick data plots"
```
User side: Windows iTunes and iCloud **from apple.com, not the Microsoft Store versions** (Sideloadly needs them), Sideloadly from sideloadly.io, an Apple ID that has been signed in on an iPhone before.

## Repository and CI
- Create once: `gh repo create schlafkurve --public --source . --remote origin --push` (ask the user public vs private in Phase 0: public = free macOS minutes; private = limited included minutes and macOS minutes are billed at a premium). The repo never contains personal data.
- Workflow: `.github/workflows/ios.yml` (in the repo from the start). Jobs: engine tests → SoundAnalysis label list → `xcodegen generate` → simulator compile check → unsigned archive → IPA artifact; optional `screenshots` job via `workflow_dispatch`.
- The runner image `macos-26` ships several Xcode 26.x versions; the workflow selects the newest non-beta one. `xcode-27` exists as a separate (preview) image – only switch after it is GA, and record it in `docs/DECISIONS.md`.

### The CI loop (keep round trips low – each costs 5–15 minutes)
```bash
git add -A && git commit -m "feat: …" && git push
RUN=$(gh run list --workflow ios.yml -L 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RUN" --exit-status || gh run view "$RUN" --log-failed | grep -E "error:|failed|Fatal" -A 4 | head -n 120
```
- Before pushing Apple-framework code: verify every unfamiliar signature in the docs (`https://developer.apple.com/documentation/<framework>/<symbol>.md`).
- Group related edits into one push. Docs-only commits get `[skip ci]` (markdown changes are also ignored by `paths-ignore`).
- If the failure is in the archive step but the simulator build passed, look for device-only issues (architectures, `#if targetEnvironment(simulator)`, missing Info.plist keys).
- Never print whole logs into context; the failed-step logs are uploaded as artifact `build-logs-<n>` if you need more.

### Local fast loop on Windows (optional but recommended)
`SleepEngineCore` is pure Swift + Foundation. With Swift for Windows installed:
```bash
swift test --package-path Packages/SleepEngine --filter SleepEngineCoreTests
swift run  --package-path Packages/SleepEngine sleepreplay --frames device-data/<night>/frames.bin --report
```
Apple-only targets compile to empty modules on Windows (`#if canImport(Accelerate)` / `#if canImport(SoundAnalysis)` around their sources and tests). Installation for the user (needs Visual Studio 2022 build tools, several GB):
```powershell
winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom "--add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.Tools.ARM64" --source winget
winget install --id Swift.Toolchain -e --source winget
```

## Getting the IPA and installing it (user does the Sideloadly part)
```bash
RUN=$(gh run list --workflow ios.yml --status success -L 1 --json databaseId -q '.[0].databaseId')
gh run download "$RUN" --pattern "Schlafkurve-ipa-*" --dir dist/
ls dist/*/*.ipa
```
Then tell the user, in German, exactly:
1. iPhone per USB anschließen, entsperren, „Diesem Computer vertrauen“.
2. Sideloadly öffnen → Gerät wählen → Apple-ID eintragen → die `.ipa` aus `dist\…` hineinziehen → **Start** → Passwort/2FA eingeben.
3. Beim allerersten Mal: Einstellungen → Allgemein → VPN & Geräteverwaltung → Entwickler-App vertrauen; Einstellungen → Datenschutz & Sicherheit → **Entwicklermodus** einschalten (Neustart).
4. Immer dieselbe Apple-ID und dieselbe Bundle-ID verwenden (in Sideloadly nichts an der Bundle-ID ändern) – nur dann bleiben die Nächte bei Updates erhalten. **App nie löschen.**

Free-account facts: apps expire after **7 days**; max **3** sideloaded apps at once; a limited number of App IDs (about 10), each app extension needs its own – that is why v1 has no extensions. Push notifications/iCloud entitlements are unavailable; v1 needs none.

## 7-day refresh (`/ios-build-deploy refresh`)
1. Find the newest green run (or trigger one: `gh workflow run ios.yml`), download the IPA as above.
2. User re-installs with Sideloadly over the existing app (data stays).
3. Alternatives the user may choose: Sideloadly's auto-refresh (enable during install + iTunes Wi-Fi sync; the PC must be on and reachable), or SideStore installed via `iloader` (refreshes on the iPhone itself; third-party, user decides).
4. Print the new expiry date (today + 7 days) and suggest a calendar reminder.

## Getting night data from the iPhone (`/ios-build-deploy pull`)
The app writes export ZIPs to `Documents/Exports/` and declares `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` (set in `project.yml`). Two ways:
- **USB:** iTunes (Windows) → iPhone → Dateifreigabe → Schlafkurve → ZIP auf den PC ziehen.
- **iCloud:** in the app „Exportieren“ → „In Dateien sichern“ → iCloud Drive → appears in the iCloud Drive folder in Windows Explorer.
Unpack into `device-data/<session-folder>/` (gitignored). Never commit it.

## Logs without a Mac
There is no Console.app. Everything diagnostic must go into the per-session `eventlog.jsonl` (lifecycle, interruptions, heartbeats, alarm states, errors with context) and the in-app debug screen. Crash reports: iPhone → Einstellungen → Datenschutz & Sicherheit → Analyse & Verbesserungen → Analysedaten → entries starting with `Schlafkurve` → share as text to the PC.

## If a Mac ever becomes available
Local Xcode, `xcrun devicectl` (install/launch/copy app container), XcodeBuildMCP and Apple's `xcrun mcpbridge` speed everything up. Record the switch in `docs/DECISIONS.md`; the CI workflow keeps working unchanged.
