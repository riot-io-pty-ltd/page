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
#
# The bundle also carries Page's macOS widgets, as a WidgetKit extension at
# Contents/PlugIns/PageWidgets.appex (built by the PageWidgets SwiftPM target).
# It is sandboxed and shares one team-prefixed app group with the app, so it
# is only built when the signing identity has a team (not ad-hoc). The
# extension is signed first, then the app: inside out, no --deep.
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
ICON_CAR="Resources/Assets.car"

# Regenerate the icon if any source piece is newer than the .icns
if [[ ! -f "$ICNS" ]] || [[ "Tools/MakeIcon.swift" -nt "$ICNS" ]]; then
    echo "==> Regenerating app icon"
    swift Tools/MakeIcon.swift >/dev/null
    iconutil -c icns "$ICONSET" -o "$ICNS"
    # macOS 26 shows an .icns-only icon on a grey plate at small sizes; an
    # asset-catalog icon (CFBundleIconName) is drawn as is. actool needs full
    # Xcode — without it the committed Assets.car is kept.
    if xcrun --find actool >/dev/null 2>&1; then
        rm -rf .build/appicon && mkdir -p .build/appicon
        xcrun actool .build/AppIcon.xcassets --compile .build/appicon --platform macosx \
            --minimum-deployment-target 12.0 --app-icon AppIcon \
            --output-partial-info-plist .build/appicon/partial.plist >/dev/null
        cp .build/appicon/Assets.car "$ICON_CAR"
    fi
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN_PATH="$BIN_DIR/$SWIFT_TARGET"
WIDGET_BIN="$BIN_DIR/PageWidgets"
WIDGET_NAME="PageWidgets"
WIDGET_ID="local.Page.widgets"
# One group for the app and the extension: <team id>.app.page.shared. macOS
# accepts a team-prefixed group for a signed app without a provisioning profile.
GROUP_SUFFIX="app.page.shared"
URL_SCHEME="page-mac"

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
# The team id (the certificate's organizational unit) for an identity given
# as a name or SHA-1. Empty when it can't be found (ad-hoc, odd identities).
team_id_for() {
    local ident="$1" name
    name="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' -v id="$ident" 'index($0, id) { print $2; exit }' || true)"
    [[ -n "$name" ]] || return 0
    security find-certificate -c "$name" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
        | sed -n 's/^ *organizationalUnitName *= *//p' | head -1 || true
}
TEAM_ID=""
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    TEAM_ID="$(team_id_for "$CODESIGN_IDENTITY")"
fi
APP_GROUP=""
if [[ -n "$TEAM_ID" ]]; then
    APP_GROUP="$TEAM_ID.$GROUP_SUFFIX"
    echo "==> Widgets: app group $APP_GROUP"
else
    echo "==> Widgets: no signing team — building Page without its widgets"
fi

# Guarded delete: $APP is a fixed relative bundle name, never empty.
[[ "$APP" == *.app && "$APP" != /* ]] || { echo "!! Unexpected APP=$APP" >&2; exit 1; }
rm -rf "./$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BUNDLE_NAME"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
if [[ -f "$ICON_CAR" ]]; then cp "$ICON_CAR" "$APP/Contents/Resources/Assets.car"; fi

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

GROUP_INFO_KEY=""
if [[ -n "$APP_GROUP" ]]; then
    GROUP_INFO_KEY="    <key>PageAppGroup</key>
    <string>$APP_GROUP</string>"
fi

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
    <key>CFBundleIconName</key>
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
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>$BUNDLE_ID.links</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>$URL_SCHEME</string>
            </array>
        </dict>
    </array>
$GROUP_INFO_KEY
</dict>
</plist>
PLIST

ENTITLEMENTS="Resources/Page.entitlements"
WIDGET_ENTITLEMENTS="Resources/PageWidgets.entitlements"
ENT_TMP="$(mktemp -d -t page-entitlements)"
trap 'rm -rf "$ENT_TMP"' EXIT
# The entitlement files carry $(PAGE_TEAM_ID) where the team goes.
fill_entitlements() {
    sed "s/\$(PAGE_TEAM_ID)/$TEAM_ID/g" "$1" > "$2"
}

# The widget extension: Contents/PlugIns/PageWidgets.appex, an XPC bundle whose
# NSExtensionPointIdentifier is the WidgetKit one. Same version as the app.
if [[ -n "$APP_GROUP" ]]; then
    [[ -x "$WIDGET_BIN" ]] || { echo "!! $WIDGET_BIN was not built" >&2; exit 1; }
    APPEX="$APP/Contents/PlugIns/$WIDGET_NAME.appex"
    mkdir -p "$APPEX/Contents/MacOS"
    cp "$WIDGET_BIN" "$APPEX/Contents/MacOS/$WIDGET_NAME"
    cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$WIDGET_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$WIDGET_ID</string>
    <key>CFBundleName</key>
    <string>$BUNDLE_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
    <key>PageAppGroup</key>
    <string>$APP_GROUP</string>
</dict>
</plist>
PLIST
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "==> Signing with identity: ${IDENTITY_NAME:-$CODESIGN_IDENTITY} ($CODESIGN_IDENTITY)"
    if [[ -n "$APP_GROUP" ]]; then
        # Inside out: the extension (sandboxed, with the group) first, then the app.
        fill_entitlements "$WIDGET_ENTITLEMENTS" "$ENT_TMP/widgets.entitlements"
        codesign --force --options runtime \
            --entitlements "$ENT_TMP/widgets.entitlements" \
            --sign "$CODESIGN_IDENTITY" "$APP/Contents/PlugIns/$WIDGET_NAME.appex"
        fill_entitlements "$ENTITLEMENTS" "$ENT_TMP/app.entitlements"
    else
        # No team, no group: the app's entitlements without the group key.
        cp "$ENTITLEMENTS" "$ENT_TMP/app.entitlements"
        /usr/libexec/PlistBuddy -c "Delete :com.apple.security.application-groups" "$ENT_TMP/app.entitlements"
    fi
    codesign --force --options runtime \
        --entitlements "$ENT_TMP/app.entitlements" \
        --sign "$CODESIGN_IDENTITY" "$APP"
else
    echo "==> No Apple Development / Developer ID identity found — signing ad-hoc"
    echo "    (macOS will forget Automation/Accessibility grants after each rebuild; no widgets)"
    cp "$ENTITLEMENTS" "$ENT_TMP/app.entitlements"
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.application-groups" "$ENT_TMP/app.entitlements"
    codesign --force --entitlements "$ENT_TMP/app.entitlements" --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

# Tell Finder/Dock to refresh icon caches for this bundle.
touch "$APP"

echo "==> Built $APP"
echo "    Run with:           open ./$APP"
echo "    Install permanently: ./install.sh"
