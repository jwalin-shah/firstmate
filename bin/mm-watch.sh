#!/usr/bin/env bash
# mm-watch.sh - Daemon that subscribes to mintmux pane state changes via
# mm-event-sub (a Go helper) and writes structured JSON events to
# state/events.jsonl.
#
# Architecture:
#   mm-event-sub connects to the mintmux Unix socket, subscribes to pane
#   events for firstmate task sessions, and writes one JSONL line per event
#   to stdout.  mm-watch.sh captures that stdout into state/events.jsonl so
#   the kqueue-mode watcher (bin/fm-kqueue-watch.sh) can block on it
#   instead of polling.
#
# The daemon auto-restarts mm-event-sub if it dies, up to 3 times before
# giving up, with exponential backoff (1s, 2s, 4s).
#
# Environment:
#   FM_STATE_OVERRIDE  state directory (default: $FM_HOME/state)
#   MM_SOCK            mintmux Unix socket path (default: auto-detect)
#   MM_SESSION         session filter (optional)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
EVENTS_FILE="$STATE/events.jsonl"
EVENTS_PID_FILE="$STATE/.mm-event-sub.pid"
MAX_BACKOFF_RESTARTS=3

mkdir -p "$STATE"

# Find mm-event-sub binary - look next to this script, then in PATH.
find_event_sub() {
  local candidate
  candidate="$SCRIPT_DIR/mm-event-sub"
  [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  candidate=$(command -v mm-event-sub 2>/dev/null || true)
  [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  return 1
}

# shellcheck disable=SC2329 # invoked by trap
cleanup() {
  local pid
  if [ -e "$EVENTS_PID_FILE" ]; then
    pid=$(cat "$EVENTS_PID_FILE" 2>/dev/null || true)
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$EVENTS_PID_FILE"
  fi
}

trap cleanup EXIT INT TERM HUP

ev_sub=$(find_event_sub) || {
  echo "mm-watch: mm-event-sub binary not found" >&2
  exit 1
}

# Start mm-event-sub, capturing stdout to events.jsonl.
backoff=1
restarts=0
while [ "$restarts" -le "$MAX_BACKOFF_RESTARTS" ]; do
  # Build env for the sub-process.
  MM_SOCK="${MM_SOCK:-}" MM_SESSION="${MM_SESSION:-}" \
    "$ev_sub" >> "$EVENTS_FILE" 2>>"$STATE/.mm-event-sub.log" &
  child_pid=$!
  printf '%s\n' "$child_pid" > "$EVENTS_PID_FILE"
  wait "$child_pid"
  rc=$?

  # Clean exit via signal means the daemon should stop.
  if [ "$rc" -ge 128 ] && [ "$rc" -le 160 ]; then
    exit 0
  fi

  restarts=$((restarts + 1))
  if [ "$restarts" -le "$MAX_BACKOFF_RESTARTS" ]; then
    sleep "$backoff"
    backoff=$((backoff * 2))
  fi
done

echo "mm-watch: mm-event-sub exited $rc times, giving up" >&2
exit 1
