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

if command -v python3 >/dev/null 2>&1; then
    PAYLOAD="$(KATO_KIND="$KIND" KATO_TITLE="$TITLE" KATO_DETAIL="$DETAIL" \
               KATO_CWD="$PWD" \
               python3 -c '
import json, os
print(json.dumps({
    "kind": os.environ["KATO_KIND"],
    "title": os.environ["KATO_TITLE"],
    "detail": os.environ["KATO_DETAIL"],
    "cwd": os.environ["KATO_CWD"],
}))
' 2>/dev/null)"
else
    PAYLOAD="{\"kind\":\"$KIND\",\"title\":\"$TITLE\",\"detail\":\"$DETAIL\"}"
fi

[ -n "${PAYLOAD:-}" ] || exit 0

curl -sS -m 2 -o /dev/null -X POST "$KATO_URL" \
    -H 'Content-Type: application/json' \
    -d "$PAYLOAD" 2>/dev/null || true
exit 0
