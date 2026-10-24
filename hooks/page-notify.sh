#!/bin/bash
# Page — Claude Code and Codex hook
#
# One script for every hook event Page uses. The agent passes the event as
# JSON on stdin; the script branches on `hook_event_name`. Run it with
# `--codex` from ~/.codex/hooks.json (Codex sends a slightly different
# payload and its pages are tagged backend "codex").
#
# The easy way to install it is Page ▸ Integrations ▸ "Install agent hooks…",
# which shows the exact change to ~/.claude/settings.json and
# ~/.codex/hooks.json, backs the files up and can remove it again. The
# entries it writes are shown below for reference.
#
# AWAY-ONLY. Every blocking mode first checks whether you have touched this
# Mac (keyboard, mouse, trackpad) within PAGE_HOOK_ONLY_WHEN_AWAY seconds
# (default 120). If you have, it prints nothing and exits at once, so the
# normal dialog appears exactly as if the hook weren't installed. While it
# waits for your phone it keeps checking: touch the Mac and it stops waiting
# and hands back to the dialog.
#
# NEVER DECIDES ON ITS OWN. A decision is only ever printed for an explicit
# answer from your phone. Relay down, token missing, no answer in time, an
# answer that isn't a decision, anything unexpected: the hook prints nothing
# and the agent shows its own dialog.
#
# 1) PermissionRequest (Claude Code and Codex; blocking)
#    Fires only when the agent is about to ask you for permission. Pages
#    your phone and waits: Approve -> allow; Deny -> deny; a typed reply ->
#    deny with your text as the message, so the agent reads it and adjusts.
#
#      "PermissionRequest": [
#        { "hooks": [ { "type": "command",
#                       "command": "'/Applications/Page.app/Contents/Resources/hooks/page-notify.sh' --agent-timeout 570",
#                       "timeout": 570 } ] } ]
#
# 2) PreToolUse for AskUserQuestion and ExitPlanMode (Claude Code; blocking)
#    These two tools need an answer, not a permission, so they are handled
#    before they run: your reply picks an option (by number or label) and is
#    returned as the tool's `answers`; a plan is approved, or rejected with
#    your text as feedback. A reply that doesn't map to the options is
#    handed to Claude as text instead of guessing an answer.
#
#      "PreToolUse": [
#        { "matcher": "AskUserQuestion|ExitPlanMode",
#          "hooks": [ { "type": "command", "command": "'…/page-notify.sh' --agent-timeout 570",
#                       "timeout": 570 } ] } ]
#
#    Older manual installs that match other tools here (e.g. "Bash") keep
#    the previous behaviour: wait for the phone, and fall back to Claude's
#    own prompt ("ask") on any failure. PermissionRequest replaces that.
#
# 3) Notification (Claude Code; fire-and-forget)
#    Pages your phone when Claude says it needs you, then exits with no
#    output. The Page Mac app types your reply into the session. Stays quiet
#    while the Mac app's own detector is running (it pages these itself) and
#    while a blocking Page hook is already holding a request for the session.
#
#      "Notification": [ { "hooks": [ { "type": "command",
#                         "command": "…/page-notify.sh", "timeout": 30 } ] } ]
#
# 4) Stop (Codex, opt-in; blocking)
#    When Codex finishes a turn while you're away, pages your phone and
#    keeps the turn open: a typed reply becomes Codex's next prompt (Codex's
#    documented Stop "block" continuation). No reply, Deny, or you come back
#    to the Mac: Codex stops normally.
#
#      ~/.codex/hooks.json:
#      "Stop": [ { "hooks": [ { "type": "command",
#                  "command": "'…/page-notify.sh' --codex --agent-timeout 570", "timeout": 570 } ] } ]
#
#    Codex runs new or changed hooks only after you trust them: open Codex
#    and run /hooks once after installing.
#
# The agent kills a hook that reaches its "timeout" and discards anything it
# printed. The installer passes that timeout to the script as
# `--agent-timeout <seconds>` (570 when absent), and every wait ends at least
# 30 s before it — whatever PAGE_HOOK_TIMEOUT says — so the hook always gives
# up cleanly, and never tells the phone a decision was applied unless there
# is still time to print it.
#
# Steps aside (prints nothing, so the agent behaves as if the hook weren't
# installed) for: bypassPermissions and dontAsk permission modes, a
# non-interactive `claude -p/--print` run (nobody is at that session, and
# Claude denies what it can't ask; set PAGE_HOOK_PRINT=1 to page those
# anyway), and any run with PAGE_HOOK_SKIP=1 in its environment (for tools
# that start agents in the background and want them left alone).
#
# While a blocking mode waits it keeps a marker in
# ~/Library/Application Support/ClaudePowerMode/hook-holds/<session>.<pid>
# so the Mac app doesn't page the same prompt a second time.
#
# Relay: PAGE_RELAY_URL if set, else `relayURL` from the Page Mac app's
# config.json when its relay is enabled. Token: the Mac app's
# relay_token.txt. If no relay is configured the hook does nothing at all.
# Requires jq and curl (both ship with recent macOS); python3 is optional
# and only adds Claude transcript context.
#
# Env (all optional):
#   PAGE_RELAY_URL          Worker base URL, e.g. https://page-relay.you.workers.dev
#                           (wss://…/ws forms are accepted and normalised). Plain
#                           http:// is refused except for localhost / 127.0.0.1 /
#                           [::1] (same rule as the app): the URL carries the token.
#   PAGE_HOOK_ONLY_WHEN_AWAY  Seconds without keyboard/mouse input before a
#                           blocking mode pages (default 120). 0 = always page.
#   PAGE_HOOK_TIMEOUT       Blocking modes: seconds to wait for a reply before
#                           handing back to the dialog (default 540, range 5–3600,
#                           and never past the agent's timeout minus 30 s).
#   PAGE_HOOK_PRINT         "1" pages from non-interactive `claude -p` runs too.
#   PAGE_HOOK_SKIP          "1" makes the hook do nothing at all for that run.
#   PAGE_HOOK_AUTO          Legacy generic PreToolUse only: "allow", "deny" or "ask"
#                           skips the phone and returns that decision.
#   PAGE_CONTEXT_TOOL_OUTPUT  "1" includes short tool-output excerpts in the
#                           context sent to your phone (off by default: tool output
#                           is where secrets tend to live).
#   PAGE_HOOK_LOG           Log file (default ~/Library/Logs/page-hook.log). The
#                           token is never logged.
#
# Notes: written for macOS /bin/bash 3.2 (no associative arrays, no ${x,,},
# no process substitution so `sh page-notify.sh` works too). Every path exits
# 0: exit 2 means "block" on several events and must only ever come from an
# explicit decision.

set -uo pipefail
umask 077

# Desktop-app and IDE sessions can start hooks with a minimal PATH: make
# sure the system tools (ioreg lives in /usr/sbin) and the usual Homebrew
# locations (jq on older macOS) are reachable.
PATH="${PATH:+$PATH:}/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
export PATH

APP_SUPPORT="$HOME/Library/Application Support/ClaudePowerMode"
CONFIG_FILE="$APP_SUPPORT/config.json"
TOKEN_FILE="$APP_SUPPORT/relay_token.txt"
DETECTOR_MARKER="$APP_SUPPORT/detector.alive"
# Written by the Page Mac app (unix seconds, one line) right before and
# after each synthetic keystroke it posts, so its own Return isn't taken for
# the user coming back (see synthetic_input_explains_idle).
SYNTHETIC_INPUT_MARKER="$APP_SUPPORT/synthetic-input"
SYNTHETIC_INPUT_TOLERANCE=3
HOLD_DIR="$APP_SUPPORT/hook-holds"
CLAUDE_SESSIONS_DIR="$HOME/.claude/sessions"
# The Mac app touches the marker every scan tick (seconds); 90s of silence
# means it has quit, crashed, or had detection/relay switched off.
DETECTOR_FRESH_SECONDS=90
# Hold markers are touched every poll (~2s, plus up to 5s for a slow poll).
HOLD_FRESH_SECONDS=20
POLL_INTERVAL=2
# Consecutive failed polls before we stop waiting and hand back to the agent.
MAX_POLL_FAILURES=10
CONTEXT_MAX_CHARS=3500
DEFAULT_AWAY_SECONDS=120
DEFAULT_TIMEOUT=540
# The agent's own hook timeout (what Page's installer writes) when the
# command line doesn't say, and how long before it every wait must end.
DEFAULT_AGENT_TIMEOUT=570
AGENT_TIMEOUT_SAFETY=30
# Seconds a settle (report + close) and the printed decision need: a reply
# seen later than this before the agent's timeout is not applied.
SETTLE_RESERVE=12
USER_AGENT="page-hook/3.0"
START_TS=$(date +%s)

