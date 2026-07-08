#!/usr/bin/env bash
# fm-events.sh -- Append a firstmate crew event to the shared events.jsonl bus.
# Writes in the same Event schema as jw-sessiond so all consumers (jw-sentry,
# jw-tui) can read firstmate events without format translation.
#
# Usage: fm-events.sh crew_spawned <task-id> <project> [extra-json-pairs...]
#        fm-events.sh crew_state   <task-id> <verb> <note>
#        fm-events.sh crew_torn_down <task-id> <project>
#
# Each call appends one JSON line to ~/.local/share/jw/events.jsonl.
# Schema fields:
#   ts       -- RFC 3339 timestamp (auto-generated)
#   source   -- "firstmate"
#   event    -- "crew_spawned" | "crew_state" | "crew_torn_down"
#   thread_id -- task id
#   project  -- project name
#   status   -- state verb (working/done/blocked/failed/needs-decision)
#   text     -- human-readable note
set -eu

EVENTS_FILE="${HOME}/.local/share/jw/events.jsonl"
EVENT=${1:-}
THREAD_ID=${2:-}

[ -n "$EVENT" ] || { echo "usage: fm-events.sh <event> <task-id> [args...]" >&2; exit 2; }
[ -n "$THREAD_ID" ] || { echo "usage: fm-events.sh <event> <task-id> [args...]" >&2; exit 2; }

shift 2

# Build JSON payload from positional args and any extra key=value pairs.
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if command -v python3 >/dev/null 2>&1; then
  python3 -c "
import json, sys, os
ts = os.environ.get('FM_EVENT_TS', '')
tid = os.environ.get('FM_EVENT_THREAD_ID', '')
evt = os.environ.get('FM_EVENT_TYPE', '')
args = sys.argv[1:]

obj = {'ts': ts, 'source': 'firstmate', 'event': evt, 'thread_id': tid}

i = 0
for a in args:
    i += 1
    if i == 1 and evt in ('crew_spawned', 'crew_torn_down'):
        obj['project'] = a
    elif i == 1 and evt == 'crew_state':
        obj['status'] = a
    elif i == 2 and evt == 'crew_state':
        obj['text'] = a
    elif '=' in a:
        k, v = a.split('=', 1)
        obj[k] = v
    else:
        # positional overflow: store as fields
        if 'text' not in obj:
            obj['text'] = a
        elif 'note' not in obj:
            obj['note'] = a

print(json.dumps(obj, separators=(',', ':')))
" "$@"
else
  # Degraded fallback: minimal valid JSON
  printf '{"ts":"%s","source":"firstmate","event":"%s","thread_id":"%s"}\n' \
    "$TS" "$EVENT" "$THREAD_ID"
fi >> "$EVENTS_FILE"
