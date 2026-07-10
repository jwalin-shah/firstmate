#!/usr/bin/env bash
# fm-kqueue-watch.sh - Block on state/events.jsonl writes via the
# fm-kqueue-watch Go helper.
#
# Usage: fm-kqueue-watch.sh [<poll>]
#   <poll>  max seconds to wait before timing out (default: block indefinitely).
#           The kqueue binary exits after timeout without printing anything,
#           and this script exits 2.
#
# Exits 0 when new data is written to events.jsonl.
# Exits 2 on timeout with no new data.
# Used by bin/fm-watch.sh when FM_WATCH_MODE=kqueue.
#
# Environment:
#   FM_STATE_OVERRIDE  state directory (default: $FM_HOME/state)
#   FM_KQUEUE_POLL     polling fallback interval in seconds (default: 5)
#                      Used when the kqueue binary is unavailable.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
EVENTS_FILE="$STATE/events.jsonl"
POLL_FALLBACK="${FM_KQUEUE_POLL:-5}"

# Optional argument: timeout in seconds.
TIMEOUT=${1:-0}

# Find fm-kqueue-watch binary.
find_kq_bin() {
  local candidate
  candidate="$SCRIPT_DIR/fm-kqueue-watch"
  [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  candidate=$(command -v fm-kqueue-watch 2>/dev/null || true)
  [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  return 1
}

kq_bin=$(find_kq_bin 2>/dev/null || true)

if [ -n "$kq_bin" ]; then
  # kqueue mode: block on NOTE_WRITE with optional timeout.
  if [ "$TIMEOUT" -gt 0 ] 2>/dev/null; then
    "$kq_bin" -t "$TIMEOUT" "$EVENTS_FILE" 2>/dev/null
    rc=$?
  else
    "$kq_bin" "$EVENTS_FILE" 2>/dev/null
    rc=$?
  fi
  # If the events file doesn't exist yet, retry.
  if [ "$rc" -eq 1 ] && [ ! -e "$EVENTS_FILE" ]; then
    sleep "$POLL_FALLBACK"
    if [ "$TIMEOUT" -gt 0 ] 2>/dev/null; then
      "$kq_bin" -t "$TIMEOUT" "$EVENTS_FILE" 2>/dev/null; rc=$?
    else
      "$kq_bin" "$EVENTS_FILE" 2>/dev/null; rc=$?
    fi
  fi
  exit "$rc"
else
  # Fallback: poll the events.jsonl file mtime.
  last_mtime=0
  elapsed=0
  if [ -e "$EVENTS_FILE" ]; then
    if [ "$(uname)" = Darwin ]; then
      last_mtime=$(stat -f %m "$EVENTS_FILE" 2>/dev/null || echo 0)
    else
      last_mtime=$(stat -c %Y "$EVENTS_FILE" 2>/dev/null || echo 0)
    fi
  fi
  while :; do
    sleep "$POLL_FALLBACK"
    elapsed=$((elapsed + POLL_FALLBACK))
    if [ -e "$EVENTS_FILE" ]; then
      if [ "$(uname)" = Darwin ]; then
        cur=$(stat -f %m "$EVENTS_FILE" 2>/dev/null || echo 0)
      else
        cur=$(stat -c %Y "$EVENTS_FILE" 2>/dev/null || echo 0)
      fi
      if [ "$cur" -gt "$last_mtime" ]; then
        exit 0
      fi
    fi
    if [ "$TIMEOUT" -gt 0 ] 2>/dev/null && [ "$elapsed" -ge "$TIMEOUT" ]; then
      exit 2
    fi
  done
fi