LOG_FILE="${PAGE_HOOK_LOG:-$HOME/Library/Logs/page-hook.log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

AGENT="claude"
AGENT_TIMEOUT=$DEFAULT_AGENT_TIMEOUT
while [ $# -gt 0 ]; do
    case "$1" in
        --codex)            AGENT="codex" ;;
        --agent)            [ "${2:-}" = "codex" ] && AGENT="codex"; [ $# -gt 1 ] && shift ;;
        --agent=codex)      AGENT="codex" ;;
        --agent-timeout)    AGENT_TIMEOUT="${2:-}"; [ $# -gt 1 ] && shift ;;
        --agent-timeout=*)  AGENT_TIMEOUT="${1#--agent-timeout=}" ;;
    esac
    shift
done
case "$AGENT_TIMEOUT" in
    ''|*[!0-9]*) AGENT_TIMEOUT=$DEFAULT_AGENT_TIMEOUT ;;
esac
[ "${#AGENT_TIMEOUT}" -le 6 ] || AGENT_TIMEOUT=$DEFAULT_AGENT_TIMEOUT

EVENT_JSON=""
EVENT_NAME=""
SESSION_ID=""
RELAY_URL=""
TOKEN=""
WORK_DIR=""
IV_ID=""
# 1 while an intervention we opened is still pending on the relay; the EXIT
# trap closes it so a killed hook never leaves a stale page on the phone.
IV_OPEN=0
# How a blocking wait gives up: "quiet" prints nothing (the agent shows its
# own dialog); "ask" is the legacy generic-PreToolUse behaviour.
FAIL_MODE="quiet"
HOLD_FILE=""
TIMEOUT=$DEFAULT_TIMEOUT
# Set by wait_for_reply.
REPLY_ACTION=""
REPLY_TEXT=""
# Claude session status tracking (resolved-elsewhere detection).
SESSION_FILE=""
SESSION_PID=""
SAW_WAITING=0
WAITING_SINCE=""
# The agent process this hook answers to (see find_agent_pid).
AGENT_PID=""
AGENT_PID_IS_PARENT=0

agent_label() {
    if [ "$AGENT" = "codex" ]; then printf 'Codex'; else printf 'Claude'; fi
}

# ---------------------------------------------------------------------------
# Logging

log() {
    {
        mkdir -p "$(dirname "$LOG_FILE")" &&
        printf '[%s] [pid=%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$$" "$*" >> "$LOG_FILE"
    } 2>/dev/null
    return 0
}

rotate_log() {
    local size
    [ -f "$LOG_FILE" ] || return 0
    size=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$size" ] && [ "$size" -gt 1048576 ] 2>/dev/null; then
        mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Exit paths. Everything funnels through `exit 0`, and the EXIT trap tidies up.

on_exit() {
    hold_end
    if [ "$IV_OPEN" = "1" ] && [ -n "$IV_ID" ]; then
        log "closing $IV_ID on exit"
        close_intervention hook_exited
    fi
    if [ -n "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR" 2>/dev/null
    fi
    exit 0
}

on_signal() {
    log "received $1 — giving up"
    trap - INT TERM HUP
    # The agent has stopped listening (it killed us at its own timeout, or
    # the user hit Ctrl-C), so print nothing; the EXIT trap closes the page.
    exit 0
}

trap on_exit EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

# Nothing to say: the agent continues with its normal flow (for blocking
# events that means its own dialog).
quiet_exit() {
    [ -n "${1:-}" ] && log "$1"
    exit 0
}

# Stops waiting and hands back to the agent's own dialog. Closes our page
# (never as "replied": the Worker reads that as "decision applied").
fall_back() {
    local why="$1" close_reason="${2:-hook_fallback}"
    log "FALLBACK ($why) — no decision printed"
    if [ "$FAIL_MODE" = "ask" ]; then
        close_intervention "$close_reason"
        decide_pretool_legacy "ask" "Page: $why — answer here instead."
    fi
    close_intervention "$close_reason"
    exit 0
}

# Prints one JSON object (the agent reads stdout only if it's exactly one
# object) and exits. If jq somehow fails, nothing is printed, which is the
# safe fallback for every event.
emit() {
    local json="$1"
    [ -n "$json" ] && printf '%s\n' "$json"
    exit 0
}

# PermissionRequest decision (identical shape for Claude Code and Codex).
# Only `behavior` and, for deny, `message`: Codex fails closed on
# updatedInput / updatedPermissions / interrupt.
decide_permission() {
    local behavior="$1" message="${2:-}"
    log "DECIDE PermissionRequest behavior=$behavior"
    if [ "$behavior" = "deny" ]; then
        emit "$(jq -nc --arg m "$message" \
            '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "deny", message: $m}}}' 2>/dev/null)"
    fi
    emit "$(jq -nc '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow"}}}' 2>/dev/null)"
}

# PreToolUse allow with a full replacement input (AskUserQuestion answers,
# ExitPlanMode echo). UPDATED is a JSON object.
decide_pretool_allow_with_input() {
    local reason="$1" updated="$2"
    log "DECIDE PreToolUse allow+updatedInput"
    emit "$(jq -nc --arg r "$reason" --argjson u "$updated" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow",
          permissionDecisionReason: $r, updatedInput: $u}}' 2>/dev/null)"
}

decide_pretool_deny() {
    local reason="$1"
    log "DECIDE PreToolUse deny"
    emit "$(jq -nc --arg r "$reason" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' 2>/dev/null)"
}

# Legacy generic PreToolUse: allow / deny / ask with a reason.
decide_pretool_legacy() {
    local action="$1" reason="$2"
    log "DECIDE PreToolUse action=$action"
    emit "$(jq -nc --arg action "$action" --arg reason "$reason" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $action, permissionDecisionReason: $reason}}' \
        2>/dev/null)"
}

# Codex Stop continuation: the reason becomes Codex's next user prompt.
decide_stop_continue() {
    local prompt="$1"
    log "DECIDE Stop block (continue with ${#prompt}B prompt)"
    emit "$(jq -nc --arg r "$prompt" '{decision: "block", reason: $r}' 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# Relay plumbing

# Strips scheme/path variants down to the HTTP base URL the Worker serves:
# wss://x/ws -> https://x, ws://x/ws/ -> http://x, trailing slash removed.
normalise_relay_url() {
    printf '%s' "$1" | tr -d '[:space:]' |
        sed -E 's#^wss://#https://#; s#^ws://#http://#; s#/ws/?$##; s#/+$##'
}

# Sets RELAY_URL, or leaves it empty when no relay is configured. An explicit
# PAGE_RELAY_URL wins; otherwise we follow the Mac app's config, including
# its relayEnabled switch (the user turned paging off -> so do we).
resolve_relay_url() {
    local raw=""
    if [ -n "${PAGE_RELAY_URL:-}" ]; then
        raw="$PAGE_RELAY_URL"
    elif [ -r "$CONFIG_FILE" ]; then
        raw=$(jq -r 'if (.relayEnabled == true) then (.relayURL // "") else "" end' "$CONFIG_FILE" 2>/dev/null)
    fi
    raw=$(normalise_relay_url "$raw")
    # The token rides on every request, so never send it unencrypted: plain
    # http only to this Mac (the app's Config.validatedRelayURL rule). The
    # host is anchored on ":", "/" or the end, so http://localhost.evil.com
    # is refused, and any "@" (user-info: http://localhost:x@evil.com would
    # connect to evil.com) disqualifies the URL.
    case "$raw" in
        *@*) raw="" ;;
        *your-page-relay*) raw="" ;;          # the shipped placeholder
        https://?*) ;;
        http://localhost|http://localhost[:/]*|http://127.0.0.1|http://127.0.0.1[:/]*|http://\[::1\]|http://\[::1\][:/]*) ;;
        http://*)
            log "relay URL uses plain http for a non-local host — refusing to send the token over it"
            raw=""
            ;;
        *) raw="" ;;
    esac
    case "$raw" in
        *[\"\\\ ]*) raw="" ;;                 # never let odd characters near curl
    esac
    RELAY_URL="$raw"
}

# Sets TOKEN from the Mac app's token file. The legacy Keychain item is not
# consulted: the app migrates it to the file on first launch, and a
# `security` lookup can pop a GUI access dialog that would hang this hook.
read_token() {
    TOKEN=""
    if [ -r "$TOKEN_FILE" ]; then
        TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE" 2>/dev/null)
    fi
    # The token is spliced into a curl config line below, so anything outside
    # the URL-safe set is treated as "no usable token" rather than escaped.
    case "$TOKEN" in
        *[!A-Za-z0-9._~+/=-]*) TOKEN="" ;;
    esac
}

