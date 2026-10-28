#!/usr/bin/env bash
# Renders Night Watch's five signature motions (and Now's: In flight, the Runway, the Horizon's words,
# the badges, the chips, Settled) frame by frame on the "Page
# Render" simulator (the DEBUG harness: -NWRender motion-<name> -NWTime <s>)
# and tiles each motion into a contact sheet like board 07's rows
# (Designs/v4/07-signature-motion.png).
#
#   [ONLY=<regex>] iOS/Tools/render-motion.sh [out-dir] [--no-build]
#
# out-dir defaults to the session scratchpad's motion/ios folder. Frames go to
# <out-dir>/frames, sheets to <out-dir>/<motion>.png. The simulator must
# already exist (iOS/Tools/render-screens.sh creates it). Simulator only: this
# never touches a physical device.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ios="$(cd "$here/.." && pwd)"
out="${1:-/private/tmp/claude-501/-Users-roysinclair-projects-mac-on-claude-code/b84356ec-c2dc-40b5-89f0-6948ea5c3815/scratchpad/motion/ios}"
build=1
[ "${2:-}" = "--no-build" ] && build=0
mkdir -p "$out/frames"

udid="$(xcrun simctl list devices -j | python3 -I -c '
import json, sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == "Page Render" and d.get("isAvailable", True):
            print(d["udid"]); raise SystemExit
')"
[ -n "$udid" ] || { echo "No 'Page Render' simulator: run iOS/Tools/render-screens.sh once first."; exit 3; }
xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$udid" || true

if [ "$build" = 1 ]; then
  xcodebuild -project "$ios/Page.xcodeproj" -scheme Page -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$ios/build/DerivedData" build | tail -2
fi
app="$ios/build/DerivedData/Build/Products/Debug-iphonesimulator/Page.app"
[ -d "$app" ] || { echo "Built app not found at $app"; exit 5; }
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
xcrun simctl install "$udid" "$app"
xcrun simctl ui "$udid" appearance dark || true
xcrun simctl status_bar "$udid" override --time "1:12" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 || true

# screen@seconds for every frame of every sheet (the board's moments, plus a few between).
frames=(
  motion-pulse-quiet@3 motion-pulse-working@2 motion-pulse-working@4 motion-pulse-waiting1@1.2 motion-pulse-waiting3@1.2 motion-pulse-waiting3@2.0
  motion-pulse-exhale@0 motion-pulse-exhale@0.3 motion-pulse-exhale@0.8 motion-pulse-exhale@1.6
  motion-approach@0 motion-approach@0.09 motion-approach@0.18 motion-approach@0.36 motion-approach@0.52
  motion-receipt-arm@0.6 motion-receipt-sending@0.3 motion-receipt-sent@0.8 motion-receipt-typed@0.45 motion-receipt-verified@0.95
  motion-receipt-failed@0.06 motion-receipt-failed@0.6 motion-receipt-fold@1.2 motion-receipt-fold@1.45 motion-receipt-sheet@0.95
  motion-hold@0 motion-hold@0.36 motion-hold@0.9 motion-hold@1.5 motion-hold-burst@0.15 motion-hold-burst@0.4
  lanes@3 motion-dusk@0.7 motion-dusk@3 motion-dawn@0.6 motion-dawn@1.2 motion-dawn@2.4
  now-working@3 motion-dusk-now@0.8 motion-dusk-now@3 motion-dawn-now@0.9 motion-dawn-now@1.8
  motion-brief@0 motion-brief@0.6 motion-brief@1.2 motion-brief@2.6
  motion-inflight-enter@0.0 motion-inflight-enter@0.35 motion-inflight-enter@0.7 motion-inflight-enter@1.4 motion-inflight-enter@3.0
  motion-inflight-advance@1.4 motion-inflight-advance@2.0 motion-inflight-advance@2.2 motion-inflight-advance@2.5 motion-inflight-advance@3.6
  motion-inflight-complete@1.4 motion-inflight-complete@2.2 motion-inflight-complete@2.5 motion-inflight-complete@3.75 motion-inflight-complete@4.5
  motion-inflight-vanish@1.4 motion-inflight-vanish@2.2 motion-inflight-stuck@1.4 motion-inflight-stuck@3.6
  motion-now-enter@0.0 motion-now-enter@0.2 motion-now-enter@0.5 motion-now-enter@1.4
  motion-now-enter-low@0.0 motion-now-enter-low@0.2 motion-now-enter-low@0.5 motion-now-enter-low@1.0
  motion-now-change@1.4 motion-now-change@2.2 motion-now-change@2.5 motion-now-change@3.0
  motion-now-change-low@1.4 motion-now-change-low@2.2 motion-now-change-low@2.5 motion-now-change-low@3.0
  motion-now-runway@1.4 motion-now-runway@2.2 motion-now-runway@2.5 motion-now-runway@3.0
)
for f in "${frames[@]}"; do
  # ONLY=<regex> re-captures just the matching frames.
  if [ -n "${ONLY:-}" ] && ! [[ "$f" =~ $ONLY ]]; then continue; fi
  screen="${f%@*}"; t="${f#*@}"
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" "$bundle" -NWRender "$screen" -NWTime "$t" -NWGlow off >/dev/null
  sleep 2.2
  xcrun simctl io "$udid" screenshot "$out/frames/$f.png" >/dev/null 2>&1
  echo "captured $f"
done
xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true

python3 -I "$here/motion-sheets.py" "$out"
