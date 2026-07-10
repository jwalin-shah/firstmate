#!/usr/bin/env bash
# Behavior tests for bin/fm-stage-enforce.sh — pipeline stage enforcement.
#
# Cases:
#   1. Silent when stage is progressing (within thresholds)
#   2. Nudge when stage is overdue (>= NUDGE_MINUTES)
#   3. Kill when unresponsive (>= KILL_MINUTES, after nudge)
#   4. Nudge before kill — never kills without nudging first
#   5. New stage resets the timer
#   6. Idempotent after kill
#   7. No-op for secondmates
#   8. No-op without meta file
#   9. No stages yet (fresh spawn, no status file)
#  10. Graceful handling of corrupt marker file
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STAGE_ENFORCE="$ROOT/bin/fm-stage-enforce.sh"
TMP_ROOT=$(fm_test_tmproot fm-stage-enforce)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

# --- helpers ------------------------------------------------------------------

setup_home() {
  local home=$1 id=$2
  mkdir -p "$home/state"
  # meta file: minimal ship task
  printf 'kind=ship\n' > "$home/state/$id.meta"
  printf 'window=firstmate:fm-%s\n' "$id" >> "$home/state/$id.meta"
  printf 'backend=tmux\n' >> "$home/state/$id.meta"
}

write_status() {
  local home=$1 id=$2
  shift 2
  printf '%s\n' "$@" > "$home/state/$id.status"
}

write_enforce_file() {
  local home=$1 id=$2 stage=$3 epoch=$4 state=$5 nudge_epoch=${6:-0}
  printf '%s\t%s\t%s\t%s\n' "$stage" "$epoch" "$state" "$nudge_epoch" > "$home/state/.stage-enforce-$id"
}

# Create a fake fm-send.sh that records its arguments.
make_fake_send() {
  cat > "$FAKEBIN/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf 'send-args: %s\n' "$*" >> "${FM_SEND_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$FAKEBIN/fm-send.sh"
}

# Create a fake tmux that records kill-window calls.
make_fake_tmux() {
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  kill-window)
    printf 'tmux-kill: %s\n' "$*" >> "${TMUX_LOG:-/dev/null}"
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/tmux"
}

make_fake_send
make_fake_tmux

# All tests run the script with the fakebin at the front of PATH.
run_enforce() {
  local home=$1 id=$2
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_SEND_BIN="$FAKEBIN/fm-send.sh" bash "$STAGE_ENFORCE" "$id"
}

# --- tests --------------------------------------------------------------------

# 1. Silent when stage is progressing (within thresholds)
echo "== 1: progressing stage =="
HOME1=$(mktemp -d "$TMP_ROOT/home1.XXXXXX")
setup_home "$HOME1" "task1"
write_status "$HOME1" "task1" "working: wayfinder complete"
out=$(run_enforce "$HOME1" "task1")
[ -z "$out" ] || fail "1: expected silent, got: $out"
[ -f "$HOME1/state/.stage-enforce-task1" ] || fail "1: expected marker file"
pass "1: progressing stage — silent"

# 2. Nudge when stage is overdue
echo "== 2: nudge overdue stage =="
HOME2=$(mktemp -d "$TMP_ROOT/home2.XXXXXX")
setup_home "$HOME2" "task2"
write_status "$HOME2" "task2" "working: wayfinder complete"
SEND_LOG="$HOME2/send.log"
old_epoch=$(( $(date +%s) - 400 ))  # ~6.6 min ago
write_enforce_file "$HOME2" "task2" "working: wayfinder complete" "$old_epoch" "tracking"
out=$(FM_SEND_LOG="$SEND_LOG" run_enforce "$HOME2" "task2")
assert_contains "$out" "nudge: task2 wayfinder complete stalled for" "2: expected nudge output"
assert_grep "send-args:" "$SEND_LOG" "2: expected fm-send call"
# Marker should now be in 'nudged' state.
assert_grep "nudged" "$HOME2/state/.stage-enforce-task2" "2: expected nudged state in marker"
pass "2: nudge overdue stage"

# 3. Kill when unresponsive
echo "== 3: kill unresponsive =="
HOME3=$(mktemp -d "$TMP_ROOT/home3.XXXXXX")
setup_home "$HOME3" "task3"
write_status "$HOME3" "task3" "working: wayfinder complete"
old_epoch=$(( $(date +%s) - 1000 ))  # ~16.6 min ago
TMUX_LOG="$HOME3/tmux.log"
write_enforce_file "$HOME3" "task3" "working: wayfinder complete" "$old_epoch" "nudged"
out=$(TMUX_LOG="$TMUX_LOG" run_enforce "$HOME3" "task3")
assert_contains "$out" "kill: task3 unresponsive for" "3: expected kill output"
assert_grep "failed: unresponsive - no stage progress" "$HOME3/state/task3.status" "3: expected failed line in status"
assert_grep "tmux-kill:" "$TMUX_LOG" "3: expected tmux kill-window call"
assert_grep "killed" "$HOME3/state/.stage-enforce-task3" "3: expected killed state in marker"
pass "3: kill unresponsive"