# relay_request METHOD PATH MAX_TIME [extra curl args...]
# Prints the response body followed by a final line holding the HTTP status
# ("000" when the request never completed). The bearer token travels in a
# curl config read from stdin so it never appears in argv (`ps -axww` shows
# other users' command lines on macOS); printf is a builtin, so neither does
# the pipe's producer. -q (must come first) ignores the user's ~/.curlrc so
# its options can't change what we send or print.
relay_request() {
    local method="$1" path="$2" max_time="$3"
    shift 3
    printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
        curl -q --config - -sS -X "$method" \
            -H "User-Agent: $USER_AGENT" \
            --connect-timeout 3 --max-time "$max_time" \
            -w '\n%{http_code}' \
            "$@" "$RELAY_URL$path" 2>/dev/null
    return 0
}

# Splits relay_request output into RESP_BODY / RESP_CODE.
RESP_BODY=""
RESP_CODE=""
split_response() {
    local resp="$1" nl='
'
    case "$resp" in
        *"$nl"*)
            RESP_CODE="${resp##*$nl}"
            RESP_BODY="${resp%$nl*}"
            ;;
        *)
            RESP_CODE="$resp"
            RESP_BODY=""
            ;;
    esac
    case "$RESP_CODE" in
        [0-9][0-9][0-9]) ;;
        *) RESP_CODE="000" ;;
    esac
}

# post_envelope MAX_TIME JSON_FILE -> sets RESP_CODE. The payload goes in a
# 0600 temp file, not argv, because it carries commands and transcript text.
post_envelope() {
    local max_time="$1" file="$2"
    split_response "$(relay_request POST /intervention "$max_time" \
        -H "Content-Type: application/json" --data-binary "@$file")"
}

# write_payload NAME JSON -> prints the path of a temp file holding JSON.
write_payload() {
    local file="$WORK_DIR/$1.json"
    printf '%s' "$2" > "$file" 2>/dev/null || return 1
    printf '%s' "$file"
}

# Closes our pending intervention (no-op once someone else has closed it).
# Retried (up to 3 attempts) while the relay doesn't answer, as long as the
# agent's own timeout leaves room: a page whose close never lands stays on
# the phone until the Worker expires it, and it often follows a lost relay.
close_intervention() {
    local reason="$1" json file attempt=1
    [ "$IV_OPEN" = "1" ] || return 0
    IV_OPEN=0
    [ -n "$IV_ID" ] && [ -n "$WORK_DIR" ] || return 0
    json=$(jq -nc --arg id "$IV_ID" --arg reason "$reason" \
        '{type: "intervention.closed", payload: {id: $id, reason: $reason}}' 2>/dev/null) || return 0
    file=$(write_payload close "$json") || return 0
    while :; do
        post_envelope 4 "$file"
        log "POST close id=$IV_ID reason=$reason http=$RESP_CODE (attempt $attempt)"
        case "$RESP_CODE" in
            2??|4??) return 0 ;;              # closed, or the relay won't ever take it
        esac
        [ "$attempt" -lt 3 ] || return 0
        [ $(( $(date +%s) + 6 )) -lt $(( START_TS + AGENT_TIMEOUT )) ] || return 0
        sleep 1
        attempt=$((attempt + 1))
    done
}

# Tells the phone what happened to its reply (v2 Workers show this as the
# delivery result; older Workers just log it). Skipped when the item was
# already closed elsewhere: whoever closed it reported its own outcome.
report_delivery() {
    local success="$1" detail="$2" json file
    [ "$IV_OPEN" = "1" ] || return 0
    [ -n "$IV_ID" ] && [ -n "$WORK_DIR" ] || return 0
    json=$(jq -nc --arg id "$IV_ID" --argjson ok "$success" --arg detail "$detail" \
        '{type: "reply.injected", payload: {interventionId: $id, method: "hook", success: $ok, detail: $detail}}' \
        2>/dev/null) || return 0
    file=$(write_payload delivery "$json") || return 0
    post_envelope 4 "$file"
    log "POST reply.injected id=$IV_ID success=$success http=$RESP_CODE"
}

# Reports the outcome, closes the page as "replied" (the Worker's signal that
# the decision was applied) — always before the decision is printed.
settle() {
    local success="$1" detail="$2"
    report_delivery "$success" "$detail"
    close_intervention replied
}

# ---------------------------------------------------------------------------
# Context

# Only use python3 if it's real: on a Mac without the Command Line Tools,
# /usr/bin/python3 is a stub that pops an install dialog.
have_python() {
    local py
    py=$(command -v python3 2>/dev/null) || return 1
    if [ "$py" = "/usr/bin/python3" ]; then
        xcode-select -p >/dev/null 2>&1 || return 1
    fi
    return 0
}

