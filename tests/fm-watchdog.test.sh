#!/usr/bin/env bash
# tests/fm-watchdog.test.sh — tests for bin/fm-watchdog.sh
#
# Three core cases:
#   1. Fresh beacon → silent, no wake written
#   2. Stale beacon → check: entry written to wake queue
#   3. Missing beacon → treated as stale, check: entry written
#   4. (bonus) Loop survives missing wake library
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCHDOG="$ROOT/bin/fm-watchdog.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-watchdog-tests)

# Run the watchdog for up to N seconds, capturing stdout and stderr, then kill
# it. Returns the watchdog's combined output. Uses a temp file because the
# background process output would otherwise be lost.
run_watchdog_cycle() {
  local state=$1 timeout_secs=${2:-10} out
  out=$(mktemp "${TMPDIR:-/tmp}/fm-watchdog-out.XXXXXX")
  FM_STATE_OVERRIDE="$state" "$WATCHDOG" >"$out" 2>&1 &
  local pid=$!
  # Wait for the watchdog to complete at least one check cycle. The watchdog
  # sleeps in 5s chunks, so 8s is enough for one full cycle with FM_WATCHDOG_INTERVAL=2.
  sleep "$timeout_secs"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  cat "$out" 2>/dev/null
  rm -f "$out" 2>/dev/null
}

# Read and drain the wake queue, returning its content.
drain_queue() {
  local state=$1 queue="$state/.wake-queue"
  if [ -e "$queue" ]; then
    cat "$queue" 2>/dev/null
    : > "$queue"
  fi
}

# ---------------------------------------------------------------------------
# Case 1: Fresh beacon — watchdog runs silently, no wake enqueued
# ---------------------------------------------------------------------------
test_fresh_beacon_silent() {
  local dir state out queue_out
  dir="$TMP_ROOT/fresh-beacon"
  state="$dir/state"
  mkdir -p "$state"

  # Touch a fresh beacon and an empty wake queue so fm_wake_append doesn't
  # fail on a missing queue file's lock dir.
  touch "$state/.last-watcher-beat"
  : > "$state/.wake-queue"

  # Run one cycle with a short interval
  out=$(run_watchdog_cycle "$state" 6)
  queue_out=$(drain_queue "$state")

  # The watchdog should produce no stdout (it only writes to stderr on errors)
  assert_not_contains "$out" "watchdog:" "fresh beacon should not trigger warning"
  # No check entry in the wake queue
  assert_not_contains "$queue_out" "watchdog" "fresh beacon should not enqueue a wake"
  pass "fresh beacon: watchdog stays silent, no wake enqueued"
}

# ---------------------------------------------------------------------------
# Case 2: Stale beacon — watchdog writes a check: entry to the wake queue
# ---------------------------------------------------------------------------
test_stale_beacon_writes_wake() {
  local dir state out queue_out
  dir="$TMP_ROOT/stale-beacon"
  state="$dir/state"
  mkdir -p "$state"

  # Create a beacon with an old mtime using touch -t (portable).
  # The beacon must be older than FM_WATCHDOG_GRACE (default 120s).
  touch -t 202001010000 "$state/.last-watcher-beat"
  : > "$state/.wake-queue"

  # Run with a low grace so we don't need to wait 120+ seconds
  out=$(FM_WATCHDOG_GRACE=1 run_watchdog_cycle "$state" 6)
  queue_out=$(drain_queue "$state")

  # The wake queue should contain a check entry with key "watchdog"
  assert_contains "$queue_out" "check" "stale beacon should write a check wake entry"
  assert_contains "$queue_out" "watchdog" "check entry should have key=watchdog"
  assert_contains "$queue_out" "watcher beacon stale" "check entry should describe the stale beacon"
  pass "stale beacon: check wake entry enqueued"
}

# ---------------------------------------------------------------------------
# Case 3: Missing beacon — treated as stale, wake entry written
# ---------------------------------------------------------------------------
test_missing_beacon_triggers() {
  local dir state out queue_out
  dir="$TMP_ROOT/missing-beacon"
  state="$dir/state"
  mkdir -p "$state"

  # No .last-watcher-beat file at all
  : > "$state/.wake-queue"

  out=$(FM_WATCHDOG_GRACE=1 run_watchdog_cycle "$state" 6)
  queue_out=$(drain_queue "$state")

  assert_contains "$queue_out" "check" "missing beacon should write a check wake entry"
  assert_contains "$queue_out" "watchdog" "missing beacon check entry should have key=watchdog"
  pass "missing beacon: treated as stale, check wake enqueued"
}

# ---------------------------------------------------------------------------
# Case 4: Missing wake library — watchdog survives, warns to stderr
# ---------------------------------------------------------------------------
test_missing_wake_library_survives() {
  local dir state out fakebin bin_dir watchdog_copy
  dir="$TMP_ROOT/missing-lib"
  state="$dir/state"
  fakebin="$dir/fakebin"
  bin_dir="$dir/bin"
  mkdir -p "$state" "$fakebin" "$bin_dir"

  touch -t 202001010000 "$state/.last-watcher-beat"
  : > "$state/.wake-queue"

  # Copy the watchdog into a bin/ dir that does NOT contain fm-wake-lib.sh,
  # so SCRIPT_DIR resolves to that dir and the library source fails.
  watchdog_copy="$bin_dir/fm-watchdog.sh"
  cp "$WATCHDOG" "$watchdog_copy"
  chmod +x "$watchdog_copy"

  out=$(FM_STATE_OVERRIDE="$state" FM_WATCHDOG_GRACE=1 FM_WATCHDOG_INTERVAL=2 \
    "$watchdog_copy" 2>&1 &
    pid=$!
    sleep 5
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  )

  # The watchdog should warn that it cannot source the library
  assert_contains "$out" "cannot source wake library" "missing wake library should produce stderr warning"
  pass "missing wake library: watchdog survives and warns"
}

test_fresh_beacon_silent
test_stale_beacon_writes_wake
test_missing_beacon_triggers
test_missing_wake_library_survives
