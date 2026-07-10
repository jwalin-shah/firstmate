#!/usr/bin/env bash
# Enforce pipeline stage reporting by crewmates.
# Detects when a crewmate has stopped reporting stage progress (working: lines
# in its status file) and escalates: nudge first via fm-send.sh, then kill via
# fm-backend.sh if still unresponsive.
#
# Called periodically (from fm-watch.sh's poll loop via a check script, or
# standalone). Idempotent: tracks nudge/kill state so each action fires once.
#
# Usage: fm-stage-enforce.sh <id>
#
# Config:
#   FM_STAGE_NUDGE_MINUTES  minutes of no stage change before nudging (default 5)
#   FM_STAGE_KILL_MINUTES   minutes of no stage change before killing (default 15)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

# Resolve fm-send.sh path. Overridable for testing.
FM_SEND_BIN="${FM_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-stage-enforce.sh <id>" >&2; exit 2; }

NUDGE_MINUTES=${FM_STAGE_NUDGE_MINUTES:-5}
KILL_MINUTES=${FM_STAGE_KILL_MINUTES:-15}

# Validate config: must be positive integers.
case "$NUDGE_MINUTES" in
  ''|*[!0-9]*) NUDGE_MINUTES=5 ;;
esac
[ "$NUDGE_MINUTES" -gt 0 ] 2>/dev/null || NUDGE_MINUTES=5

case "$KILL_MINUTES" in
  ''|*[!0-9]*) KILL_MINUTES=15 ;;
esac
[ "$KILL_MINUTES" -gt 0 ] 2>/dev/null || KILL_MINUTES=15

# Kill must be >= nudge (otherwise we'd kill before nudging).
if [ "$KILL_MINUTES" -lt "$NUDGE_MINUTES" ]; then
  KILL_MINUTES=$NUDGE_MINUTES
fi

META="$STATE/$ID.meta"
STATUS_FILE="$STATE/$ID.status"
ENFORCE_FILE="$STATE/.stage-enforce-$ID"

# Not a managed task: nothing to enforce.
[ -f "$META" ] || exit 0

# Secondmates idle by design — skip enforcement.
KIND=$(fm_meta_get "$META" kind)
[ "$KIND" != secondmate ] || exit 0

now=$(date +%s)

# --- read last working: line from status --------------------------------------

last_stage=""
if [ -f "$STATUS_FILE" ]; then
  last_stage=$(grep '^working:' "$STATUS_FILE" 2>/dev/null | tail -1 || true)
fi

# --- read persistent enforcement state ----------------------------------------

prev_stage=""
first_seen_epoch=0
enforce_state=tracking
nudge_epoch=0

if [ -f "$ENFORCE_FILE" ]; then
  IFS=$(printf '\t') read -r prev_stage first_seen_epoch enforce_state nudge_epoch < "$ENFORCE_FILE" 2>/dev/null || true
  case "$first_seen_epoch" in
    ''|*[!0-9]*) first_seen_epoch=0 ;;
  esac
  case "$nudge_epoch" in
    ''|*[!0-9]*) nudge_epoch=0 ;;
  esac
  case "$enforce_state" in
    tracking|nudged|killed) ;;
    *) enforce_state=tracking ;;
  esac
fi

# --- new stage detected → reset timer -----------------------------------------

if [ "$last_stage" != "$prev_stage" ]; then
  printf '%s\t%s\t%s\t%s\n' "$last_stage" "$now" "tracking" "0" > "$ENFORCE_FILE"
  exit 0
fi

# Same stage; compute elapsed.
# A first_seen_epoch of 0 means uninitialized — treat as just now.
if [ "$first_seen_epoch" -eq 0 ] 2>/dev/null; then
  first_seen_epoch=$now
  printf '%s\t%s\t%s\t%s\n' "$last_stage" "$now" "$enforce_state" "$nudge_epoch" > "$ENFORCE_FILE"
fi
elapsed=$(( now - first_seen_epoch ))
[ "$elapsed" -lt 0 ] 2>/dev/null && elapsed=0

# --- already killed → silent --------------------------------------------------

if [ "$enforce_state" = killed ]; then
  exit 0
fi

# --- kill threshold reached ---------------------------------------------------
# Only kill after a nudge has been sent (state = nudged). If the kill threshold
# is reached but we haven't nudged yet (state = tracking), fall through to the
# nudge path below — never kill without nudging first.

if [ "$elapsed" -ge $(( KILL_MINUTES * 60 )) ] && [ "$enforce_state" = nudged ]; then
  minutes=$(( elapsed / 60 ))
  backend=$(fm_backend_of_meta "$META")
  target=$(fm_backend_target_of_meta "$META")

  # Kill the runtime endpoint.
  if [ -n "$target" ]; then
    fm_backend_kill "$backend" "$target" 2>/dev/null || true
  fi

  # Mark as failed.
  printf 'failed: unresponsive - no stage progress for %s minutes\n' "$minutes" >> "$STATUS_FILE"

  # Record killed state.
  printf '%s\t%s\t%s\t%s\n' "$last_stage" "$first_seen_epoch" "killed" "$nudge_epoch" > "$ENFORCE_FILE"

  printf 'kill: %s unresponsive for %sm\n' "$ID" "$minutes"
  exit 0
fi

# --- nudge threshold reached --------------------------------------------------

if [ "$elapsed" -ge $(( NUDGE_MINUTES * 60 )) ] && [ "$enforce_state" = tracking ]; then
  minutes=$(( elapsed / 60 ))
  stage_desc="${last_stage#working: }"
  stage_desc="${stage_desc#"${stage_desc%%[![:space:]]*}"}"  # trim leading whitespace
  [ -n "$stage_desc" ] || stage_desc="no stages reported"

  nudge_msg="Stage progress check: you last reported \"${stage_desc}\" ${minutes} minutes ago. Are you still making progress? Please report your current stage."

  # Send nudge via fm-send.sh. Best-effort: a send failure does not block
  # enforcement — the kill threshold still fires on the next cycle.
  "$FM_SEND_BIN" "fm-$ID" "$nudge_msg" 2>/dev/null || true

  # Record nudged state.
  printf '%s\t%s\t%s\t%s\n' "$last_stage" "$first_seen_epoch" "nudged" "$now" > "$ENFORCE_FILE"

  printf 'nudge: %s %s stalled for %sm\n' "$ID" "$stage_desc" "$minutes"
  exit 0
fi

# --- within thresholds, nothing to do -----------------------------------------

exit 0