find_extractor() {
    local candidate
    for candidate in "$SCRIPT_DIR/page-extract-context.py" "$HOME/.claude/hooks/page-extract-context.py"; do
        if [ -f "$candidate" ] && [ -r "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# Recent transcript activity, or nothing. Claude transcripts only: Codex
# rollouts are a different (and explicitly unstable) format.
transcript_context() {
    local transcript extractor
    [ "$AGENT" = "claude" ] || return 0
    transcript=$(jq -r '.transcript_path // ""' <<<"$EVENT_JSON" 2>/dev/null)
    [ -n "$transcript" ] && [ -f "$transcript" ] && [ -r "$transcript" ] || return 0
    have_python || return 0
    extractor=$(find_extractor) || return 0
    if [ "${PAGE_CONTEXT_TOOL_OUTPUT:-}" = "1" ]; then
        python3 -I "$extractor" --tool-output "$transcript" 2>/dev/null </dev/null
    else
        python3 -I "$extractor" "$transcript" 2>/dev/null </dev/null
    fi
    return 0
}

# Best-effort secret redaction for text we build ourselves (tool commands).
redact() {
    local extractor
    if have_python && extractor=$(find_extractor); then
        python3 -I "$extractor" --redact 2>/dev/null
    else
        cat
    fi
}

# compose_context HEADLINE -> headline, then recent activity, capped.
compose_context() {
    local headline="$1" tail
    tail=$(transcript_context)
    if [ -n "$tail" ]; then
        jq -rn --arg h "$headline" --arg t "$tail" --argjson max "$CONTEXT_MAX_CHARS" \
            '($h + "\n\n— recent activity —\n" + $t) | .[0:$max]' 2>/dev/null
    else
        jq -rn --arg h "$headline" --argjson max "$CONTEXT_MAX_CHARS" '$h | .[0:$max]' 2>/dev/null
    fi
}

# Prints the tool_use id of the prompt this event is about, or nothing.
# PermissionRequest / PreToolUse: the event's own tool_use_id when it has
# one. Otherwise (and for Notification) the LAST tool call in the Claude
# transcript tail that has no tool_result yet, parsed the way the Mac's
# InterventionDetector.parseTranscriptTail does: sidechain records are
# skipped, a tool_result answers its tool_use, and a real user message
# (no tool_result) means nothing before it is pending. The Worker stores it
# as the page's promptKey and echoes it to the Mac with the reply, so the
# Mac can tell whether the prompt on screen is still this one. Codex
# rollouts are a different format: only the event's own id is used there.
prompt_key() {
    local key="" transcript
    case "$EVENT_NAME" in
        PermissionRequest|PreToolUse)
            key=$(jq -r '(.tool_use_id // "") | if type == "string" then . else "" end' <<<"$EVENT_JSON" 2>/dev/null)
            ;;
    esac
    if [ -z "$key" ] && [ "$AGENT" = "claude" ]; then
        transcript=$(jq -r '(.transcript_path // "") | if type == "string" then . else "" end' <<<"$EVENT_JSON" 2>/dev/null)
        if [ -n "$transcript" ] && [ -f "$transcript" ] && [ -r "$transcript" ]; then
            key=$(tail -c 262144 "$transcript" 2>/dev/null | jq -nrR '
                def items: (.message.content // []) | if type == "array" then .[] | select(type == "object") else empty end;
                reduce (inputs | (fromjson? // null)
                        | select(type == "object" and .isSidechain != true
                                 and (.type == "assistant" or .type == "user")
                                 and (.message | type) == "object")) as $r
                    ({order: [], open: {}};
                     if $r.type == "assistant" then
                         reduce ($r | items | select(.type == "tool_use" and (.id | type) == "string") | .id) as $id
                             (.; (if .open[$id] == null and ((.order | index([$id])) == null) then .order += [$id] else . end)
                                 | .open[$id] = true)
                     else
                         [ $r | items | select(.type == "tool_result") | .tool_use_id ] as $answered
                         | if ($answered | length) == 0 then .open = {}
                           else reduce ($answered[] | select(type == "string")) as $id (.; .open |= del(.[$id])) end
                     end)
                | . as $s | [ $s.order[] | select($s.open[.] == true) ] | first // empty
            ' 2>/dev/null)
        fi
    fi
    # Only an id-shaped value travels (the Worker applies the same rule).
    case "$key" in
        ''|*[!A-Za-z0-9_.:-]*) return 0 ;;
    esac
    [ "${#key}" -le 200 ] || return 0
    printf '%s' "$key"
}

# open_intervention KIND CONTEXT [SUBTYPE] [HOLD_SECONDS] -> sets RESP_CODE.
# HOLD_SECONDS (blocking modes) tells the Worker how long this hook will
# wait at most, so it can expire the page if the hook dies without closing it.
open_intervention() {
    local kind="$1" context="$2" subtype="${3:-}" hold="${4:-}" cwd project json file pkey
    pkey=$(prompt_key)
    cwd=$(jq -r '.cwd // ""' <<<"$EVENT_JSON" 2>/dev/null)
    project=$(basename "${cwd:-$(agent_label)}" 2>/dev/null)
    [ -n "$project" ] && [ "$project" != "/" ] || project="$(agent_label)"
    json=$(jq -nc \
        --arg id "$IV_ID" \
        --arg sid "$SESSION_ID" \
        --arg cwd "$cwd" \
        --arg proj "$project" \
        --arg ctx "$context" \
        --arg kind "$kind" \
        --arg subtype "$subtype" \
        --arg backend "$AGENT" \
        --arg hold "$hold" \
        --arg pkey "$pkey" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            type: "intervention.opened",
            payload: ({
                id: $id, sessionId: $sid, cwd: $cwd, projectName: $proj,
                kind: $kind, openedAt: $now, context: $ctx, backend: $backend
            } + (if $subtype != "" then {subtype: $subtype} else {} end)
              + (if ($hold | test("^[0-9]+$")) then {holdSeconds: ($hold | tonumber)} else {} end)
              + (if $pkey != "" then {promptKey: $pkey} else {} end))
        }' 2>/dev/null) || { RESP_CODE="000"; return 0; }
    if ! file=$(write_payload open "$json"); then
        RESP_CODE="000"
        return 0
    fi
    post_envelope 6 "$file"
}

make_id() {
    printf '%s-%s-%s-%s' "$1" "${SESSION_ID:0:8}" "$(date +%s)" "$$"
}

# BSD stat by absolute path: a GNU coreutils `stat` ahead of /usr/bin in
# PATH reads -f as --file-system and fails (which used to make the detector
# and hold markers look stale). GNU syntax only as a fallback.
file_age_seconds() {
    local mtime
    mtime=$(/usr/bin/stat -f %m "$1" 2>/dev/null) || mtime=$(stat -c %Y "$1" 2>/dev/null) || return 1
    case "$mtime" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "$(( $(date +%s) - mtime ))"
}

lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Strips leading/trailing whitespace from the whole string (not per line:
# a typed reply may contain indented code).
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Presence

# Seconds since the last keyboard/mouse input, from the HID system. Empty
# when it can't be read. `ioreg` is looked up on PATH (tests shadow it).
hid_idle_seconds() {
    ioreg -c IOHIDSystem -d 4 2>/dev/null |
        awk '/HIDIdleTime/ { print int($NF / 1000000000); exit }'
}

away_threshold() {
    local v="${PAGE_HOOK_ONLY_WHEN_AWAY:-}"
    case "$v" in
        ''|*[!0-9]*) printf '%s' "$DEFAULT_AWAY_SECONDS" ;;
        *) printf '%s' "$v" ;;
    esac
}

# synthetic_input_explains_idle IDLE_SECONDS -> 0 when the last input
# (IDLE_SECONDS ago) lines up, within SYNTHETIC_INPUT_TOLERANCE seconds,
# with the Page Mac app's own synthetic keystroke (its marker file), i.e.
# the idle reset was Page typing a phone reply, not the user. Same rule as
# the app's SyntheticInput.explainsIdleReset.
synthetic_input_explains_idle() {
    local m now last
    m=$(head -n 1 "$SYNTHETIC_INPUT_MARKER" 2>/dev/null | tr -d '[:space:]')
    case "$m" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#m}" -le 12 ] || return 1
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    now=$(date +%s)
    last=$(( now - $1 ))
    [ $(( last - m )) -le "$SYNTHETIC_INPUT_TOLERANCE" ] && [ $(( m - last )) -le "$SYNTHETIC_INPUT_TOLERANCE" ]
}

# True (0) when the user has touched the Mac recently, so the dialog should
# show instead of a page. An unreadable idle time counts as present: the
# safe default is the dialog in front of whoever might be there. An input
# that was Page's own synthetic keystroke doesn't count.
user_is_present() {
    local threshold idle
    threshold=$(away_threshold)
    [ "$threshold" -gt 0 ] 2>/dev/null || return 1
    idle=$(hid_idle_seconds)
    case "$idle" in
        ''|*[!0-9]*) log "presence: HID idle time unreadable — treating as present"; return 0 ;;
    esac
    [ "$idle" -lt "$threshold" ] || return 1
    if synthetic_input_explains_idle "$idle"; then
        log "presence: last input ${idle}s ago was Page's own keystroke — treating as away"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Hold markers: tell the Page Mac app's detector "this prompt is already
# paged". One file per hook process (subagents and parallel requests share a
# session id, so a per-session file would be deleted by whichever hook
# finished first).

hold_begin() {
    local json
    case "$SESSION_ID" in
        ''|unknown|.*|*[!A-Za-z0-9._-]*) return 0 ;;
    esac
    [ "${#SESSION_ID}" -le 200 ] || return 0
    mkdir -p "$HOLD_DIR" 2>/dev/null || return 0
    chmod 700 "$HOLD_DIR" 2>/dev/null
    HOLD_FILE="$HOLD_DIR/$SESSION_ID.$$"
    json=$(jq -nc --arg sid "$SESSION_ID" --arg id "$IV_ID" --arg agent "$AGENT" \
        --arg event "$EVENT_NAME" --argjson pid "$$" --argjson at "$(date +%s)" \
        '{sessionId: $sid, pid: $pid, interventionId: $id, agent: $agent, event: $event, startedAt: $at}' 2>/dev/null)
    if ! { printf '%s\n' "$json" > "$HOLD_FILE.tmp" && mv -f "$HOLD_FILE.tmp" "$HOLD_FILE"; } 2>/dev/null; then
        rm -f "$HOLD_FILE.tmp" 2>/dev/null
        HOLD_FILE=""
    fi
}

hold_touch() {
    [ -n "$HOLD_FILE" ] && touch "$HOLD_FILE" 2>/dev/null
    return 0
}

hold_end() {
    if [ -n "$HOLD_FILE" ]; then
        rm -f "$HOLD_FILE" "$HOLD_FILE.tmp" 2>/dev/null
        HOLD_FILE=""
    fi
    return 0
}

# True (0) if another Page hook process is holding a request for SESSION_ID.
session_is_held() {
    local f age
    case "$SESSION_ID" in
        ''|unknown|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    for f in "$HOLD_DIR/$SESSION_ID".*; do
        [ -f "$f" ] || continue
        case "$f" in *.tmp) continue ;; esac
        age=$(file_age_seconds "$f") || continue
        [ "$age" -lt "$HOLD_FRESH_SECONDS" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Claude session status: if the prompt gets answered somewhere else (at the
# Mac, by another hook such as cmux's), stop paging. Only trusted after the
# session has been seen "waiting" during our hold, because whether the
# status flips while a PermissionRequest hook runs isn't documented.

find_session_file() {
    local f pid
    SESSION_FILE=""
    [ "$AGENT" = "claude" ] || return 0
    [ -d "$CLAUDE_SESSIONS_DIR" ] || return 0
    for f in "$CLAUDE_SESSIONS_DIR"/*.json; do
        [ -f "$f" ] || continue
        pid=$(jq -r --arg sid "$SESSION_ID" 'if .sessionId == $sid then (.pid // "") else "" end' "$f" 2>/dev/null)
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        if kill -0 "$pid" 2>/dev/null; then
            SESSION_FILE="$f"
            SESSION_PID="$pid"
            return 0
        fi
    done
    return 0
}

# Returns 0 when the prompt has clearly been resolved elsewhere.
resolved_elsewhere() {
    local line status updated
    [ -n "$SESSION_FILE" ] || return 1
    if [ ! -f "$SESSION_FILE" ]; then
        # The session exited (clean exit removes the file).
        [ "$SAW_WAITING" = "1" ] && return 0
        return 1
    fi
    line=$(jq -r '"\(.status // "")|\(.statusUpdatedAt // "")"' "$SESSION_FILE" 2>/dev/null) || return 1
    status="${line%%|*}"
    updated="${line#*|}"
    case "$status" in
        waiting)
            SAW_WAITING=1
            WAITING_SINCE="$updated"
            ;;
        busy|idle)
            if [ "$SAW_WAITING" = "1" ] && [ "$updated" != "$WAITING_SINCE" ]; then
                return 0
            fi
            ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# The agent process: a blocking wait must end when the agent is gone (a
# crash, a SIGKILL, a timed-out background run) — otherwise an orphaned hook
# could tell the phone "Approved — running it" for a process that no longer
# exists.

# Sets AGENT_PID: the Claude session's own pid when its sessions file was
# found, else the nearest ancestor that is the agent, else our parent (and
# then AGENT_PID_IS_PARENT=1: a wrapper shell might outlive the agent, so
# being re-parented to launchd also counts as "gone").
find_agent_pid() {
    if [ -n "$SESSION_PID" ]; then
        AGENT_PID="$SESSION_PID"
        return 0
    fi
    AGENT_PID=$(ancestor_matching is_agent_command) || AGENT_PID=""
    if [ -z "$AGENT_PID" ]; then
        AGENT_PID="$PPID"
        AGENT_PID_IS_PARENT=1
    fi
    return 0
}

agent_alive() {
    local ppid
    [ -n "$AGENT_PID" ] || return 0
    kill -0 "$AGENT_PID" 2>/dev/null || return 1
    if [ "$AGENT_PID_IS_PARENT" = "1" ]; then
        ppid=$(ps -o ppid= -p "$$" 2>/dev/null | tr -d '[:space:]')
        [ "$ppid" = "1" ] && return 1
    fi
    return 0
}

# Called with a reply in hand, before anything is reported or printed.
ensure_can_settle() {
    agent_alive || fall_back "the agent exited before the reply arrived" agent_exited
    if [ "$(date +%s)" -ge $(( START_TS + AGENT_TIMEOUT - SETTLE_RESERVE )) ]; then
        fall_back "the reply came too late to apply before the agent's ${AGENT_TIMEOUT}s hook timeout" too_late
    fi
}

# ---------------------------------------------------------------------------
# Blocking wait

# TIMEOUT = PAGE_HOOK_TIMEOUT (default 540, 5–3600), but never past the
# agent's own timeout minus AGENT_TIMEOUT_SAFETY, counted from script start.
resolve_timeout() {
    local t="${PAGE_HOOK_TIMEOUT:-$DEFAULT_TIMEOUT}" budget
    case "$t" in
        ''|*[!0-9]*) t=$DEFAULT_TIMEOUT ;;
    esac
    [ "${#t}" -le 5 ] || t=3600
    [ "$t" -lt 5 ] && t=5
    [ "$t" -gt 3600 ] && t=3600
    budget=$(( START_TS + AGENT_TIMEOUT - AGENT_TIMEOUT_SAFETY - $(date +%s) ))
    if [ "$t" -gt "$budget" ]; then
        [ -n "${PAGE_HOOK_TIMEOUT:-}" ] &&
            log "PAGE_HOOK_TIMEOUT=$PAGE_HOOK_TIMEOUT capped to ${budget}s by the agent's ${AGENT_TIMEOUT}s hook timeout"
        t=$budget
    fi
    TIMEOUT=$t
}

# Common start for every blocking mode: relay, presence, token, page. Each
# precondition that fails prints nothing (or "ask" in the legacy mode).
# begin_blocking KIND CONTEXT [SUBTYPE]
begin_blocking() {
    local kind="$1" context="$2" subtype="${3:-}"
    [ -n "$WORK_DIR" ] || fall_back "couldn't create a temp file"
    resolve_relay_url
    # Not set up at all: behave exactly as if the hook weren't installed.
    [ -n "$RELAY_URL" ] || quiet_exit "$EVENT_NAME: no relay configured — normal flow"
    if user_is_present; then
        quiet_exit "$EVENT_NAME: user is at the Mac — normal flow"
    fi
    if [ "$AGENT" = "claude" ] && [ "${PAGE_HOOK_PRINT:-}" != "1" ] && under_claude_print; then
        quiet_exit "$EVENT_NAME: non-interactive claude --print run — normal flow (PAGE_HOOK_PRINT=1 pages these)"
    fi
    read_token
    [ -n "$TOKEN" ] || fall_back "no usable relay token (pair the Page Mac app first)"
    resolve_timeout
    [ "$TIMEOUT" -ge 5 ] || fall_back "only ${TIMEOUT}s left before the agent's ${AGENT_TIMEOUT}s hook timeout"

    IV_ID=$(make_id hookpre)
    hold_begin
    # Assume the page is stored until the relay says otherwise: a lost
    # response (000) or a 5xx may come after the Worker stored it, and only a
    # close (via fall_back / the EXIT trap) clears it. Closing an id the
    # Worker never stored just leaves a harmless tombstone.
    IV_OPEN=1
    open_intervention "$kind" "$context" "$subtype" "$TIMEOUT"
    log "$EVENT_NAME: POST open id=$IV_ID kind=$kind${subtype:+/$subtype} agent=$AGENT http=$RESP_CODE"
    case "$RESP_CODE" in
        2??) ;;
        401|403) IV_OPEN=0; fall_back "the relay rejected the token (HTTP $RESP_CODE)" ;;
        410)     IV_OPEN=0; fall_back "the relay token was retired (re-paired on the Mac)" ;;
        4??) IV_OPEN=0; fall_back "relay error (HTTP $RESP_CODE)" ;;
        000) fall_back "relay unreachable" ;;
        *)   fall_back "relay error (HTTP $RESP_CODE)" ;;
    esac
    find_session_file
    find_agent_pid
}

# Polls until the phone replies (sets REPLY_ACTION / REPLY_TEXT and returns)
# or gives up through fall_back.
wait_for_reply() {
    local deadline failures item hist idle now last_check elapsed
    log "$EVENT_NAME: waiting up to ${TIMEOUT}s for a reply"
    deadline=$(( $(date +%s) + TIMEOUT ))
    # The open may have taken a few seconds: the agent's timeout still rules.
    [ "$deadline" -le $(( START_TS + AGENT_TIMEOUT - AGENT_TIMEOUT_SAFETY )) ] ||
        deadline=$(( START_TS + AGENT_TIMEOUT - AGENT_TIMEOUT_SAFETY ))
    failures=0
    last_check=$(date +%s)
    while [ "$(date +%s)" -lt "$deadline" ]; do
        # Sleep in the background and `wait`, so INT/TERM interrupt the wait
        # immediately instead of after the sleep finishes.
        sleep "$POLL_INTERVAL" &
        wait $! 2>/dev/null
        hold_touch

        agent_alive || fall_back "the agent exited" agent_exited

        # Back at the Mac? Any input since the last check means someone is
        # there to answer the dialog, which this hook may be holding back.
        if [ "$(away_threshold)" -gt 0 ] 2>/dev/null; then
            now=$(date +%s)
            elapsed=$(( now - last_check ))
            last_check=$now
            idle=$(hid_idle_seconds)
            case "$idle" in
                ''|*[!0-9]*) ;;
                *)
                    if [ "$idle" -le "$elapsed" ]; then
                        if synthetic_input_explains_idle "$idle"; then
                            log "input ${idle}s ago was Page's own keystroke — still waiting"
                        else
                            fall_back "you're back at the Mac (input ${idle}s ago)" user_returned
                        fi
                    fi
                    ;;
            esac
        fi

        if resolved_elsewhere; then
            fall_back "the prompt was answered elsewhere" resolved_elsewhere
        fi

        split_response "$(relay_request GET /interventions 5)"
        case "$RESP_CODE" in
            200) failures=0 ;;
            401|403)
                fall_back "the relay rejected the token (HTTP $RESP_CODE)"
                ;;
            410)
                # token_retired: the pairing was replaced on the Mac. The
                # Worker already dropped our page; nothing will ever answer.
                IV_OPEN=0
                fall_back "the relay token was retired (re-paired on the Mac)"
                ;;
            *)
                failures=$((failures + 1))
                log "poll failed http=$RESP_CODE ($failures/$MAX_POLL_FAILURES)"
                if [ "$failures" -ge "$MAX_POLL_FAILURES" ]; then
                    fall_back "lost contact with the relay"
                fi
                continue
                ;;
        esac

        item=$(jq -c --arg id "$IV_ID" 'if type == "array" then (map(select(.id == $id)) | first // empty) else empty end' \
            <<<"$RESP_BODY" 2>/dev/null)
        if [ -n "$item" ]; then
            # Key on repliedAt, not repliedAction: a reply with no action
            # (typed text on an old Worker) is still a reply.
            if [ "$(jq -r '.repliedAt // ""' <<<"$item" 2>/dev/null)" != "" ]; then
                parse_reply "$item"
                ensure_can_settle
                return 0
            fi
            continue
        fi

        # Gone from the inbox. Someone closed it: an older Mac that injected
        # the reply and closed it, or an older Worker's supersede/cascade.
        # History keeps replied items, so look there before giving up.
        IV_OPEN=0
        split_response "$(relay_request GET '/history?limit=50' 5)"
        hist=""
        if [ "$RESP_CODE" = "200" ]; then
            hist=$(jq -c --arg id "$IV_ID" 'if type == "array" then (map(select(.id == $id)) | first // empty) else empty end' \
                <<<"$RESP_BODY" 2>/dev/null)
        fi
        if [ -n "$hist" ] && [ "$(jq -r '.repliedAt // ""' <<<"$hist" 2>/dev/null)" != "" ]; then
            parse_reply "$hist"
            ensure_can_settle
            return 0
        fi
        fall_back "the page was closed before you replied"
    done

    log "$EVENT_NAME: no reply within ${TIMEOUT}s"
    fall_back "no reply within ${TIMEOUT}s" timeout
}

# Sets REPLY_ACTION / REPLY_TEXT from a replied intervention.
parse_reply() {
    local item="$1"
    REPLY_ACTION=$(jq -r '.repliedAction // ""' <<<"$item" 2>/dev/null)
    REPLY_TEXT=$(jq -r '(.repliedText // "") | .[0:4000]' <<<"$item" 2>/dev/null)
    REPLY_TEXT=$(trim "$REPLY_TEXT")
    # Old Workers store a null action as missing; a bare typed reply is custom.
    if [ -z "$REPLY_ACTION" ] && [ -n "$REPLY_TEXT" ]; then
        REPLY_ACTION="custom"
    fi
    log "reply id=$IV_ID action=${REPLY_ACTION:-none} text=${#REPLY_TEXT}B"
}

# A reply that isn't a decision: tell the phone and hand back to the dialog.
not_a_decision() {
    local detail="$1"
    report_delivery false "$detail"
    fall_back "reply \"${REPLY_ACTION:-empty}\" isn't a decision" not_a_decision
}

# ---------------------------------------------------------------------------
# Tool summaries for the phone

tool_summary() {
    jq -r '
        (.tool_input // {}) as $i |
        (.tool_name // "tool") as $t |
        def s: if . == null then "" elif type == "string" then . else tostring end;
        def clip($n): if length > $n then .[0:$n] + "…" else . end;
        if $t == "Bash" then
            "$ " + ($i.command | s | clip(1200))
            + (if ($i.description | s) != "" then "\n# " + ($i.description | s | clip(200)) else "" end)
        elif $t == "apply_patch" then
            "Apply patch:\n" + ($i.command | s | clip(1500))
        elif $t == "Edit" then
            "Edit " + ($i.file_path // "(unknown file)" | s)
            + (if ($i.old_string | s) != "" then "\n- " + ($i.old_string | s | clip(300)) else "" end)
            + (if ($i.new_string | s) != "" then "\n+ " + ($i.new_string | s | clip(300)) else "" end)
        elif $t == "MultiEdit" then
            "Edit " + ($i.file_path | s) + " (" + (($i.edits // []) | length | tostring) + " changes)"
        elif $t == "Write" then
            "Write " + ($i.file_path | s) + "\n" + ($i.content | s | clip(400))
        elif $t == "NotebookEdit" then
            "Edit notebook " + ($i.notebook_path | s)
        elif $t == "WebFetch" then
            "Fetch " + ($i.url | s)
        elif $t == "ExitPlanMode" then
            "Plan ready for approval:\n" + ($i.plan | s | clip(1500))
        else
            $t + ": " + ($i | tostring | clip(400))
        end
    ' <<<"$EVENT_JSON" 2>/dev/null
}

question_summary() {
    jq -r '
        def s: if . == null then "" elif type == "string" then . else tostring end;
        def clip($n): if length > $n then .[0:$n] + "…" else . end;
        ((.tool_input.questions // []) | if type == "array" then . else [] end) as $qs |
        if ($qs | length) == 0 then "Claude has a question" else
        [ $qs | to_entries[] |
            (if ($qs | length) > 1 then "Q\(.key + 1). " else "" end)
            + ((.value.question // .value.header // "Question") | s | clip(500))
            + (if .value.multiSelect == true then " (pick any, comma-separated)" else "" end)
            + ([ (.value.options // []) | to_entries[] |
                 "\n\(.key + 1). " + (.value.label | s | clip(120))
                 + (if ((.value.description | s) != "") then " — " + (.value.description | s | clip(160)) else "" end)
               ] | join(""))
        ] | join("\n\n")
        + (if ($qs | length) > 1 then "\n\nReply with one answer per line, in order." else "" end)
        end
    ' <<<"$EVENT_JSON" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Notification: page and leave. The Mac app delivers the reply.

classify_notification() {
    local ntype="$1" message
    message=$(lowercase "$2")
    case "$ntype" in
        permission_prompt)  printf 'permission'; return ;;
        idle_prompt)        printf 'idle'; return ;;
        elicitation_dialog) printf 'question'; return ;;
    esac
    case "$message" in
        *permission*)               printf 'permission' ;;
        *"waiting for your input"*) printf 'idle' ;;
        *)                          printf 'question' ;;
    esac
}

handle_notification() {
    local ntype message kind age context
    ntype=$(jq -r '.notification_type // ""' <<<"$EVENT_JSON" 2>/dev/null)
    message=$(jq -r '.message // ""' <<<"$EVENT_JSON" 2>/dev/null)
    case "$ntype" in
        auth_success|elicitation_complete|elicitation_response|agent_completed|quota_auto_resume_*|plugin_notification)
            quiet_exit "notification: $ntype — not paging" ;;
    esac
    [ -n "$message" ] || message="Claude needs your attention"

    if [ -f "$DETECTOR_MARKER" ] && age=$(file_age_seconds "$DETECTOR_MARKER") &&
        [ "$age" -lt "$DETECTOR_FRESH_SECONDS" ]; then
        quiet_exit "notification: Mac detector alive (${age}s) — it pages this itself"
    fi
    if session_is_held; then
        quiet_exit "notification: a blocking Page hook already paged this session"
    fi

    resolve_relay_url
    [ -n "$RELAY_URL" ] || quiet_exit "notification: no relay configured — not paging"
    read_token
    [ -n "$TOKEN" ] || quiet_exit "notification: relay token missing — not paging"

    kind=$(classify_notification "$ntype" "$message")
    context=$(compose_context "$message")
    IV_ID=$(make_id hook)
    open_intervention "$kind" "$context"
    log "notification: POST open id=$IV_ID kind=$kind http=$RESP_CODE"
    exit 0
}

# ---------------------------------------------------------------------------
# PermissionRequest (Claude Code and Codex): fires only when a dialog would
# show. Approve -> allow, Deny -> deny, typed text -> deny with the text.

handle_permission_request() {
    local tool mode summary context
    tool=$(jq -r '.tool_name // ""' <<<"$EVENT_JSON" 2>/dev/null)
    mode=$(jq -r '.permission_mode // ""' <<<"$EVENT_JSON" 2>/dev/null)

    case "$tool" in
        # Answered by the PreToolUse path (they need `answers`, which a
        # permission decision can't carry); paging here too would double-page.
        AskUserQuestion|ExitPlanMode)
            quiet_exit "permissionrequest: $tool is handled by PreToolUse" ;;
    esac
    # Modes in which Claude wouldn't wait for an answer: bypassPermissions
    # allows, dontAsk denies. Paging would turn that into a long hold.
    case "$mode" in
        bypassPermissions|dontAsk) quiet_exit "permissionrequest: $mode — stepping aside" ;;
    esac

    summary=$(tool_summary | redact)
    [ -n "$summary" ] || summary="${tool:-A tool} needs approval"
    context=$(compose_context "$summary")

    begin_blocking permission "$context"
    wait_for_reply

    case "$REPLY_ACTION" in
        approve)
            settle true "Approved — $(agent_label) is running it"
            decide_permission allow
            ;;
        deny)
            settle true "Denied — $(agent_label) won't run it"
            if [ -n "$REPLY_TEXT" ] && [ "$(lowercase "$REPLY_TEXT")" != "deny" ]; then
                decide_permission deny "The user denied this from their phone (Page): $REPLY_TEXT"
            fi
            decide_permission deny "The user denied this from their phone (Page)."
            ;;
        custom)
            [ -n "$REPLY_TEXT" ] || not_a_decision "Empty reply — answer on the Mac"
            settle true "Sent to $(agent_label) instead of running it"
            decide_permission deny "The user replied from their phone (Page) instead of approving: $REPLY_TEXT"
            ;;
        *)
            # carry_on, an empty reply or anything newer than this script:
            # none of these is an explicit decision.
            not_a_decision "That reply isn't an approval — answer on the Mac"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# PreToolUse: AskUserQuestion / ExitPlanMode (answers), else the legacy
# generic blocking approval.

# Maps REPLY_TEXT onto tool_input.questions. Prints the `answers` object, or
# nothing when the reply can't be mapped without guessing.
map_answers() {
    jq -c --arg reply "$REPLY_TEXT" '
        def s: if . == null then "" elif type == "string" then . else tostring end;
        def norm: s | ascii_downcase | gsub("^\\s+|\\s+$"; "");
        # One answer string for one question -> option label, or null.
        def pick($q; $ans):
            ($q.options // [] | if type == "array" then . else [] end) as $opts |
            ($ans | norm) as $a |
            if ($a | test("^[0-9]+$")) and (($a | tonumber) >= 1) and (($a | tonumber) <= ($opts | length))
                then $opts[($a | tonumber) - 1].label | s
            else
                ([ $opts[] | select((.label | norm) == $a) | .label | s ] | first) //
                ( ([ $ans | s | capture("^\\s*(?<n>[0-9]+)[.)]\\s+(?<rest>.+)$") ] | first) as $m |
                  if $m != null and (($m.n | tonumber) >= 1) and (($m.n | tonumber) <= ($opts | length))
                     and (($opts[($m.n | tonumber) - 1].label | norm) == ($m.rest | norm))
                  then $opts[($m.n | tonumber) - 1].label | s else null end )
            end;
        def answer($q; $ans):
            if $q.multiSelect == true then
                [ $ans | split(",")[] | select(norm != "") | pick($q; .) ] as $picked |
                if ($picked | length) > 0 and ($picked | all(. != null)) then $picked | join(", ") else null end
            else pick($q; $ans) end;
        (.tool_input.questions // []) as $qs |
        if ($qs | type) != "array" or ($qs | length) == 0 then empty else
        ( if ($qs | length) == 1 then [$reply]
          else [ $reply | split("\n")[] | select(norm != "") ] end ) as $lines |
        if ($lines | length) != ($qs | length) then empty else
        [ range(0; $qs | length) as $i |
            { key: (($qs[$i].question // $qs[$i].header) | s), value: answer($qs[$i]; $lines[$i]) } ] as $pairs |
        # Every question must get exactly one mapped answer; a partial map
        # would silently drop a question.
        if ($pairs | length) == ($qs | length) and ($pairs | all(.value != null and .key != ""))
        then ($pairs | from_entries) else empty end
        end end
    ' <<<"$EVENT_JSON" 2>/dev/null
}

handle_question() {
    local context answers updated
    context=$(compose_context "$(question_summary)")
    begin_blocking question "$context"
    wait_for_reply

    case "$REPLY_ACTION" in
        deny)
            settle true "Told Claude you'd rather not answer"
            if [ -n "$REPLY_TEXT" ] && [ "$(lowercase "$REPLY_TEXT")" != "deny" ]; then
                decide_pretool_deny "The user declined to answer from their phone (Page): $REPLY_TEXT"
            fi
            decide_pretool_deny "The user declined to answer from their phone (Page)."
            ;;
        custom|approve|carry_on)
            # Only typed text answers a question; a bare Approve / Carry on
            # doesn't say which option.
            [ -n "$REPLY_TEXT" ] || not_a_decision "Type an answer (or a number) to reply to a question"
            answers=$(map_answers)
            if [ -n "$answers" ]; then
                updated=$(jq -c --argjson a "$answers" '(.tool_input // {}) + {answers: $a}' <<<"$EVENT_JSON" 2>/dev/null)
                if [ -n "$updated" ]; then
                    settle true "Answered — Claude has your choice"
                    decide_pretool_allow_with_input "Answered via Page" "$updated"
                fi
            fi
            # Not one of the options (or can't be split per question): hand
            # the text to Claude rather than guess an answer.
            settle true "Sent your reply to Claude as text"
            decide_pretool_deny "The user answered from their phone (Page) in their own words instead of picking an option: $REPLY_TEXT"
            ;;
        *)
            not_a_decision "That reply doesn't answer the question — answer on the Mac"
            ;;
    esac
}

handle_plan() {
    local context updated summary
    summary=$(tool_summary | redact)
    [ -n "$summary" ] || summary="Claude has a plan ready for approval"
    context=$(compose_context "$summary")
    begin_blocking permission "$context" plan
    wait_for_reply

    case "$REPLY_ACTION" in
        approve)
            # ExitPlanMode needs `allow` with updatedInput (allow alone isn't
            # enough); echo the input Claude Code gave us (plan, planFilePath).
            updated=$(jq -c '(.tool_input // {}) | if type == "object" then . else {} end' <<<"$EVENT_JSON" 2>/dev/null)
            [ -n "$updated" ] || fall_back "couldn't read the plan input"
            settle true "Plan approved — Claude is starting"
            decide_pretool_allow_with_input "Plan approved via Page" "$updated"
            ;;
        deny)
            settle true "Plan rejected — Claude keeps planning"
            if [ -n "$REPLY_TEXT" ] && [ "$(lowercase "$REPLY_TEXT")" != "deny" ]; then
                decide_pretool_deny "The user rejected this plan from their phone (Page). Their feedback: $REPLY_TEXT"
            fi
            decide_pretool_deny "The user rejected this plan from their phone (Page). Keep planning and ask what to change."
            ;;
        custom)
            [ -n "$REPLY_TEXT" ] || not_a_decision "Empty reply — answer on the Mac"
            settle true "Sent your feedback — Claude keeps planning"
            decide_pretool_deny "The user replied from their phone (Page) instead of approving the plan. Their feedback: $REPLY_TEXT"
            ;;
        *)
            not_a_decision "That reply isn't an approval — answer on the Mac"
            ;;
    esac
}

# Legacy: a manual install whose PreToolUse matcher covers ordinary tools.
handle_pretooluse_generic() {
    local tool mode summary context
    FAIL_MODE="ask"
    tool=$(jq -r '.tool_name // ""' <<<"$EVENT_JSON" 2>/dev/null)
    mode=$(jq -r '.permission_mode // ""' <<<"$EVENT_JSON" 2>/dev/null)

    # Escape hatch: explicit decisions only. A typo must not become "allow".
    case "${PAGE_HOOK_AUTO:-}" in
        allow) decide_pretool_legacy "allow" "Auto-allowed via PAGE_HOOK_AUTO" ;;
        deny)  decide_pretool_legacy "deny"  "Auto-denied via PAGE_HOOK_AUTO" ;;
        ask)   decide_pretool_legacy "ask"   "Page: PAGE_HOOK_AUTO=ask" ;;
        "")    ;;
        *)     log "ignoring unknown PAGE_HOOK_AUTO value" ;;
    esac

    # Respect the permission mode the user chose: Claude wouldn't prompt here.
    case "$mode" in
        bypassPermissions|dontAsk) quiet_exit "pretooluse: $mode — stepping aside" ;;
        acceptEdits)
            case "$tool" in
                Edit|MultiEdit|Write|NotebookEdit) quiet_exit "pretooluse: $mode + $tool — stepping aside" ;;
            esac
            ;;
    esac

    summary=$(tool_summary | redact)
    [ -n "$summary" ] || summary="${tool:-A tool} needs approval"
    context=$(compose_context "$summary")

    begin_blocking permission "$context"
    wait_for_reply

    case "$REPLY_ACTION" in
        approve)
            settle true "Approved — Claude is running it"
            decide_pretool_legacy "allow" "Approved via Page"
            ;;
        deny)
            settle true "Denied — Claude won't run it"
            if [ -n "$REPLY_TEXT" ] && [ "$(lowercase "$REPLY_TEXT")" != "deny" ]; then
                decide_pretool_legacy "deny" "User denied this via Page: $REPLY_TEXT"
            fi
            decide_pretool_legacy "deny" "User denied this via Page."
            ;;
        custom)
            [ -n "$REPLY_TEXT" ] || not_a_decision "Empty reply — answer on the Mac"
            settle true "Sent to Claude instead of running the tool"
            decide_pretool_legacy "deny" "User replied via Page: $REPLY_TEXT"
            ;;
        *)
            not_a_decision "That reply isn't an approval — answer on the Mac"
            ;;
    esac
}

handle_pretooluse() {
    local tool
    tool=$(jq -r '.tool_name // ""' <<<"$EVENT_JSON" 2>/dev/null)
    case "$AGENT:$tool" in
        claude:AskUserQuestion) handle_question ;;
        claude:ExitPlanMode)    handle_plan ;;
        codex:*)                quiet_exit "pretooluse: not used for Codex" ;;
        *)                      handle_pretooluse_generic ;;
    esac
}

# ---------------------------------------------------------------------------
# Codex Stop (opt-in): keep the finished turn open while you're away; a typed
# reply becomes Codex's next prompt.

# ancestor_matching TEST -> prints the pid of the nearest ancestor (at most
# 8 levels up) whose command line TEST accepts; fails when none does.
ancestor_matching() {
    local test_fn="$1" pid=$PPID line ppid i=0
    while [ "$i" -lt 8 ] && [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
        line=$(ps -o ppid=,command= -p "$pid" 2>/dev/null) || return 1
        [ -n "$line" ] || return 1
        line="${line#"${line%%[![:space:]]*}"}"
        ppid="${line%%[[:space:]]*}"
        if "$test_fn" "${line#*[[:space:]]}"; then
            printf '%s' "$pid"
            return 0
        fi
        pid="$ppid"
        i=$((i + 1))
    done
    return 1
}

# True (0) when this hook runs under a non-interactive `codex exec` (e.g.
# the Page Mac app delivering a reply with `codex exec resume`): nobody is
# looking at that turn, and holding it open would stall the delivery.
under_codex_exec() {
    ancestor_matching is_codex_exec_command >/dev/null
}

# True (0) when the nearest Claude Code process above this hook is a
# `claude -p` / `claude --print` run.
under_claude_print() {
    local pid cmd
    pid=$(ancestor_matching is_claude_command) || return 1
    cmd=$(ps -o command= -p "$pid" 2>/dev/null) || return 1
    is_claude_print_command "$cmd"
}

is_claude_command() {
    set -f
    # shellcheck disable=SC2086
    set -- $1
    set +f
    is_claude_program "$@"
}

# is_claude_program WORDS… -> 0 when the program is Claude Code, and sets
# PROGRAM_ARGS_START to how many leading words name the program: `claude`,
# a native versioned binary (…/claude/versions/<semver>), or node/bun
# running …/claude or Claude Code's cli.js. Only the program name is
# trusted: a shell's `-c "<script>"` argument can mention anything.
PROGRAM_ARGS_START=0
is_claude_program() {
    PROGRAM_ARGS_START=0
    [ $# -gt 0 ] || return 1
    case "${1##*/}" in
        claude) PROGRAM_ARGS_START=1; return 0 ;;
        node|node[0-9]*|bun|deno)
            if [ $# -gt 1 ]; then
                case "$2" in
                    */claude|claude|*/claude-code/cli.js|*/claude-code/cli.mjs) PROGRAM_ARGS_START=2; return 0 ;;
                esac
            fi
            return 1
            ;;
    esac
    case "$1" in
        */claude/versions/*) PROGRAM_ARGS_START=1; return 0 ;;
    esac
    return 1
}

# Any agent process Page hooks run under (Claude Code or Codex).
is_agent_command() {
    set -f
    # shellcheck disable=SC2086
    set -- $1
    set +f
    is_claude_program "$@" && return 0
    [ $# -gt 0 ] || return 1
    case "${1##*/}" in
        codex) return 0 ;;
        node|node[0-9]*|bun|deno)
            [ $# -gt 1 ] && { [ "${2##*/}" = "codex" ] || [ "${2##*/}" = "codex.js" ]; } && return 0
            ;;
    esac
    return 1
}

