#!/usr/bin/env bash
# Renders Night Watch's five signature motions (and In flight's) frame by frame on the "PagePixel" emulator (the debug render harness:
# `--es page_render motion-<name> --ef page_time <s>`) and tiles each motion into a contact sheet like board 07's rows
# (Designs/v4/07-signature-motion.png), the same frames iOS/Tools/render-motion.sh captures.
#
#   [ONLY=<regex>] [ANDROID_SERIAL=emulator-NNNN] android/tools/render-motion.sh [out-dir] [--no-build] [--canvas [--noblur]]
#       [--reduce | --reduce-harness] [--avd NAME]
#
#   --canvas   Draw with the Canvas fallbacks a phone below Android 13 gets (`--ez page_canvas true`), not AGSL.
#   --noblur   With --canvas: the Canvas aurora as a phone below Android 12 draws it, with no blur.
#   --reduce   Turn on the system's "Remove animations" for the run (restored afterwards): the static equivalents.
#   --reduce-harness  The same, forced by the harness (`--ez page_reduce true`), leaving the emulator's settings alone.
#
# ANDROID_SERIAL, when set, names the emulator to use (it must be an emulator-* serial) instead of the first running one.
#
# out-dir defaults to android/build/motion (gitignored). Frames go to <out-dir>/frames, sheets to
# <out-dir>/<motion>.png. In-memory fixtures only: no keystore, network or push. Emulator only: this script talks to
# emulator-* serials and never to a physical device, and stops the emulator at the end only if it started it.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
android="$(cd "$here/.." && pwd)"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
adb="$ANDROID_HOME/platform-tools/adb"
emulator="$ANDROID_HOME/emulator/emulator"
pkg="app.page.android.debug"

out=""
build=1
canvas=0
noblur=0
reduce=0
reduce_harness=0
avd="PageParity"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) build=0 ;;
    --canvas) canvas=1 ;;
    --noblur) noblur=1 ;;
    --reduce) reduce=1 ;;
    --reduce-harness) reduce_harness=1 ;;
    --avd) avd="$2"; shift ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) out="$1" ;;
  esac
  shift
done
out="${out:-$android/build/motion}"
mkdir -p "$out/frames"

# 1. The emulator: ANDROID_SERIAL when set, else the headless "PageParity" on port 5560, booted read-only when it isn't
# running. Never any other emulator: emulator-5554 is the PagePixel window someone may be looking at, and a script that
# picked "the first emulator running" used to render on it, or boot PagePixel itself and then kill it.
started=0
serial="${ANDROID_SERIAL:-emulator-5560}"
[[ "$serial" == emulator-* ]] || { echo "ANDROID_SERIAL must name an emulator" >&2; exit 2; }
[ "$serial" != emulator-5554 ] || { echo "emulator-5554 is the PagePixel window; render on a headless emulator" >&2; exit 2; }
if ! "$adb" devices | grep -q "^$serial[[:space:]]*device$"; then
  "$emulator" -avd "$avd" -read-only -port "${serial#emulator-}" -no-window -no-audio -no-snapshot -no-boot-anim -gpu swiftshader_indirect >/dev/null 2>&1 &
  started=1
  for _ in $(seq 1 90); do
    "$adb" devices | grep -q "^$serial[[:space:]]*device$" && break
    sleep 2
  done
  "$adb" devices | grep -q "^$serial[[:space:]]*device$" || { echo "the emulator did not come up" >&2; exit 1; }
fi
export ANDROID_SERIAL="$serial"
for _ in $(seq 1 120); do
  [ "$("$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break
  sleep 2
done

old_anim=""
cleanup() {
  if [ -n "$old_anim" ]; then "$adb" shell settings put global animator_duration_scale "$old_anim" >/dev/null 2>&1 || true; fi
  if [ "$started" = 1 ]; then "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# 2. Build and install.
if [ "$build" = 1 ]; then
  (cd "$android" && ./gradlew --offline -q assembleDebug) || { echo "gradle assembleDebug failed" >&2; exit 1; }
  "$adb" install -r "$android/app/build/outputs/apk/debug/app-debug.apk" >/dev/null
fi

# 3. Remove animations, when asked.
if [ "$reduce" = 1 ]; then
  old_anim="$("$adb" shell settings get global animator_duration_scale | tr -d '\r')"
  [ "$old_anim" = null ] && old_anim=1.0
  "$adb" shell settings put global animator_duration_scale 0
fi

# screen@seconds for every frame of every sheet (the board's moments, plus a few between): iOS's list.
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
  motion-inflight-enter@0.1 motion-inflight-enter@0.35 motion-inflight-enter@0.7 motion-inflight-enter@1.4 motion-inflight-enter@3.0
  motion-inflight-advance@1.4 motion-inflight-advance@2.2 motion-inflight-advance@2.5 motion-inflight-advance@3.6
  motion-inflight-complete@1.4 motion-inflight-complete@2.2 motion-inflight-complete@2.5 motion-inflight-complete@3.6 motion-inflight-complete@4.5
  motion-inflight-vanish@1.4 motion-inflight-vanish@2.2 motion-inflight-vanish@3.6
  motion-inflight-stuck@1.4 motion-inflight-stuck@3.0
)
# The rest of Now: every shared moment of each motion-now-* screen.
for now_screen in motion-now-enter motion-now-enter-review motion-now-change motion-now-change-settled motion-now-quiet; do
  for t in 0.0 0.1 0.2 0.35 0.5 0.7 1.0 1.4 2.0 2.2 2.5 3.0 3.6 4.5; do frames+=("$now_screen@$t"); done
done
failed=0
for f in "${frames[@]}"; do
  # ONLY=<regex> re-captures just the matching frames.
  if [ -n "${ONLY:-}" ] && ! [[ "$f" =~ $ONLY ]]; then continue; fi
  screen="${f%@*}"; t="${f#*@}"
  "$adb" shell am force-stop "$pkg" >/dev/null
  "$adb" shell am start -S -W -n "$pkg/app.page.android.MainActivity" --ez page_demo true --es page_render "$screen" \
    --es page_glow off --ef page_time "$t" --ez page_canvas "$([ "$canvas" = 1 ] && echo true || echo false)" \
    --ez page_noblur "$([ "$noblur" = 1 ] && echo true || echo false)" --ez page_reduce "$([ "$reduce_harness" = 1 ] && echo true || echo false)" >/dev/null
  sleep 2.5
  top="$("$adb" shell dumpsys activity activities | grep -m1 topResumedActivity || true)"
  if [[ "$top" != *"$pkg/"* ]]; then
    echo "WARN  $f: Page is not in front (crash? see adb logcat); skipped" >&2
    failed=$((failed + 1))
    continue
  fi
  "$adb" exec-out screencap -p > "$out/frames/$f.png"
  echo "captured $f"
done
"$adb" shell am force-stop "$pkg" >/dev/null

python3 -I "$here/motion-sheets.py" "$out"
[ "$failed" = 0 ] || { echo "$failed frame(s) did not render" >&2; exit 1; }
