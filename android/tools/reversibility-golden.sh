#!/usr/bin/env bash
# Regenerates app/src/test/resources/reversibility-golden.tsv by running the iOS
# classifier (iOS/Page/Models/Reversibility.swift, the source of truth) over:
#   - every row of `rvTable` and the hook-text sweep in iOS/Tests/LogicTests.swift
#     (spliced in verbatim, so they cannot drift),
#   - hand-picked entry points, a deterministic fuzz corpus and tool/path rows
#     (tools/reversibility-golden/driver.swift).
# The Kotlin test requires an exact match on every row (level, tags, reason).
# Build output goes to a temp dir; nothing is written outside android/.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
tests="$root/iOS/Tests/LogicTests.swift"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
dest="${1:-$here/../app/src/test/resources/reversibility-golden.tsv}"

# The table: from `let rvTable` up to (not including) `for (ctx, want) in rvTable`.
awk '/let rvTable: \[\(String, Reversibility\)\] = \[/{p=1} /for \(ctx, want\) in rvTable/{p=0} p' "$tests" > "$out/rvtable.swift"
# The hook sweep: from `let hookCommands` through the closing of the nested loops.
awk '/let hookCommands = /{p=1} p{print} p&&/^    \} \} \} \}$/{exit}' "$tests" > "$out/hooks.swift"
test -s "$out/rvtable.swift" && test -s "$out/hooks.swift"

python3 -I - "$here/reversibility-golden/driver.swift" "$out" <<'PY'
import sys
drv, out = sys.argv[1], sys.argv[2]
s = open(drv).read()
s = s.replace("//@@RVTABLE@@", open(out + "/rvtable.swift").read()).replace("//@@HOOKS@@", open(out + "/hooks.swift").read())
open(out + "/main.swift", "w").write(s)
PY

swiftc -swift-version 5 -O -o "$out/golden" "$root/iOS/Page/Models/Reversibility.swift" "$out/main.swift"
mkdir -p "$(dirname "$dest")"
"$out/golden" > "$dest"
echo "wrote $(wc -l < "$dest") rows to $dest"