# "claude [options] -p|--print …" with nobody to ask. Options after a bare
# "--" are the prompt. A --print process driven by a host that can prompt
# (IDE / Desktop / Agent SDK sessions: --input-format stream-json, or a
# --permission-prompt-tool) is not one: the host shows the approval and the
# hook may page alongside it as usual.
is_claude_print_command() {
    local word prev="" print=1
    set -f
    # shellcheck disable=SC2086
    set -- $1
    set +f
    is_claude_program "$@" || return 1
    shift "$PROGRAM_ARGS_START"
    for word in "$@"; do
        case "$word" in
            --) break ;;
            -p|--print|--print=*) print=0 ;;
            --permission-prompt-tool|--permission-prompt-tool=*|--input-format=stream-json) return 1 ;;
            stream-json) [ "$prev" = "--input-format" ] && return 1 ;;
        esac
        prev="$word"
    done
    return "$print"
}

# "codex [options] exec …" or "node …/codex [options] exec …". Only the
# program name is trusted, not substrings: a shell's `-c "<script>"`
# argument can mention anything.
is_codex_exec_command() {
    local word n=0
    set -f
    # shellcheck disable=SC2086
    set -- $1
    set +f
    [ $# -gt 0 ] || return 1
    case "${1##*/}" in
        codex) shift ;;
        node|node[0-9]*|bun|deno)
            [ $# -gt 1 ] && { [ "${2##*/}" = "codex" ] || [ "${2##*/}" = "codex.js" ]; } || return 1
            shift 2
            ;;
        *) return 1 ;;
    esac
    for word in "$@"; do
        case "$word" in
            exec|e) return 0 ;;
            -*) ;;
            *) n=$((n + 1)); [ "$n" -gt 2 ] && return 1 ;;   # option values
        esac
    done
    return 1
}

