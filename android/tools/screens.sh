#!/usr/bin/env bash
# Builds the Page Android debug app, installs it on the "PagePixel" emulator (booting it headless first when none
# is running) and screenshots every Night Watch fixture screen of the debug render harness into a directory.
#
#   android/tools/screens.sh [out-dir] [options] [-- screen ...]
#
#   --glow off|subtle|full   Card glow to render with; repeatable (default: off). With more than one, each
#                            screen is captured once per glow and the file name carries the glow.
#   --font-scale 1.3         The system font scale to render at (restored afterwards). Default: leave as is.
#   --time 2.0               The aurora phase the harness pins, in seconds (default 2.0).
#   --no-build               Skip the Gradle build and install; reuse what is on the emulator.
#   --avd NAME               The emulator to boot (default PageParity, headless, port 5560).
#
# out-dir defaults to android/build/screens (gitignored). Screens default to the one list in
# app/src/debug/java/app/page/android/demo/Demo.kt (`val screens`), parsed here with `python3 -I`, so the script
# and the app can never disagree. The harness (`--es page_render <screen> --es page_glow <glow>`) seeds in-memory
# fixtures only: no keystore, network or push, and it never writes the Card glow setting.
#
# Emulator only. This script talks to emulator-* serials and never to a physical device. It stops the emulator at
# the end only if it started it.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
android="$(cd "$here/.." && pwd)"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
adb="$ANDROID_HOME/platform-tools/adb"
emulator="$ANDROID_HOME/emulator/emulator"
pkg="app.page.android.debug"
default_out="$android/build/screens"

out=""
glows=()
screens=()
font_scale=""
phase="2.0"
build=1
avd="PageParity"
mode=opts
while [ $# -gt 0 ]; do
  case "$1" in
    --) mode=screen ;;
    --glow) glows+=("$2"); shift ;;
    --font-scale) font_scale="$2"; shift ;;
    --time) phase="$2"; shift ;;
    --no-build) build=0 ;;
    --avd) avd="$2"; shift ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) if [ "$mode" = screen ]; then screens+=("$1"); elif [ -z "$out" ]; then out="$1"; else screens+=("$1"); fi ;;
  esac
  shift
done
out="${out:-$default_out}"
[ ${#glows[@]} -gt 0 ] || glows=(off)
mkdir -p "$out"

if [ ${#screens[@]} -eq 0 ]; then
  # One list: Demo.screens in the debug source set.
  while IFS= read -r name; do screens+=("$name"); done < <(python3 -I - "$android/app/src/debug/java/app/page/android/demo/Demo.kt" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
block = src[src.index("val screens = listOf("):]
block = block[:block.index("\n    )")]
for name in re.findall(r'"([a-z0-9-]+)"', block):
    print(name)
PY
)
fi

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

old_scale=""
cleanup() {
  [ -n "$old_scale" ] && "$adb" shell settings put system font_scale "$old_scale" >/dev/null 2>&1 || true
  if [ "$started" = 1 ]; then "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# 2. Build and install.
if [ "$build" = 1 ]; then
  (cd "$android" && ./gradlew --offline -q assembleDebug) || { echo "gradle assembleDebug failed" >&2; exit 1; }
  "$adb" install -r "$android/app/build/outputs/apk/debug/app-debug.apk" >/dev/null
fi
"$adb" shell pm grant "$pkg" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true

# 3. Font scale.
if [ -n "$font_scale" ]; then
  old_scale="$("$adb" shell settings get system font_scale | tr -d '\r')"
  [ "$old_scale" = null ] && old_scale=1.0
  "$adb" shell settings put system font_scale "$font_scale"
fi

failed=0
# 4. One cold start per screen, so the aurora frame and every fixture repeat.
for glow in "${glows[@]}"; do
  for s in "${screens[@]}"; do
    name="$s"
    [ ${#glows[@]} -gt 1 ] && name="$s-$glow"
    [ -n "$font_scale" ] && name="$name@${font_scale}x"
    "$adb" shell am force-stop "$pkg" >/dev/null
    "$adb" shell am start -S -W -n "$pkg/app.page.android.MainActivity" --ez page_demo true --es page_render "$s" --es page_glow "$glow" --ef page_time "$phase" >/dev/null
    sleep 2.5
    # A crashed screen leaves the launcher or another app in front: never save that under the screen's name.
    top="$("$adb" shell dumpsys activity activities | grep -m1 topResumedActivity || true)"
    if [[ "$top" != *"$pkg/"* ]]; then
      echo "WARN  $name: Page is not in front (crash? see adb logcat); skipped" >&2
      failed=$((failed + 1))
      continue
    fi
    "$adb" exec-out screencap -p > "$out/$name.png"
    echo "$out/$name.png"
  done
done
"$adb" shell am force-stop "$pkg" >/dev/null
[ "$failed" = 0 ] || { echo "$failed screen(s) did not render" >&2; exit 1; }
