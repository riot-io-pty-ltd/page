#!/bin/bash
# Page — Claude Code PreToolUse hook
#
# Intercepts Bash/Edit/Write/MultiEdit before Claude runs them, posts the
# request to the Page relay, blocks until you reply on your phone, then
# tells Claude to allow or deny.
#
# Reads the hook event JSON on stdin. Writes a JSON decision to stdout.
#
# Env (all optional):
#   PAGE_RELAY_URL       Worker base URL (default: production page-relay)
#   PAGE_HOOK_TIMEOUT    Seconds to wait for a reply before auto-denying (default: 300)
#   PAGE_HOOK_AUTO       If set to "allow" or "deny", skip the phone and use that.
#                        Useful when the phone isn't paired yet.

set -uo pipefail

RELAY_URL="${PAGE_RELAY_URL:-https://your-page-relay.workers.dev}"
TIMEOUT_SECONDS="${PAGE_HOOK_TIMEOUT:-300}"
POLL_INTERVAL=2

# Log everything to a single file so we can see what's happening.
LOG_FILE="${PAGE_HOOK_LOG:-$HOME/Library/Logs/page-hook.log}"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    printf "[%s] [pid=%s] %s\n" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$$" "$*" >> "$LOG_FILE"
}

decide() {
    local action="$1" reason="$2"
    log "DECIDE action=$action reason=$reason"
    jq -nc \
        --arg action "$action" \
        --arg reason "$reason" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $action, permissionDecisionReason: $reason}}'
    exit 0
}

log "==== hook fired ===="

# Read stdin
EVENT_JSON=$(cat)
log "stdin: $(printf '%s' "$EVENT_JSON" | head -c 400)"

# Pull context out of the event
EVENT_NAME=$(jq -r '.hook_event_name // ""' <<<"$EVENT_JSON")
TOOL_NAME=$(jq -r '.tool_name // ""' <<<"$EVENT_JSON")
SESSION_ID=$(jq -r '.session_id // "unknown"' <<<"$EVENT_JSON")
CWD=$(jq -r '.cwd // ""' <<<"$EVENT_JSON")
NOTIFICATION_MSG=$(jq -r '.message // ""' <<<"$EVENT_JSON")
PROJECT=$(basename "$CWD")
log "event=$EVENT_NAME tool=$TOOL_NAME session=${SESSION_ID:0:8} cwd=$CWD msg=$NOTIFICATION_MSG"

# Hard-coded auto-decision (escape hatch)
case "${PAGE_HOOK_AUTO:-}" in
    allow) decide "allow" "Auto-allowed via PAGE_HOOK_AUTO" ;;
    deny)  decide "deny"  "Auto-denied via PAGE_HOOK_AUTO"  ;;
esac

TRANSCRIPT_PATH=$(jq -r '.transcript_path // ""' <<<"$EVENT_JSON")

# Build a human-readable description of what's being requested
if [[ "$EVENT_NAME" == "Notification" ]]; then
    # Pull the last few user/assistant text bodies from the transcript so the
    # phone page shows what Claude was just doing, not just the bare alert.
    CONTEXT_TAIL=""
    if [[ -n "$TRANSCRIPT_PATH" && -r "$TRANSCRIPT_PATH" ]]; then
        CONTEXT_TAIL=$(python3 "$HOME/.claude/hooks/page-extract-context.py" "$TRANSCRIPT_PATH" 2>/dev/null)
    fi
    if [[ -n "$CONTEXT_TAIL" ]]; then
        SUMMARY="$NOTIFICATION_MSG

— recent activity —
$CONTEXT_TAIL"
    else
        SUMMARY="$NOTIFICATION_MSG"
    fi
    KIND="question"
else
    # PreToolUse fallback — describe the tool being requested.
    SUMMARY=$(jq -r '
        .tool_input as $i |
        if .tool_name == "Bash" then
            "$ " + ($i.command // "")
        elif .tool_name == "Edit" or .tool_name == "MultiEdit" then
            "Edit " + ($i.file_path // "(unknown file)")
        elif .tool_name == "Write" then
            "Write " + ($i.file_path // "(unknown file)")
        else
            .tool_name + ": " + (($i | tostring) | .[0:120])
        end
    ' <<<"$EVENT_JSON" | head -c 300)
    KIND="permission"
fi

# Read relay token. Primary location is the file written by ClaudePowerMode;
# Keychain is the legacy fallback for older installs.
TOKEN_FILE="$HOME/Library/Application Support/ClaudePowerMode/relay_token.txt"
if [[ -r "$TOKEN_FILE" ]]; then
    TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
else
    TOKEN=$(security find-generic-password -s "local.ClaudePowerMode.relayToken" -a "default" -w 2>/dev/null)
fi
if [[ -z "$TOKEN" ]]; then
    decide "allow" "Page relay token not found — falling through"
fi

ID="hook-${SESSION_ID:0:8}-$(date +%s)-$$"

PAYLOAD=$(jq -nc \
    --arg id "$ID" \
    --arg sid "$SESSION_ID" \
    --arg cwd "$CWD" \
    --arg proj "$PROJECT" \
    --arg ctx "$SUMMARY" \
    --arg kind "$KIND" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
        type: "intervention.opened",
        payload: {
            id: $id, sessionId: $sid, cwd: $cwd, projectName: $proj,
            kind: $kind, openedAt: $now, context: $ctx
        }
    }')

# POST the intervention. If the relay is unreachable, fall through to allow
# so we don't break the user's workflow.
HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$RELAY_URL/intervention" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: page-hook/1.0" \
    --max-time 10 \
    -d "$PAYLOAD" 2>/dev/null || echo "000")
log "POST /intervention id=$ID http_code=$HTTP_CODE"

if [[ "$HTTP_CODE" != "200" ]]; then
    decide "allow" "Page relay unreachable (HTTP $HTTP_CODE) — falling through"
fi

log "waiting for reply (timeout=${TIMEOUT_SECONDS}s)"

# Poll for reply
START=$(date +%s)
while true; do
    ELAPSED=$(($(date +%s) - START))
    if (( ELAPSED >= TIMEOUT_SECONDS )); then
        # Close the intervention to keep the inbox tidy.
        curl -sS -X POST "$RELAY_URL/intervention" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            --max-time 5 \
            -d "{\"type\":\"intervention.closed\",\"payload\":{\"id\":\"$ID\",\"reason\":\"timeout\"}}" >/dev/null 2>&1
        decide "deny" "No reply from phone within ${TIMEOUT_SECONDS}s — denying"
    fi

    REPLY_ACTION=$(curl -sS \
        -H "Authorization: Bearer $TOKEN" \
        --max-time 5 \
        "$RELAY_URL/interventions" 2>/dev/null \
        | jq -r --arg id "$ID" '.[] | select(.id == $id) | .repliedAction // empty')

    if [[ -n "$REPLY_ACTION" && "$REPLY_ACTION" != "null" ]]; then
        # Close it so it doesn't linger in the inbox
        curl -sS -X POST "$RELAY_URL/intervention" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            --max-time 5 \
            -d "{\"type\":\"intervention.closed\",\"payload\":{\"id\":\"$ID\",\"reason\":\"replied\"}}" >/dev/null 2>&1

        case "$REPLY_ACTION" in
            approve|carry_on|custom)
                decide "allow" "Approved via Page (${REPLY_ACTION})" ;;
            deny)
                decide "deny" "Denied via Page" ;;
            *)
                decide "allow" "Unknown action '$REPLY_ACTION' — defaulting allow" ;;
        esac
    fi

    sleep $POLL_INTERVAL
done
