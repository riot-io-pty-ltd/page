#!/usr/bin/env bash
# Builds the Page app for the iOS Simulator, installs it on a simulator named
# "Page Render" (created if missing) and screenshots every Night Watch fixture
# screen of the DEBUG render harness into a directory.
#
#   iOS/Tools/render-screens.sh [out-dir] [glow ...] [-- screen ...]
#
# out-dir defaults to the session scratchpad's ios-renders folder. glow is any
# of off, subtle, full (default: off); each screen is captured once per glow.
# The harness (-NWRender <screen> -NWGlow <glow>) seeds in-memory fixtures
# only: no Keychain, network or push, and it never writes the Card glow setting.
#
# Simulator only. This script never touches a physical device.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ios="$(cd "$here/.." && pwd)"
default_out="/private/tmp/claude-501/-Users-roysinclair-projects-mac-on-claude-code/b84356ec-c2dc-40b5-89f0-6948ea5c3815/scratchpad/ios-renders"
out="${1:-$default_out}"
[ $# -gt 0 ] && shift || true

glows=()
screens=()
mode=glow
for a in "$@"; do
  if [ "$a" = "--" ]; then mode=screen; continue; fi
  if [ "$mode" = glow ]; then glows+=("$a"); else screens+=("$a"); fi
done
[ ${#glows[@]} -gt 0 ] || glows=(off)
if [ ${#screens[@]} -eq 0 ]; then
  # One list: RenderHarness.screens in Services/RenderHarness.swift.
  while IFS= read -r name; do screens+=("$name"); done < <(python3 -I - "$ios/Page/Services/RenderHarness.swift" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
block = src[src.index("static let screens = ["):]
block = block[:block.index("]")]
for name in re.findall(r'"([a-z0-9-]+)"', block):
    print(name)
PY
)
fi

sim_name="Page Render"

# 1. An iOS runtime must exist; the build alone can still be checked without one.
runtime="$(xcrun simctl list runtimes -j | python3 -I -c '
import json, sys
rt = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS")]
print(sorted(rt, key=lambda r: r["version"])[-1]["identifier"] if rt else "")
')"
if [ -z "$runtime" ]; then
  echo "No iOS Simulator runtime is installed (Xcode > Settings > Components may still be downloading one)."
  echo "Build-check only; skipping the screenshots."
  xcodebuild -project "$ios/Page.xcodeproj" -scheme Page -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$ios/build/DerivedData" build | tail -3
  echo "For a stand-in render without a runtime: $here/render-proxy-macos.sh <out-dir>"
  exit 3
fi

# 2. The "Page Render" simulator: an iPhone 15 Pro if the runtime has it, else
#    the closest phone-shaped device it supports. Whatever is used is named, so
#    a render is never mistaken for the iPhone 15 Pro the boards are drawn on.
pick_type() {
  xcrun simctl list runtimes -j | python3 -I -c '
import json, re, sys
rid = sys.argv[1]
for r in json.load(sys.stdin)["runtimes"]:
    if r["identifier"] != rid:
        continue
    types = [t for t in r.get("supportedDeviceTypes", []) if "iPhone" in t["name"]]
    def rank(t):
        n = t["name"]
        if n == "iPhone 15 Pro": return (0, 0, n)
        m = re.match(r"iPhone (\d+)( Pro)?$", n)
        if m: return (1, abs(int(m.group(1)) - 15) + (0 if m.group(2) else 1), n)   # a numbered phone near 15, Pro first
        if "Duo" in n or "Fold" in n: return (3, 0, n)                                # not phone-shaped
        return (2, 0, n)
    types.sort(key=rank)
    print(types[0]["identifier"] + "|" + types[0]["name"] if types else "")
' "$1"
}
picked="$(pick_type "$runtime")"
[ -n "$picked" ] || { echo "Runtime $runtime has no iPhone device type."; exit 4; }
devtype="${picked%%|*}"; devname="${picked#*|}"
udid="$(xcrun simctl list devices -j | python3 -I -c '
import json, sys
name = sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == name and d.get("isAvailable", True):
            print(d["udid"]); raise SystemExit
' "$sim_name")"
if [ -z "$udid" ]; then
  udid="$(xcrun simctl create "$sim_name" "$devtype" "$runtime")"
  echo "Created simulator $sim_name ($udid) as $devname"
fi
actual="$(xcrun simctl list devices -j | python3 -I -c '
import json, sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["udid"] == sys.argv[1]: print(d.get("deviceTypeIdentifier", "").split(".")[-1].replace("-", " "))
' "$udid")"
if [ "$actual" != "iPhone 15 Pro" ]; then
  echo "WARNING: rendering on '$actual', not an iPhone 15 Pro (this runtime offers '$devname')."
  echo "         Sizes and positions will differ from the boards; compare layout, not pixels."
fi
xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$udid" || true

# 3. Build (unsigned, for this simulator) and install.
xcodebuild -project "$ios/Page.xcodeproj" -scheme Page -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$ios/build/DerivedData" build | tail -3
app="$ios/build/DerivedData/Build/Products/Debug-iphonesimulator/Page.app"
[ -d "$app" ] || { echo "Built app not found at $app"; exit 5; }
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
xcrun simctl install "$udid" "$app"

# 4. Dark appearance, a fixed status bar, then one screenshot per screen and glow.
xcrun simctl ui "$udid" appearance dark || true
xcrun simctl status_bar "$udid" override --time "1:12" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 || true
mkdir -p "$out"
for glow in "${glows[@]}"; do
  for screen in "${screens[@]}"; do
    xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
    xcrun simctl launch "$udid" "$bundle" -NWRender "$screen" -NWGlow "$glow" >/dev/null
    sleep 2
    xcrun simctl io "$udid" screenshot "$out/$screen-glow-$glow.png" >/dev/null
    echo "captured $screen (glow $glow)"
  done
done
xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
echo "Screenshots are in $out"
