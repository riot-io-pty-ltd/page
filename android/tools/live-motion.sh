#!/usr/bin/env bash
# Records the debug demo's scripted live run (`--ez page_live_motion true`: a page arrives, the swipe-to-run page is
# approved, the last decisions clear, the battery cutoff falls and power returns) with `adb shell screenrecord`, so
# the signature motions can be seen on their real, unpinned paths: the arrival book, item placement, the one-shot
# clocks, the demo relay's delivery states. Frames are tiled into filmstrips by live-motion-sheets.py.
#
#   android/tools/live-motion.sh [out-dir] [--seconds 20] [--reduce] [--lanes]
#
#   --lanes  Play it on Lanes (the dusk and dawn over the list of lanes) instead of Now.
#   --arrivals  The arrivals script instead: a first page into an empty stream, then one while a finger is held on
#               the stream (it waits behind the "New" pill, which is then tapped), then a short hold on "Hold to
#               approve" let go early (the ring unwinds, nothing is sent). Coordinates are for PagePixel.
#
# Emulator only (emulator-* serials); the emulator must be running with the debug build installed.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
android="$(cd "$here/.." && pwd)"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
adb="$ANDROID_HOME/platform-tools/adb"
pkg="app.page.android.debug"
out=""
seconds=20
reduce=0
lanes=false
script=full
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) seconds="$2"; shift ;;
    --reduce) reduce=1 ;;
    --lanes) lanes=true ;;
    --arrivals) script=arrivals ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) out="$1" ;;
  esac
  shift
done
out="${out:-$android/build/motion-live}"
mkdir -p "$out"
serial="${ANDROID_SERIAL:-emulator-5560}"  # never "the first emulator": emulator-5554 is the PagePixel window
[ -n "$serial" ] || { echo "no emulator running" >&2; exit 1; }
export ANDROID_SERIAL="$serial"

old_anim=""
cleanup() { if [ -n "$old_anim" ]; then "$adb" shell settings put global animator_duration_scale "$old_anim" >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT
if [ "$reduce" = 1 ]; then
  old_anim="$("$adb" shell settings get global animator_duration_scale | tr -d '\r')"
  [ "$old_anim" = null ] && old_anim=1.0
  "$adb" shell settings put global animator_duration_scale 0
fi

"$adb" shell am force-stop "$pkg" >/dev/null
"$adb" shell rm -f /sdcard/page-live.mp4 >/dev/null 2>&1 || true
# Recording first, then the launch: the video's clock starts a moment before the script's.
"$adb" shell screenrecord --time-limit "$seconds" --bit-rate 12000000 /sdcard/page-live.mp4 &
rec=$!
sleep 1
"$adb" shell am start -n "$pkg/app.page.android.MainActivity" --ez page_demo true --ez page_live_motion true --ez page_live_lanes "$lanes" --es page_live_script "$script" >/dev/null
if [ "$script" = arrivals ]; then
  # Seconds after launch (the app takes about 2 s to come up, the script starts with it).
  sleep 7; "$adb" shell input swipe 540 1000 540 1000 3000 &   # a finger on the stream while the second page arrives
  sleep 5; "$adb" shell input tap 540 262                       # the "New" pill
  sleep 3; "$adb" shell input swipe 744 1596 744 1596 900      # Hold to approve, let go at 0.9 s
fi
wait "$rec" || true
sleep 1
"$adb" pull /sdcard/page-live.mp4 "$out/live.mp4" >/dev/null
"$adb" shell am force-stop "$pkg" >/dev/null
echo "$out/live.mp4"
python3 -I "$here/live-motion-sheets.py" "$out/live.mp4" "$out"
