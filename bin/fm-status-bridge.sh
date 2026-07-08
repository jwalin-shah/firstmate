#!/usr/bin/env bash
# fm-status-bridge.sh -- Watch firstmate state/ for crew status changes and emit
# crew_state events to events.jsonl in real-time.
#
# When a crewmate appends to state/<id>.status, this bridge:
#   1. Reads the last line of the status file
#   2. Extracts the verb (done/blocked/failed/needs-decision/working)
#   3. Emits a crew_state event to events.jsonl
#   4. On terminal states (done/blocked/failed/needs-decision), touches
#      state/<id>.turn-ended for instant firstmate wake
#
# Uses fswatch for event-driven watching (no polling, near-instant).
# Designed to run under launchd as a LaunchAgent.
#
# Usage: fm-status-bridge.sh [--foreground]
#   --foreground   Run in foreground (for launchd); default is to daemonize.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${FM_STATE_OVERRIDE:-${FM_HOME:-$HOME/projects/firstmate}/state}"
EVENTS_FILE="$HOME/.local/share/jw/events.jsonl"
LOCKFILE="$STATE_DIR/.fm-status-bridge.lock"
PIDFILE="$STATE_DIR/.fm-status-bridge.pid"

FOREGROUND=0
case "${1:-}" in
  --foreground|-f) FOREGROUND=1 ;;
esac

if [ "$FOREGROUND" != 1 ]; then
  # Ensure singleton.
  if [ -f "$PIDFILE" ]; then
    old_pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      echo "fm-status-bridge already running (pid $old_pid)" >&2
      exit 0
    fi
  fi
  echo $$ > "$PIDFILE"
  # Daemonize
  exec "$0" --foreground </dev/null >>/dev/null 2>&1 &
  disown
  exit 0
fi

# In foreground mode.
mkdir -p "$STATE_DIR"

emit_event() {
  local task_id=$1 verb=$2 note=$3
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json
obj = {'ts': '$ts', 'source': 'firstmate', 'event': 'crew_state',
       'thread_id': '$task_id', 'status': '$verb', 'text': '''$note'''}
print(json.dumps(obj, separators=(',', ':')))
" >> "$EVENTS_FILE" 2>/dev/null
  fi
}

process_status_file() {
  local status_file=$1
  local task_id
  task_id=$(basename "$status_file" .status)
  [ -z "$task_id" ] && return
  [ ! -f "$status_file" ] && return

  # Read last non-empty line.
  local line verb note
  line=$(grep -v '^[[:space:]]*$' "$status_file" 2>/dev/null | tail -1)
  [ -z "$line" ] && return

  # Extract verb (word before the colon).
  verb=${line%%:*}
  verb="${verb#"${verb%%[![:space:]]*}"}"
  verb="${verb%"${verb##*[![:space:]]}"}"
  [ -z "$verb" ] && return

  # Extract note (everything after the colon).
  case "$line" in
    *:*) note=${line#*:}; note="${note#"${note%%[![:space:]]*}"}" ;;
    *) note="" ;;
  esac

  # Emit crew_state to events.jsonl.
  emit_event "$task_id" "$verb" "$note"

  # On terminal states, touch turn-ended for instant firstmate wake.
  case "$verb" in
    done|blocked|failed|needs-decision)
      local turnend="$STATE_DIR/$task_id.turn-ended"
      touch "$turnend" 2>/dev/null || true
      ;;
  esac
}

# Process existing status files on startup.
for f in "$STATE_DIR"/*.status; do
  [ -f "$f" ] || continue
  process_status_file "$f"
done

# Watch for changes using fswatch.
if command -v fswatch >/dev/null 2>&1; then
  fswatch -0 --event Updated --event Created "$STATE_DIR" 2>/dev/null | while IFS= read -r -d '' path; do
    case "$path" in
      *.status) process_status_file "$path" ;;
    esac
  done
else
  # Fallback: lightweight polling (2s interval).
  while true; do
    for f in "$STATE_DIR"/*.status; do
      [ -f "$f" ] || continue
      _marker="$STATE_DIR/.bridge-last-$(basename "$f" .status)"
      _current_mtime=$(stat -f %m "$f" 2>/dev/null || echo 0)
      _last_mtime=$(cat "$_marker" 2>/dev/null || echo 0)
      if [ "$_current_mtime" != "$_last_mtime" ]; then
        process_status_file "$f"
        echo "$_current_mtime" > "$_marker"
      fi
    done
    sleep 2
  done
fi
