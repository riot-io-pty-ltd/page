#!/bin/bash
# Installs (or uninstalls) Page to /Applications and registers a LaunchAgent
# so it starts at every login.
#
# Usage:
#   ./install.sh                  # build, install, (re)launch — never uses sudo
#   ./install.sh --install-hook   # copy the Claude Code hook into ~/.claude/hooks
#                                 #   and print the settings.json snippet to add
#                                 #   (easier: Page > Integrations > Install agent hooks…)
#   ./install.sh --enable-power-helpers
#                                 # add a narrow sudoers rule so Page can (a) schedule
#                                 #   a system wake before a rate limit resets and
#                                 #   (b) keep working with the lid closed on battery
#                                 #   (pmset disablesleep 0/1; opt-in in Preferences) (sudo)
#   ./install.sh --disable-power-helpers
#                                 # remove that sudoers rule (sudo); stops Page
#                                 #   meanwhile and restarts it afterwards
#   ./install.sh --uninstall      # remove app, LaunchAgents, scheduled resumes and,
#                                 #   if present, the sudoers rule (sudo only then).
#                                 #   Stops first if Page's phone-approval hooks are
#                                 #   still in ~/.claude/settings.json or
#                                 #   ~/.codex/hooks.json (add --force to go ahead)
#
#   --enable-wake / --disable-wake are older names for the two helper options.
#
# Only --enable-power-helpers, --disable-power-helpers and --uninstall (when
# the rule exists) ask for an admin password; a plain install never does.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="local.Page"
APP_SRC="Page.app"
APP_DEST="/Applications/Page.app"
BUNDLE_NAME="Page"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
# Name kept from the ClaudePowerMode era so existing installs are found.
SUDOERS_FILE="/etc/sudoers.d/claude-power-mode"
UID_NUM="$(id -u)"
USER_NAME="$(id -un)"
HOOKS_DIR="$HOME/.claude/hooks"
SUPPORT_DIR="$HOME/Library/Application Support/ClaudePowerMode"
# Lid-closed-on-battery: the app writes this marker before `pmset
# disablesleep 1` and removes it after `disablesleep 0` succeeded, and runs a
# watchdog LaunchAgent that clears the flag if Page dies.
SLEEP_MARKER="$SUPPORT_DIR/disablesleep.active"
SLEEPGUARD_LABEL="local.Page.sleepguard"
SLEEPGUARD_PLIST="$HOME/Library/LaunchAgents/$SLEEPGUARD_LABEL.plist"
SLEEPGUARD_SCRIPT="$SUPPORT_DIR/sleepguard.sh"
RESUME_LABEL_PREFIXES=("local.ClaudePowerMode.resume." "local.Page.resume." "local.PageAI.resume.")
SCHEDULED_DIR="$HOME/Library/Application Support/ClaudePowerMode/scheduled"

# Legacy install paths. The app was originally called ClaudePowerMode and
# briefly PageAI before settling on Page. We clean both up so an old menu
# bar process doesn't fight for the slot.
LEGACY_LABELS=("local.ClaudePowerMode" "local.PageAI")
LEGACY_APPS=("/Applications/ClaudePowerMode.app" "/Applications/PageAI.app")
LEGACY_BUNDLES=("ClaudePowerMode" "PageAI")

