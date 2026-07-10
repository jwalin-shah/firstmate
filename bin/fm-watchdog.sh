#!/usr/bin/env bash
# Firstmate watchdog — independent sentinel that monitors the watcher's liveness
# beacon (state/.last-watcher-beat). Runs as a background loop, checking every
# FM_WATCHDOG_INTERVAL (default 30s). If the beacon is older than
# FM_WATCHDOG_GRACE (default 120s) or missing entirely, writes a check: entry
# to the durable wake queue so firstmate's supervisor is alerted.
#
# Defensive shell: no set -u, every variable uses ${VAR:-default}. The loop
# never exits on its own; it survives missing files, failed source, and failed
# queue writes. SIGTERM/SIGINT trigger a clean exit.
#
# This is the passive counterpart to bin/fm-guard.sh (ad-hoc, called by
# supervision scripts) and bin/fm-watch.sh (active classification loop). The
# watchdog catches a dead watcher even when no other script is running.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "${SCRIPT_DIR:-/tmp}/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${FM_HOME:-/tmp}/state}"
INTERVAL="${FM_WATCHDOG_INTERVAL:-30}"
GRACE="${FM_WATCHDOG_GRACE:-120}"
WAKE_LIB="${SCRIPT_DIR:-/tmp}/fm-wake-lib.sh"

mkdir -p "${STATE:-/tmp}" 2>/dev/null || true

# Portable stat_mtime — same pattern as fm-watch.sh and fm-guard.sh.
# Returns epoch seconds of file mtime, or empty string on failure.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

# Compute seconds since a file's mtime. Returns a large sentinel for a missing
# or unreadable file so the watchdog treats it as stale.
beacon_age() {
  local beacon="${1:-}"
  local m=""
  if [ -z "$beacon" ] || [ ! -e "$beacon" ]; then
    echo 999999
    return 0
  fi
  m=$(stat_mtime "$beacon")
  if [ -z "$m" ]; then
    echo 999999
    return 0
  fi
  echo $(( $(date +%s) - m ))
}

# Source the wake library for fm_wake_append. Best-effort: if the library is
# missing or broken the watchdog keeps running and warns to stderr.
_wake_lib_loaded=0
_load_wake_lib() {
  if [ "${_wake_lib_loaded:-0}" -eq 1 ]; then
    return 0
  fi
  if [ -r "${WAKE_LIB:-}" ]; then
    # shellcheck disable=SC1090
    . "${WAKE_LIB}" 2>/dev/null && _wake_lib_loaded=1 || true
  fi
}

# Clean shutdown on SIGTERM/SIGINT. The loop never exits on its own otherwise.
_exiting=0
trap '_exiting=1' TERM INT

BEACON="${STATE:-/tmp}/.last-watcher-beat"

while [ "${_exiting:-0}" -eq 0 ]; do
  age=$(beacon_age "$BEACON")

  if [ "${age:-0}" -ge "${GRACE:-120}" ]; then
    _load_wake_lib
    if [ "${_wake_lib_loaded:-0}" -eq 1 ]; then
      payload="watchdog: watcher beacon stale for ${age}s (>${GRACE}s)"
      fm_wake_append check watchdog "$payload" 2>/dev/null || {
        printf 'fm-watchdog: failed to append wake entry (beacon age %ss > %ss)\n' "$age" "$GRACE" >&2
      }
    else
      printf 'fm-watchdog: cannot source wake library at %s, beacon age %ss > %ss\n' "${WAKE_LIB:-unknown}" "$age" "$GRACE" >&2
    fi
  fi

  # Sleep in small chunks so the trap is responsive. A plain "sleep $INTERVAL"
  # won't notice SIGTERM until the full interval elapses.
  _remaining="${INTERVAL:-30}"
  while [ "${_remaining:-0}" -gt 0 ] && [ "${_exiting:-0}" -eq 0 ]; do
    _chunk="${_remaining}"
    if [ "${_chunk:-0}" -gt 5 ]; then
      _chunk=5
    fi
    sleep "${_chunk}"
    _remaining=$(( _remaining - _chunk ))
  done
done

exit 0
