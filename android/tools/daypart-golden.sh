#!/usr/bin/env bash
# Regenerates app/src/test/resources/daypart-golden.tsv, the time-of-day sky
# table, from the iOS model (iOS/Page/Models/Daypart.swift, the source of
# truth) through tools/daypart-golden/driver.swift. The Kotlin test and the iOS
# logic tests both read it, so a table edit that is not regenerated fails on
# both platforms: weights within 0.0001, colours within one level a channel.
# Build output goes to a temp dir; nothing is written outside android/.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
dest="${1:-$here/../app/src/test/resources/daypart-golden.tsv}"

# Top-level code must live in a file called main.swift.
cp "$here/daypart-golden/driver.swift" "$out/main.swift"
swiftc -swift-version 5 -O -o "$out/golden" \
  "$root/iOS/Page/Models/MotionCurves.swift" "$root/iOS/Page/Models/Daypart.swift" "$out/main.swift"
mkdir -p "$(dirname "$dest")"
"$out/golden" > "$dest"
echo "wrote $(wc -l < "$dest") rows to $dest"
