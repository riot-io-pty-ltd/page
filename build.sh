#!/bin/bash
# Builds ClaudePowerMode and wraps it as a macOS .app bundle.
# Requires Xcode Command Line Tools (swift, iconutil). Install with:
#   xcode-select --install
#
# Env (all optional):
#   CONFIG=debug|release      swift build configuration (default release)
#   VERSION=1.2.3             CFBundleShortVersionString (default: latest
#                             vX.Y.Z git tag, else 1.0.0)
#   CODESIGN_IDENTITY=...     signing identity (name or SHA-1); default: first
#                             "Apple Development", else first "Developer ID
#                             Application", else ad-hoc
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="Page.app"
BUNDLE_NAME="Page"
BUNDLE_ID="local.Page"
DISPLAY_NAME="Page"
# Internal Swift target name stays `ClaudePowerMode` so we don't have to
# rename the source tree. The executable inside the .app bundle is renamed
# to match the bundle so Activity Monitor / `ps` show the user-visible name.
SWIFT_TARGET="ClaudePowerMode"
ICONSET="Resources/AppIcon.iconset"
ICNS="Resources/AppIcon.icns"

# Regenerate the icon if any source piece is newer than the .icns
if [[ ! -f "$ICNS" ]] || [[ "Tools/MakeIcon.swift" -nt "$ICNS" ]]; then
    echo "==> Regenerating app icon"
    swift Tools/MakeIcon.swift >/dev/null
    iconutil -c icns "$ICONSET" -o "$ICNS"
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$SWIFT_TARGET"

# Versioning: a marketing version (must be numeric dotted for macOS), a
# monotonically increasing build number, and the exact git revision for
# bug reports.
if [[ -z "${VERSION:-}" ]]; then
    VERSION="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)"
fi
VERSION="${VERSION:-1.0.0}"
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "!! VERSION must look like 1.2.3 (got '$VERSION')" >&2
    exit 1
fi
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
GIT_DESCRIBE="$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
echo "==> Version $VERSION (build $BUILD_NUMBER, $GIT_DESCRIBE)"

# Guarded delete: $APP is a fixed relative bundle name, never empty.
[[ "$APP" == *.app && "$APP" != /* ]] || { echo "!! Unexpected APP=$APP" >&2; exit 1; }
rm -rf "./$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BUNDLE_NAME"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Claude Code / Codex hook scripts. "Phone approvals…" in the app writes
# hook entries that point at these copies, so they ship inside the bundle.
# Explicit list (no __pycache__ / .DS_Store), executable, and copied before
# signing so the code signature seals them.
HOOK_FILES=(hooks/page-notify.sh hooks/page-extract-context.py)
mkdir -p "$APP/Contents/Resources/hooks"
for f in "${HOOK_FILES[@]}"; do
    [[ -f "$f" ]] || { echo "!! Missing $f" >&2; exit 1; }
    cp "$f" "$APP/Contents/Resources/hooks/"
    chmod 755 "$APP/Contents/Resources/hooks/$(basename "$f")"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$BUNDLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$BUNDLE_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>PageGitDescribe</key>
    <string>$GIT_DESCRIBE</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Page needs to control your Terminal to deliver replies from your phone into the active session.</string>
</dict>
</plist>
PLIST

# Sign with a stable identity. Ad-hoc (`--sign -`) gives a fresh code
# hash on every build, which invalidates any TCC permissions (Accessibility,
# Automation) the user has already granted. Picking an existing Apple
# Development identity from the user's keychain keeps the Designated
# Requirement stable across rebuilds so TCC grants persist.
#
# `CODESIGN_IDENTITY` lets the caller override (e.g. CI). Otherwise the
# choice is deterministic: the first valid "Apple Development" identity,
# else the first "Developer ID Application" one — never whatever happens to
# be listed first (that could be an employer's distribution certificate).
# Ad-hoc only when neither exists.
pick_identity() {
    local kind="$1"
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -v kind="$kind" -F'"' '$2 ~ "^" kind ": " { split($1, a, " "); print a[2] "\t" $2; exit }'
}
IDENTITY_NAME=""
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    for kind in "Apple Development" "Developer ID Application"; do
        picked="$(pick_identity "$kind")"
        if [[ -n "$picked" ]]; then
            CODESIGN_IDENTITY="${picked%%$'\t'*}"
            IDENTITY_NAME="${picked#*$'\t'}"
            break
        fi
    done
fi
ENTITLEMENTS="Resources/Page.entitlements"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "==> Signing with identity: ${IDENTITY_NAME:-$CODESIGN_IDENTITY} ($CODESIGN_IDENTITY)"
    codesign --force --deep --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$CODESIGN_IDENTITY" "$APP"
else
    echo "==> No Apple Development / Developer ID identity found — signing ad-hoc"
    echo "    (macOS will forget Automation/Accessibility grants after each rebuild)"
    codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi
codesign --verify --strict "$APP"

# Tell Finder/Dock to refresh icon caches for this bundle.
touch "$APP"

echo "==> Built $APP"
echo "    Run with:           open ./$APP"
echo "    Install permanently: ./install.sh"
