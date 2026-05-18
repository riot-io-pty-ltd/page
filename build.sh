#!/bin/bash
# Builds ClaudePowerMode and wraps it as a macOS .app bundle.
# Requires Xcode Command Line Tools (swift, iconutil). Install with:
#   xcode-select --install
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

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BUNDLE_NAME"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

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
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
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
# `CODESIGN_IDENTITY` env var lets the caller override (e.g. CI). When
# unset, we pick the first valid code-signing identity. Falls back to
# ad-hoc only if no signing identity exists at all.
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning | awk '/^[[:space:]]+[0-9]+\)/ { gsub(/"/,"",$3); print $2; exit }')"
fi
ENTITLEMENTS="Resources/Page.entitlements"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "==> Signing with identity: $CODESIGN_IDENTITY"
    codesign --force --deep --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$CODESIGN_IDENTITY" "$APP"
else
    echo "==> No code-signing identity found — falling back to ad-hoc (TCC grants will not persist across rebuilds)"
    codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP" >/dev/null 2>&1 || true
fi

# Tell Finder/Dock to refresh icon caches for this bundle.
touch "$APP"

echo "==> Built $APP"
echo "    Run with:           open ./$APP"
echo "    Install permanently: ./install.sh"
