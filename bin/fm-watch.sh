#!/usr/bin/env bash
# Firstmate watcher.
# Blocks until supervision work is due, then exits printing one reason line:
#   signal: <file>...     a crewmate wrote a status line or a turn-end hook fired; signals
#                         landing within FM_SIGNAL_GRACE of each other coalesce into one wake
#   stale: <window>       a crewmate pane stopped changing and shows no busy signature
#   check: <script>: <out> a per-task check script (e.g. merged-PR poll) produced output
#   heartbeat              fleet review due; starts at FM_HEARTBEAT and backs off to FM_HEARTBEAT_MAX
# Run as a background task. Re-arm it after handling each wake; duplicate
# invocations no-op through the watcher singleton lock.
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$FM_ROOT/bin/fm-init.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
trap 'fm_lock_release "$WATCH_LOCK"' EXIT

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat wakes
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
# Transcript summarizer: run fm-transcript-summarizer.py every N seconds in the
# background. Default 300s (5 min). Set FM_SUMMARIZER_INTERVAL=0 to disable.
SUMMARIZER_INTERVAL=${FM_SUMMARIZER_INTERVAL:-300}
SUMMARIZER_BATCH=${FM_SUMMARIZER_BATCH:-20}
SUMMARIZER_BIN="$FM_ROOT/bin/fm-transcript-summarizer.py"
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working..."
BUSY_REGEX=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.'}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# Exit reporting a wake. Consecutive heartbeats with no other wake in between
# mean an idle fleet, so the heartbeat interval backs off exponentially
# (base * 2^streak, capped at HEARTBEAT_MAX); any real wake resets the cadence.
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  exit 0
}

# Check and heartbeat cadence must survive restarts: the watcher exits on every
# wake and is relaunched, so in-memory counters never reach their threshold on
# a busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

# Prune stale wake entries (older than FM_WAKE_TTL) accumulated across sessions
# before entering the main loop, so the queue never grows unbounded.
pruned_wakes=$(fm_wake_prune_ttl)
if [ "${pruned_wakes:-0}" -gt 0 ]; then
  echo "pruned $pruned_wakes stale wake entries" >&2
fi

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file; .seen-* is updated only when a wake is reported, so
# a watcher killed mid-cycle never swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

run_check() {
  local c=$1
  if command -v timeout >/dev/null 2>&1; then
    timeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  fi
}

while :; do
  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      out=$(run_check "$c")
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # waking: a crewmate's final status write and the same turn's turn-end hook
  # land seconds apart, and reporting them as separate wakes costs a full
  # firstmate turn each. The re-scan also picks up a newer signature for an
  # already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Backlog refresh: any status write may flip a task from inflight to
    # done (or vice versa) in the SQLite queue, and data/backlog.md is now
    # auto-derived from that store. Re-emit it on every signal so the
    # captain's view stays current without waiting for a manual edit.
    # The script is idempotent and ~30ms in the cold path; in the warm
    # path it is a noop against the existing on-disk file. We deliberately
    # call it BEFORE the auto-teardown block below: a done:/failed: write
    # must appear in backlog.md before the teardown removes the task from
    # inflight (otherwise the entry would vanish before the markdown ever
    # saw it).
    if [ -x "$SCRIPT_DIR/fm-queue.sh" ]; then
      "$SCRIPT_DIR/fm-queue.sh" to-markdown >/dev/null 2>&1 || true
    fi
    # Scout auto-teardown: when a status write lands for a scout task whose
    # last line is done: or failed:, the watcher releases the worktree slot
    # itself instead of waiting for firstmate to call fm-teardown. Ship
    # tasks are never auto-torn-down here - they have PRs and merge gates.
    # fm-teardown.sh enforces its own scout report-exists check; if the
    # report is missing it will refuse and the error is surfaced below.
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      id=$(basename "$f" .status)
      META="$STATE/$id.meta"
      [ -f "$META" ] || continue
      KIND=$(meta_get "$id" kind)
      [ "$KIND" = scout ] || continue
      last=$(tail -1 "$f" 2>/dev/null || true)
      case "$last" in
        'done:'*|'failed:'*)
          echo "watcher: auto-teardown scout $id (last status: $last)" >&2
          "$SCRIPT_DIR/fm-teardown.sh" "$id" >&2 || echo "watcher: auto-teardown of scout $id refused (see fm-teardown output above)" >&2
          ;;
      esac
    done <<EOF
$pending
EOF
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
    done <<EOF
$pending
EOF
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      printf '%s' "$sig" > "$sf"
    done <<EOF
$pending
EOF
    wake "$reason"
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale state is reported once (.stale-* remembers the hash already reported).
  #
  # Backend: mintmux pane ids come from mm_list_panes (one "<pane>\t<session>"
  # Enumerate panes via mintmux. Hash and count files key off the entry name.
  # If mintmux is unreachable, skip pane heartbeats this tick — don't fall back to tmux.
  pane_list=""
  if mm_ping 2>/dev/null; then
    pane_list=$(mm_list_panes | awk -F'\t' '$2 ~ /^fm-/ {print $2":"$1}' || true)
  fi
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    pane_id=${w##*:}
    tail40=$(mm_capture_pane "$pane_id" 4096 2>/dev/null || true)
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(printf '%s' "$w" | tr ':/.' '___')
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    prev=$(cat "$hf" 2>/dev/null || true)
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      # Busy match runs on the last 6 non-blank lines only (the TUI footer area,
      # where every verified harness renders its busy indicator) so busy-looking
      # strings in displayed content cannot suppress stale detection.
      if [ "$n" -ge 2 ] && ! printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"; then
        if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
          fm_wake_append stale "$w" "stale: $w" || exit 1
          printf '%s' "$h" > "$sf"
          wake "stale: $w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
    fi
  done <<< "$pane_list"

  # Transcript summarizer: run fm-transcript-summarizer.py in the background
  # every SUMMARIZER_INTERVAL seconds so new transcripts get MLX summaries
  # without requiring a manual trigger. Runs detached (nohup &) so it never
  # blocks the watcher cycle; a lock file prevents overlapping runs.
  if [ "${SUMMARIZER_INTERVAL:-0}" -gt 0 ] && [ -f "$SUMMARIZER_BIN" ]; then
    SUMMARIZER_LOCK="$STATE/.summarizer.lock"
    SUMMARIZER_STAMP="$STATE/.last-summarizer"
    if [ "$(age_of "$SUMMARIZER_STAMP")" -ge "$SUMMARIZER_INTERVAL" ]; then
      if ! [ -f "$SUMMARIZER_LOCK" ] || ! kill -0 "$(cat "$SUMMARIZER_LOCK" 2>/dev/null)" 2>/dev/null; then
        touch "$SUMMARIZER_STAMP"
        (
          echo $$ > "$SUMMARIZER_LOCK"
          TRANSCRIPT_BATCH_SIZE="$SUMMARIZER_BATCH" python3 "$SUMMARIZER_BIN" \
            >> "$STATE/summarizer.log" 2>&1
          rm -f "$SUMMARIZER_LOCK"
        ) &
        disown $!
      fi
    fi
  fi

  # Heartbeat: firstmate reviews the whole fleet at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any other wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    fm_wake_append heartbeat heartbeat heartbeat || exit 1
    touch "$STATE/.last-heartbeat"
    wake "heartbeat"
  fi

  sleep "$POLL"
done
