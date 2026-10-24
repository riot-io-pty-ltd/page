#!/usr/bin/env bash
# Compiles Page/Models/*.swift with the logic tests into a throwaway binary
# and runs it. Exits non-zero on any failure.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
# Top-level test code must live in a file called main.swift.
cp "$here/LogicTests.swift" "$out/main.swift"
swiftc -swift-version 5 -o "$out/page-logic-tests" "$here"/../Page/Models/*.swift "$out/main.swift"
"$out/page-logic-tests"