# rm -rf only ever on an absolute *.app path we own; a typo or empty
# variable must never turn into `rm -rf /` or `rm -rf ~`.
safe_rm_app() {
    local target="${1:?safe_rm_app needs a path}"
    case "$target" in
        /Applications/*.app|"$PWD"/*.app) ;;
        *) echo "!! Refusing to delete unexpected path: $target" >&2; exit 1 ;;
    esac
    [[ -L "$target" ]] && { rm -f "$target"; return; }
    [[ -d "$target" ]] && rm -rf "$target"
    return 0
}

# Unload a LaunchAgent and wait until launchd has really let go of it, so an
# immediate bootstrap doesn't fail with "service already loaded".
unload_agent() {
    local label="$1"
    launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "gui/$UID_NUM/$label" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    echo "!! $label is still loaded after bootout; continuing anyway" >&2
}

cleanup_legacy() {
    for i in "${!LEGACY_LABELS[@]}"; do
        local lbl="${LEGACY_LABELS[$i]}"
        local app="${LEGACY_APPS[$i]}"
        local bundle="${LEGACY_BUNDLES[$i]}"
        local plist="$HOME/Library/LaunchAgents/$lbl.plist"
        if launchctl print "gui/$UID_NUM/$lbl" >/dev/null 2>&1; then
            echo "==> Stopping legacy $bundle LaunchAgent"
            unload_agent "$lbl"
        fi
        pkill -f "$bundle.app/Contents/MacOS/$bundle" 2>/dev/null || true
        if [[ -f "$plist" ]]; then
            echo "==> Removing legacy LaunchAgent plist ($lbl)"
            rm -f "$plist"
        fi
        if [[ -e "$app" ]]; then
            echo "==> Removing legacy $app"
            safe_rm_app "$app"
        fi
    done
}

# The sudoers rule permits exactly the commands the app runs:
# - the two wake commands, each with exactly one "MM/dd/yyyy HH:mm:ss"
#   argument (ResumeScheduler formats it with en_US_POSIX, so it's always
#   ASCII digits). No trailing wildcard: `*` in sudoers matches spaces too,
#   which would allow arbitrary extra arguments;
# - `pmset -a disablesleep 0` and `pmset -a disablesleep 1`, spelled out in
#   full (a command with arguments in sudoers matches only those arguments).
STAMP_PATTERN='[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9] [0-9][0-9]\:[0-9][0-9]\:[0-9][0-9]'

enable_power_helpers() {
    echo "==> Installing a narrow sudoers rule at $SUDOERS_FILE"
    echo "    It lets $USER_NAME run, without a password, only:"
    echo "      /usr/bin/pmset schedule wake \"MM/dd/yyyy HH:mm:ss\""
    echo "      /usr/bin/pmset schedule cancel wake \"MM/dd/yyyy HH:mm:ss\""
    echo "      /usr/bin/pmset -a disablesleep 0"
    echo "      /usr/bin/pmset -a disablesleep 1"
    echo "    You'll be prompted for your admin password once."
    # Global (not local) so the EXIT trap can still see it; the script exits
    # right after this function either way.
    WAKE_TMP="$(mktemp -t page-sudoers)"
    trap 'rm -f "$WAKE_TMP"' EXIT
    local tmp="$WAKE_TMP"
    cat > "$tmp" <<EOF
# Generated by Page install.sh (--enable-power-helpers). Remove with
# --disable-power-helpers.
# Lets Page wake the Mac shortly before a Claude rate limit resets.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake $STAMP_PATTERN
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset schedule cancel wake $STAMP_PATTERN
# Lets Page keep agents running with the lid closed on battery (opt-in in
# Preferences > Power). Exactly these two commands, no other arguments.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
EOF
    # Validate before installing: a broken sudoers fragment can lock sudo out.
    if ! visudo -c -q -f "$tmp" >/dev/null 2>&1; then
        echo "!! Sudoers fragment failed validation (visudo -c). Nothing was installed." >&2
        exit 1
    fi
    sudo install -m 0440 -o root -g wheel "$tmp" "$SUDOERS_FILE"
    if ! sudo visudo -c -q >/dev/null 2>&1; then
        echo "!! sudoers no longer validates; removing $SUDOERS_FILE" >&2
        sudo rm -f "$SUDOERS_FILE"
        exit 1
    fi
    local stamp
    stamp="$(LC_ALL=C date -v+5M '+%m/%d/%Y %H:%M:%S')"
    echo "==> Power helpers enabled. To test:"
    echo "    sudo -n /usr/bin/pmset schedule wake \"$stamp\" && sudo -n /usr/bin/pmset schedule cancel wake \"$stamp\""
    echo "    sudo -n -l /usr/bin/pmset -a disablesleep 0   # prints the command if allowed"
    echo "    Lid-closed-on-battery is still off until you turn it on in Page's Preferences > Power."
}

# Never leave `pmset disablesleep 1` behind: if Page's marker says it may be
# on, clear it (while the sudoers rule still allows it without a password,
# falling back to a normal sudo prompt) and drop the marker.
clear_disablesleep() {
    [[ -f "$SLEEP_MARKER" ]] || return 0
    echo "==> Clearing pmset disablesleep left on by Page"
    if sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || sudo /usr/bin/pmset -a disablesleep 0; then
        rm -f "$SLEEP_MARKER"
    else
        echo "!! Couldn't clear it. Run: sudo pmset -a disablesleep 0" >&2
    fi
}

remove_sleepguard() {
    launchctl bootout "gui/$UID_NUM/$SLEEPGUARD_LABEL" 2>/dev/null || true
    if [[ -f "$SLEEPGUARD_PLIST" || -f "$SLEEPGUARD_SCRIPT" ]]; then
        echo "==> Removing the sleep watchdog ($SLEEPGUARD_LABEL)"
        rm -f "$SLEEPGUARD_PLIST" "$SLEEPGUARD_SCRIPT"
    fi
}

page_is_running() {
    launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 \
        || pgrep -f "$BUNDLE_NAME.app/Contents/MacOS/$BUNDLE_NAME" >/dev/null 2>&1
}

disable_power_helpers() {
    # Stop Page first. While it runs it can set `disablesleep 1` again
    # through the rule at any moment up to the rule's removal (e.g. while the
    # password prompt below is up), and after that nothing could clear it
    # without a password. SIGTERM lets Page clear the flag itself.
    local was_running=0
    if page_is_running; then
        was_running=1
        echo "==> Stopping Page while the rule is removed"
        unload_agent "$LABEL"
        pkill -f "$BUNDLE_NAME.app/Contents/MacOS/$BUNDLE_NAME" 2>/dev/null || true
        sleep 1
    fi
    # While the rule still allows it without a password.
    clear_disablesleep
    if [[ -f "$SUDOERS_FILE" ]]; then
        echo "==> Removing $SUDOERS_FILE (admin password required)"
        sudo rm -f "$SUDOERS_FILE"
        # From here on nothing can set the flag without a password. Clear it
        # once more, marker or not, in case anything set it before the rule
        # went (uses the credential the prompt above just cached).
        echo "==> Making sure pmset disablesleep is off"
        if sudo /usr/bin/pmset -a disablesleep 0; then
            rm -f "$SLEEP_MARKER"
        else
            echo "!! Couldn't clear it. Run: sudo pmset -a disablesleep 0" >&2
        fi
    fi
    remove_sleepguard
    if [[ "$was_running" == 1 && -f "$PLIST_PATH" ]]; then
        echo "==> Starting Page again"
        local started=0
        for _ in 1 2 3 4 5; do
            if launchctl bootstrap "gui/$UID_NUM" "$PLIST_PATH" 2>/dev/null; then started=1; break; fi
            sleep 1
        done
        [[ "$started" == 1 ]] || echo "!! Couldn't restart Page. Open $APP_DEST, or: launchctl bootstrap gui/$UID_NUM \"$PLIST_PATH\"" >&2
    elif [[ "$was_running" == 1 ]]; then
        echo "    Page was stopped; open $APP_DEST to start it again."
    fi
    echo "Power helpers disabled (scheduled wakes and lid-closed-on-battery won't work)."
    echo "Turn off Preferences > Power > \"keep working with the lid closed on battery\" in Page;"
    echo "until you do, Page reports the power helper as missing (and keeps its watchdog installed)."
}

install_hook() {
    local src
    for src in hooks/page-notify.sh hooks/page-extract-context.py; do
        [[ -f "$src" ]] || { echo "!! Missing $src (run from the repository root)" >&2; exit 1; }
    done
    mkdir -p "$HOOKS_DIR"
    install -m 0755 hooks/page-notify.sh "$HOOKS_DIR/page-notify.sh"
    install -m 0755 hooks/page-extract-context.py "$HOOKS_DIR/page-extract-context.py"
    echo "==> Installed the Page hook into $HOOKS_DIR"
    # The entries below mirror what Page's in-app installer writes
    # (HookInstaller.canonicalEntries). The blocking timeout must stay above
    # the hook's own wait (PAGE_HOOK_TIMEOUT, 540 s by default) so the hook
    # gives up cleanly instead of being killed: 570, as the app uses.
    cat <<'EOF'

    Easiest: Page > Integrations > Install agent hooks… installs (and can remove)
    these entries for Claude Code and Codex, shows the change first and backs
    up the file. It points them at the copy inside Page.app.

    This script does NOT edit ~/.claude/settings.json. To set it up by hand,
    merge this into the "hooks" object there:

      "hooks": {
        "PermissionRequest": [
          { "hooks": [ { "type": "command",
                         "command": "~/.claude/hooks/page-notify.sh",
                         "timeout": 570 } ] }
        ],
        "PreToolUse": [
          { "matcher": "AskUserQuestion|ExitPlanMode",
            "hooks": [ { "type": "command",
                         "command": "~/.claude/hooks/page-notify.sh",
                         "timeout": 570 } ] }
        ],
        "Notification": [
          { "hooks": [ { "type": "command",
                         "command": "~/.claude/hooks/page-notify.sh",
                         "timeout": 30 } ] }
        ]
      }

    PermissionRequest and PreToolUse wait for your phone only when you're
    away from the Mac, and fall back to Claude's own prompt on any error or
    timeout. Notification only pages (it never blocks). Keep "timeout" above
    PAGE_HOOK_TIMEOUT (540 s by default) if you change either.

    Claude Code normally picks up settings changes by itself; if a running
    session doesn't, restart it.
EOF
}

# Page's in-app installer writes hook entries that run the script inside
# Page.app. Removing the app leaves them pointing at a missing file, so every
# permission prompt / question / notification logs a hook error. Prints the
# leftover entries; returns 0 when there are none.
check_leftover_hooks() {
    local script="$APP_DEST/Contents/Resources/hooks/page-notify.sh" f found=1
    # Also the JSON-escaped spelling ("\/"), in case another tool rewrote the file.
    local escaped="${script//\//\\/}"
    for f in "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json"; do
        [[ -f "$f" ]] || continue
        if grep -qF -e "$script" -e "$escaped" "$f" 2>/dev/null; then
            if [[ "$found" == 1 ]]; then
                echo "!! Page's phone-approval hooks are still installed and would point at a deleted script:" >&2
            fi
            found=0
            echo "   $f:" >&2
            grep -nF -e "$script" -e "$escaped" "$f" | sed 's/^/     /' >&2
        fi
    done
    [[ "$found" == 1 ]]
}

uninstall() {
    local force="${1:-}"
    if ! check_leftover_hooks; then
        echo "   Remove them first: Page > Integrations > Install agent hooks… > Uninstall (Claude Code and" >&2
        echo "   Codex; it removes only Page's entries and keeps a backup), then run --uninstall again." >&2
        if [[ "$force" == "--force" ]]; then
            echo "   --force: uninstalling anyway — delete the entries above by hand afterwards." >&2
        elif [[ -t 0 ]]; then
            local answer=""
            read -r -p "   Uninstall anyway and remove them by hand later? [y/N] " answer || true
            [[ "$answer" == [yY]* ]] || { echo "Nothing was changed." >&2; exit 1; }
        else
            echo "   Nothing was changed (pass --force to uninstall anyway)." >&2
            exit 1
        fi
    fi
    echo "==> Stopping running instance"
    # SIGTERM lets Page clear disablesleep itself; give it a moment.
    unload_agent "$LABEL"
    pkill -f "$BUNDLE_NAME.app/Contents/MacOS/$BUNDLE_NAME" 2>/dev/null || true
    sleep 1
    # Before the sudoers rule goes, so `sudo -n` can still clear the flag.
    clear_disablesleep
    remove_sleepguard
    # Scheduled resume jobs (current + legacy labels), loaded or not.
    local plist label prefix
    for prefix in "${RESUME_LABEL_PREFIXES[@]}"; do
        for plist in "$HOME/Library/LaunchAgents/$prefix"*.plist; do
            [[ -f "$plist" ]] || continue
            label="$(basename "$plist" .plist)"
            launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
            rm -f "$plist"
        done
        while read -r label; do
            [[ -n "$label" ]] && launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
        done < <(launchctl list 2>/dev/null | awk -v p="$prefix" 'index($3, p) == 1 { print $3 }')
    done
    if [[ -d "$SCHEDULED_DIR" ]]; then
        rm -f "$SCHEDULED_DIR"/*.json "$SCHEDULED_DIR"/*.sh
    fi
    if [[ -f "$PLIST_PATH" ]]; then
        echo "==> Removing $PLIST_PATH"
        rm -f "$PLIST_PATH"
    fi
    if [[ -e "$APP_DEST" ]]; then
        echo "==> Removing $APP_DEST"
        safe_rm_app "$APP_DEST"
    fi
    cleanup_legacy
    if [[ -f "$SUDOERS_FILE" ]]; then
        echo "==> Removing the power-helper sudoers rule (admin password required)"
        sudo rm -f "$SUDOERS_FILE"
    fi
    if [[ -f "$HOOKS_DIR/page-notify.sh" ]]; then
        echo "    Note: the hook copy in $HOOKS_DIR (from --install-hook) was left in place;"
        echo "    remove its entries from ~/.claude/settings.json (and ~/.codex/hooks.json)"
        echo "    and delete page-notify.sh / page-extract-context.py there if you no longer want it."
    fi
    echo "Uninstalled. Settings and logs remain in ~/Library/Application Support/ClaudePowerMode"
    echo "and ~/Library/Logs; delete them by hand for a clean slate."
}

case "${1:-}" in
    "") ;;
    --uninstall) uninstall "${2:-}"; exit 0 ;;
    --enable-power-helpers|--enable-wake) enable_power_helpers; exit 0 ;;
    --disable-power-helpers|--disable-wake) disable_power_helpers; exit 0 ;;
    --install-hook) install_hook; exit 0 ;;
    # The header comment block (line 2 up to the first non-comment line).
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
esac

echo "==> Building (always, to pick up any source changes)"
./build.sh

[[ -d "$APP_SRC" ]] || { echo "!! Build did not produce $APP_SRC" >&2; exit 1; }

cleanup_legacy

echo "==> Stopping any running Page instance"
unload_agent "$LABEL"
pkill -f "$BUNDLE_NAME.app/Contents/MacOS/$BUNDLE_NAME" 2>/dev/null || true
sleep 1

echo "==> Copying to $APP_DEST"
safe_rm_app "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"

# Strip the quarantine attribute that macOS adds to anything copied around,
# so Gatekeeper doesn't pop "are you sure" on first launch.
xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true

echo "==> Writing LaunchAgent at $PLIST_PATH"
mkdir -p "$(dirname "$PLIST_PATH")"
PLIST_TMP="$(mktemp -t page-launchagent)"
trap 'rm -f "$PLIST_TMP"' EXIT
cat > "$PLIST_TMP" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_DEST/Contents/MacOS/$BUNDLE_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/Page.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/Page.stderr.log</string>
</dict>
</plist>
PLIST
plutil -lint -s "$PLIST_TMP"
mv -f "$PLIST_TMP" "$PLIST_PATH"

echo "==> Loading LaunchAgent"
# Idempotent: unload_agent above waited for any previous instance to go away;
# retry briefly in case launchd is still tearing it down.
loaded=0
for _ in 1 2 3 4 5; do
    if launchctl bootstrap "gui/$UID_NUM" "$PLIST_PATH" 2>/dev/null; then loaded=1; break; fi
    sleep 1
done
if [[ "$loaded" != 1 ]]; then
    echo "!! launchctl bootstrap failed. Try: launchctl bootstrap gui/$UID_NUM \"$PLIST_PATH\"" >&2
    exit 1
fi

sleep 2

if pgrep -f "$BUNDLE_NAME.app/Contents/MacOS/$BUNDLE_NAME" >/dev/null; then
    echo "==> Running. Look for the icon in your menu bar (top right)."
    echo "    Remote paging from Claude Code hooks: ./install.sh --install-hook"
    echo "    To uninstall:  ./install.sh --uninstall"
else
    echo "!! App did not start. Check logs:" >&2
    echo "   tail $HOME/Library/Logs/Page.stderr.log" >&2
    exit 1
fi
