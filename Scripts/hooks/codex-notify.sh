#!/bin/bash
# Kato notify hook for Codex CLI — POSTs turn-completion events to the
# Kato HookServer at 127.0.0.1:7811.
#
# Install: add this to ~/.codex/config.toml (adjust the path if you move kato):
#
#   notify = ["/Users/jeremy/dev/kato/Scripts/hooks/codex-notify.sh"]
#
# Codex invokes the program with a single JSON argument, e.g.:
#   {"type": "agent-turn-complete", "turn-id": "...",
#    "input-messages": ["..."], "last-assistant-message": "..."}
# Never fail the hook: this script always exits 0.

KATO_URL="${KATO_HOOK_URL:-http://127.0.0.1:7811/event}"
INPUT="${!#}"   # last argument
[ -n "$INPUT" ] || exit 0

if command -v python3 >/dev/null 2>&1; then
    read -r TYPE MESSAGE <<EOF
$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("type", ""))
    print(d.get("last-assistant-message", "")[:200].replace("\n", " "))
except Exception:
    print("")
    print("")
' 2>/dev/null)
EOF
fi

case "${TYPE:-}" in
    agent-turn-complete) KIND="done" ;;
    "")                  KIND="done" ;;
    *)                   KIND="needsInput" ;;
esac

DIR_NAME="$(basename "$PWD")"
TITLE="codex · ${DIR_NAME}"
DETAIL="${MESSAGE:-turn complete}"
TTY_NAME="$(ps -o tty= -p "${PPID:-0}" 2>/dev/null | tr -d ' ' || true)"

# Deterministic focus: capture the tmux "session:window.pane" when the
# agent runs inside tmux (TTY above is the resolver's fallback).
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
               KATO_CWD="$PWD" KATO_TTY="$TTY_NAME" KATO_TMUX="$TMUX_TARGET" \
               python3 -c '
import json, os
payload = {
    "kind": os.environ["KATO_KIND"],
    "title": os.environ["KATO_TITLE"],
    "detail": os.environ["KATO_DETAIL"],
    "cwd": os.environ["KATO_CWD"],
}
if os.environ.get("KATO_TTY"):
    payload["tty"] = os.environ["KATO_TTY"]
if os.environ.get("KATO_TMUX"):
    payload["tmux"] = os.environ["KATO_TMUX"]
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