# 4. Nudge before kill — never kills without nudging first
echo "== 4: nudge-before-kill ordering =="
HOME4=$(mktemp -d "$TMP_ROOT/home4.XXXXXX")
setup_home "$HOME4" "task4"
write_status "$HOME4" "task4" "working: wayfinder complete"
old_epoch=$(( $(date +%s) - 1000 ))  # past KILL_MINUTES
SEND_LOG="$HOME4/send.log"
write_enforce_file "$HOME4" "task4" "working: wayfinder complete" "$old_epoch" "tracking"
out=$(FM_SEND_LOG="$SEND_LOG" run_enforce "$HOME4" "task4")
# Even though elapsed > KILL_MINUTES, state is 'tracking' → must nudge first.
assert_contains "$out" "nudge:" "4: expected nudge, not kill"
assert_grep "nudged" "$HOME4/state/.stage-enforce-task4" "4: expected nudged state"
# Second call: now in 'nudged' state, should kill.
TMUX_LOG="$HOME4/tmux.log"
out2=$(TMUX_LOG="$TMUX_LOG" run_enforce "$HOME4" "task4")
assert_contains "$out2" "kill: task4 unresponsive for" "4: expected kill on second call"
assert_grep "failed:" "$HOME4/state/task4.status" "4: expected failed line in status"
pass "4: nudge before kill ordering"

# 5. New stage resets timer
echo "== 5: new stage resets =="
HOME5=$(mktemp -d "$TMP_ROOT/home5.XXXXXX")
setup_home "$HOME5" "task5"
write_status "$HOME5" "task5" "working: wayfinder complete" "working: design complete"
old_epoch=$(( $(date +%s) - 400 ))
write_enforce_file "$HOME5" "task5" "working: wayfinder complete" "$old_epoch" "nudged"
out=$(run_enforce "$HOME5" "task5")
[ -z "$out" ] || fail "5: expected silent after new stage, got: $out"
assert_grep "working: design complete" "$HOME5/state/.stage-enforce-task5" "5: expected new stage in marker"
assert_grep "tracking" "$HOME5/state/.stage-enforce-task5" "5: expected reset to tracking"
pass "5: new stage resets timer"

# 6. Idempotent after kill
echo "== 6: idempotent after kill =="
HOME6=$(mktemp -d "$TMP_ROOT/home6.XXXXXX")
setup_home "$HOME6" "task6"
write_status "$HOME6" "task6" "working: wayfinder complete" "failed: unresponsive"
old_epoch=$(( $(date +%s) - 2000 ))
write_enforce_file "$HOME6" "task6" "working: wayfinder complete" "$old_epoch" "killed"
out=$(run_enforce "$HOME6" "task6")
[ -z "$out" ] || fail "6: expected silent after kill, got: $out"
pass "6: idempotent after kill"

# 7. No-op for secondmates
echo "== 7: skip secondmate =="
HOME7=$(mktemp -d "$TMP_ROOT/home7.XXXXXX")
mkdir -p "$HOME7/state"
printf 'kind=secondmate\n' > "$HOME7/state/task7.meta"
write_status "$HOME7" "task7" "working: wayfinder complete"
out=$(run_enforce "$HOME7" "task7")
[ -z "$out" ] || fail "7: expected silent for secondmate, got: $out"
[ ! -f "$HOME7/state/.stage-enforce-task7" ] || fail "7: expected no marker for secondmate"
pass "7: skip secondmate"

# 8. No-op without meta file
echo "== 8: skip no meta =="
HOME8=$(mktemp -d "$TMP_ROOT/home8.XXXXXX")
mkdir -p "$HOME8/state"
out=$(run_enforce "$HOME8" "task8")
[ -z "$out" ] || fail "8: expected silent without meta, got: $out"
pass "8: skip no meta"

# 9. No stages yet (fresh spawn, no status file)
echo "== 9: no stages yet =="
HOME9=$(mktemp -d "$TMP_ROOT/home9.XXXXXX")
setup_home "$HOME9" "task9"
# No status file at all.
out=$(run_enforce "$HOME9" "task9")
[ -z "$out" ] || fail "9: expected silent for fresh spawn, got: $out"
[ -f "$HOME9/state/.stage-enforce-task9" ] || fail "9: expected marker for fresh spawn"
assert_grep "tracking" "$HOME9/state/.stage-enforce-task9" "9: expected tracking state"
pass "9: no stages yet — creates tracking marker"

# 10. Graceful handling of corrupt marker file
echo "== 10: corrupt marker =="
HOME10=$(mktemp -d "$TMP_ROOT/home10.XXXXXX")
setup_home "$HOME10" "task10"
write_status "$HOME10" "task10" "working: wayfinder complete"
echo "garbage" > "$HOME10/state/.stage-enforce-task10"
out=$(run_enforce "$HOME10" "task10")
[ -z "$out" ] || fail "10: expected silent with corrupt marker (treated as fresh), got: $out"
pass "10: corrupt marker — treated as fresh"

echo ""
echo "all tests passed"