handle_codex_stop() {
    local last context prompt
    if under_codex_exec; then
        quiet_exit "stop: running under codex exec — not holding the turn"
    fi
    last=$(jq -r '(.last_assistant_message // "") | if type == "string" then . else "" end' <<<"$EVENT_JSON" 2>/dev/null)
    last=$(trim "$last")
    if [ -n "$last" ]; then
        # The end of a reply is where the agent asks for the next step.
        context=$(jq -rn --arg t "$last" --argjson max "$CONTEXT_MAX_CHARS" \
            'if ($t | length) > $max then "…" + $t[(($t | length) - $max + 1):] else $t end' 2>/dev/null)
    else
        context="Codex finished its turn"
    fi
    context=$(printf '%s' "$context" | redact)

    begin_blocking idle "$context"
    wait_for_reply

    case "$REPLY_ACTION" in
        custom)  prompt="$REPLY_TEXT" ;;
        carry_on) prompt="${REPLY_TEXT:-carry on}" ;;
        approve) prompt="${REPLY_TEXT:-yes, proceed}" ;;
        deny)
            settle true "Left Codex stopped"
            quiet_exit "stop: user chose to leave Codex stopped"
            ;;
        *)
            not_a_decision "That reply can't continue Codex — reply on the Mac"
            ;;
    esac
    [ -n "$prompt" ] || not_a_decision "Empty reply — Codex stays stopped"
    settle true "Sent to Codex as your next message"
    decide_stop_continue "$prompt"
}

