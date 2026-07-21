#!/bin/bash
# Kato hook for Claude Code — POSTs Notification/Stop hook events to the
# Kato HookServer at 127.0.0.1:7811.
#
# Install: add this to ~/.claude/settings.json (adjust the path if you move kato):
#
# {
#   "hooks": {
#     "Notification": [
#       { "matcher": "", "hooks": [ { "type": "command", "command": "/Users/jeremy/dev/kato/Scripts/hooks/claude-hook.sh" } ] }
#     ],
#     "Stop": [
#       { "matcher": "", "hooks": [ { "type": "command", "command": "/Users/jeremy/dev/kato/Scripts/hooks/claude-hook.sh" } ] }
#     ]
#   }
# }
#
# Claude Code pipes a JSON payload to stdin, e.g.:
#   {"hook_event_name": "Notification", "cwd": "...", "session_id": "...", "message": "..."}
# Never fail the hook: this script always exits 0.

KATO_URL="${KATO_HOOK_URL:-http://127.0.0.1:7811/event}"
INPUT="$(cat 2>/dev/null || true)"

json_get() {
    # json_get <key> — best-effort extraction from $INPUT via jq or python3.
    local key="$1"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$INPUT" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get(sys.argv[1]) or "")
except Exception:
    pass
' "$key" 2>/dev/null
    fi
}

HOOK_EVENT="$(json_get hook_event_name)"
CWD="$(json_get cwd)"
MESSAGE="$(json_get message)"

case "$HOOK_EVENT" in
    Notification)    KIND="needsInput" ;;
    Stop|SubagentStop) KIND="done" ;;
    *)               KIND="done" ;;
esac

DIR_NAME="$(basename "${CWD:-$PWD}")"
TITLE="claude · ${DIR_NAME}"
DETAIL="${MESSAGE:-$HOOK_EVENT}"
TTY_NAME="$(ps -o tty= -p "${PPID:-0}" 2>/dev/null | tr -d ' ' || true)"

# Deterministic focus: when running inside tmux, capture the exact
# "session:window.pane" so kato can select it server-side. Optional; the
# TTY above is the resolver's fallback. Never fail the hook on tmux errors.
TMUX_TARGET=""
if [ -n "${TMUX:-}" ]; then
    TMUX_BIN=""
    for candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
        if [ -x "$candidate" ]; then TMUX_BIN="$candidate"; break; fi
    done
    [ -n "$TMUX_BIN" ] || TMUX_BIN="$(command -v tmux 2>/dev/null || true)"
    if [ -n "$TMUX_BIN" ]; then
        if [ -n "${TMUX_PANE:-}" ]; then
            TMUX_TARGET="$("$TMUX_BIN" display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)"
        else
            TMUX_TARGET="$("$TMUX_BIN" display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)"
        fi
    fi
fi

if command -v python3 >/dev/null 2>&1; then
    PAYLOAD="$(KATO_KIND="$KIND" KATO_TITLE="$TITLE" KATO_DETAIL="$DETAIL" \
               KATO_CWD="${CWD:-$PWD}" KATO_TTY="$TTY_NAME" KATO_TMUX="$TMUX_TARGET" \
               KATO_PID="${PPID:-}" \
               python3 -c '
import json, os
payload = {
    "kind": os.environ["KATO_KIND"],
    "title": os.environ["KATO_TITLE"],
    "detail": os.environ["KATO_DETAIL"],
    "cwd": os.environ["KATO_CWD"],
    "tty": os.environ["KATO_TTY"],
}
if os.environ.get("KATO_TMUX"):
    payload["tmux"] = os.environ["KATO_TMUX"]
if os.environ.get("KATO_PID"):
    payload["pid"] = int(os.environ["KATO_PID"])
# cmux / herdr auto-set these inside their terminals; forwarding them gives
# kato deterministic focus via each app socket API (no accessibility hacks).
for key, env in (("cmuxWorkspace", "CMUX_WORKSPACE_ID"), ("cmuxSurface", "CMUX_SURFACE_ID"),
                 ("herdrSocket", "HERDR_SOCKET_PATH"), ("herdrWorkspace", "HERDR_WORKSPACE_ID"),
                 ("herdrTab", "HERDR_TAB_ID"), ("herdrPane", "HERDR_PANE_ID")):
    if os.environ.get(env):
        payload[key] = os.environ[env]
print(json.dumps(payload))
' 2>/dev/null)"
else
    PAYLOAD="{\"kind\":\"$KIND\",\"title\":\"$TITLE\",\"detail\":\"$DETAIL\"}"
fi

[ -n "${PAYLOAD:-}" ] || exit 0

curl -sS -m 2 -o /dev/null -X POST "$KATO_URL" \
    -H 'Content-Type: application/json' \
    -d "$PAYLOAD" 2>/dev/null || true
exit 0
