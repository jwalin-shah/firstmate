#!/usr/bin/env bash
# Watcher liveness guard, called at the top of the supervision scripts.
# If any task is in flight (a state/<id>.meta exists) and the watcher's
# liveness beacon (state/.last-watcher-beat, touched every poll cycle) is
# missing or older than FM_GUARD_GRACE seconds, prints a loud warning so the
# agent sees it in the tool output of whatever it was doing - the one channel
# every harness has. Normal wake handling (watcher briefly down between a wake
# and its restart) stays inside the grace window and stays silent.
# Always exits 0: the guard warns, it never blocks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_ROOT/state}"
GRACE=${FM_GUARD_GRACE:-300}
SPAWN_GRACE=${FM_SPAWN_GUARD_GRACE:-120}
queue_pending=false

# --spawn-block turns this into a hard gate (used by fm-spawn.sh): instead of
# warning and exiting 0, it exits non-zero when the watcher beacon is stale, so a
# spawn fails fast rather than launching an unsupervised crewmate. Default
# (no flag) behavior is unchanged - warn only, always exit 0.
spawn_block=false
for arg in "$@"; do
  case "$arg" in
    --spawn-block) spawn_block=true ;;
  esac
done

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# Portable mtime; see fm-watch.sh for why the `stat -f || stat -c` fallback breaks on Linux.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

# Spawn gate: a hard, fail-fast check keyed solely on the watcher beacon.
# Missing beacon -> proceed (first launch, no watcher expected yet). Fresh beacon
# (<= SPAWN_GRACE) -> proceed. Stale beacon -> exit non-zero so the spawn aborts
# rather than launching a crewmate no watcher will supervise.
if "$spawn_block"; then
  BEAT="$STATE/.last-watcher-beat"
  [ -e "$BEAT" ] || exit 0
  m=$(stat_mtime "$BEAT") || exit 0
  age=$(( $(date +%s) - m ))
  if [ "$age" -ge "$SPAWN_GRACE" ]; then
    echo "ERROR: refusing to spawn - no watcher has been alive for ${age}s (>${SPAWN_GRACE}s)." >&2
    echo "Restart it first (run bin/fm-watch.sh as a background task), or set FM_SKIP_WATCHER_CHECK=1 to bypass." >&2
    exit 1
  fi
  exit 0
fi

has_meta=false
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  has_meta=true
  break
done
"$has_meta" || exit 0

if [ -s "$FM_WAKE_QUEUE" ]; then
  queue_pending=true
  echo "WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else." >&2
fi

BEAT="$STATE/.last-watcher-beat"
if [ -e "$BEAT" ]; then
  m=$(stat_mtime "$BEAT") || exit 0
  age=$(( $(date +%s) - m ))
  [ "$age" -lt "$GRACE" ] && exit 0
  echo "WARNING: tasks are in flight but no watcher has been alive for ${age}s (>${GRACE}s)." >&2
else
  echo "WARNING: tasks are in flight but no watcher has ever run (no liveness beacon)." >&2
fi
if "$queue_pending"; then
  echo "After draining queued wakes, re-arm the watcher: run bin/fm-watch.sh as a background task." >&2
else
  echo "Restart it NOW, before anything else: run bin/fm-watch.sh as a background task." >&2
fi
exit 0