# ---------------------------------------------------------------------------
# Main

rotate_log

EVENT_JSON=$(cat 2>/dev/null)

# Without jq/curl we can't do anything safely. Output nothing: the agent's
# normal flow (its own dialog), never an allow.
if ! command -v jq >/dev/null 2>&1; then
    quiet_exit "jq not found — install jq (brew install jq); hook inactive"
fi
if ! command -v curl >/dev/null 2>&1; then
    quiet_exit "curl not found — hook inactive"
fi

EVENT_NAME=$(jq -r '.hook_event_name // ""' <<<"$EVENT_JSON" 2>/dev/null)
SESSION_ID=$(jq -r '.session_id // ""' <<<"$EVENT_JSON" 2>/dev/null)
# The Worker requires a non-empty sessionId.
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"
log "==== $EVENT_NAME agent=$AGENT session=${SESSION_ID:0:8} ===="

# Tools that start agents in the background can opt out of Page entirely.
if [ "${PAGE_HOOK_SKIP:-}" = "1" ]; then
    quiet_exit "PAGE_HOOK_SKIP=1 — hook inactive for this run"
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/page-hook.XXXXXX" 2>/dev/null) || WORK_DIR=""

case "$AGENT:$EVENT_NAME" in
    claude:Notification)
        [ -n "$WORK_DIR" ] || quiet_exit "notification: no temp dir — not paging"
        handle_notification
        ;;
    *:PermissionRequest)
        handle_permission_request
        ;;
    *:PreToolUse)
        handle_pretooluse
        ;;
    codex:Stop)
        handle_codex_stop
        ;;
    *)
        quiet_exit "ignoring event '$EVENT_NAME' ($AGENT)"
        ;;
esac
exit 0
