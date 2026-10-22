#!/usr/bin/env bash
# Simulator screenshots of the main screens with demo data (see App/Services/DemoData.swift).
# CI only (needs Xcode): runs after `xcodegen generate` in the `screenshots` job of ios.yml.
# Usage: bash scripts/ci-screenshots.sh <outdir>
set -euo pipefail

OUT="${1:-screenshots}"
BUNDLE=de.jt7q.schlafkurve
mkdir -p "$OUT"

echo "Building for the simulator …"
if ! xcodebuild -project Schlafkurve.xcodeproj -scheme Schlafkurve -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath build/shots \
    CODE_SIGNING_ALLOWED=NO build > build-shots.log 2>&1; then
  grep -E "error:" build-shots.log | sed -E 's#^/Users/runner/work/[^/]+/[^/]+/##' | sort -u | head -n 40
  exit 1
fi
APP=$(find build/shots/Build/Products -maxdepth 2 -name "Schlafkurve.app" | head -n 1)
echo "App: $APP"

# Newest iOS runtime >= 26, prefer an "iPhone NN Pro" (not Max).
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, items in devices.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m or int(m.group(1)) < 26:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in items:
        name = d["name"]
        if not name.startswith("iPhone"):
            continue
        score = (version, "Pro" in name and "Max" not in name, name)
        if best is None or score > best[0]:
            best = (score, d["udid"])
if best is None:
    sys.exit("no iOS 26+ iPhone simulator available")
print(best[1])
')
echo "Simulator: $UDID"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance dark || true
xcrun simctl status_bar "$UDID" override --time "23:41" --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4 || true
xcrun simctl install "$UDID" "$APP"

shot() {
  local name=$1
  shift
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE" -demoNights YES "$@" >/dev/null
  sleep "${WAIT:-6}"
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null
  echo "  $name.png"
}

# First launch writes the demo nights – give it more time.
WAIT=20 shot 01-wecker -demoTab setup
shot 02-nacht -demoTab night
shot 03-bericht -demoTab report
shot 04-bericht-kurve -demoTab report -demoScroll chart
shot 05-bericht-phasen -demoTab report -demoScroll phases
shot 06-bericht-schnarchen -demoTab report -demoScroll snore
shot 07-bericht-aufnahmen -demoTab report -demoScroll recordings
shot 08-bericht-stimmung -demoTab report -demoScroll mood
shot 09-naechte -demoTab history
shot 10-statistik -demoTab stats
shot 11-einstellungen -demoTab settings

# Large text (Dynamic Type) check
xcrun simctl ui "$UDID" content_size accessibility-large || true
shot 12-bericht-grosse-schrift -demoTab report
shot 13-wecker-grosse-schrift -demoTab setup
xcrun simctl ui "$UDID" content_size large || true

ls -l "$OUT"
