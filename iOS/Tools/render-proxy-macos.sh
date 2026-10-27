#!/usr/bin/env bash
# macOS proxy renderer: draws the Night Watch fixture screens with AppKit when
# no iOS Simulator runtime is installed (see Tools/macos-proxy/main.swift).
# Not the app: use Tools/render-screens.sh for real simulator screenshots.
#   iOS/Tools/render-proxy-macos.sh <out-dir> [screen[@seconds][:glow] ...]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ios="$here/.."
out="${1:?usage: render-proxy-macos.sh <out-dir> [screen[:glow]...]}"
shift || true
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 5 -DDEBUG -o "$work/render-proxy" \
  "$ios"/Page/Models/*.swift \
  "$ios"/Page/Design/NightWatch/*.swift \
  "$ios/Page/Services/CardGlowStore.swift" \
  "$ios/Page/Services/AnswerDraftStore.swift" \
  "$ios/Page/Services/RenderHarnessAnswers.swift" \
  "$ios/Page/Services/RenderHarness.swift" \
  "$ios/Page/Services/RenderHarnessStage3.swift" \
  "$ios/Page/Services/RenderHarnessMotion.swift" \
  "$ios/Page/Services/RenderHarnessHistory.swift" \
  "$here/macos-proxy/main.swift" 2>&1 | grep -v "warning:" | grep -E "error" || true
"$work/render-proxy" "$out" "$@"
