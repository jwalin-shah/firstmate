#!/usr/bin/env bash
# Tests for bin/fm-bridge-verify.sh: the machine gate run before human review
# of a done: report. Missing `bridge` is a skip, a green run is a pass, a red
# run blocks - and in every case the gate must target the task's project
# clone (meta project=), never the worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE_VERIFY="$ROOT/bin/fm-bridge-verify.sh"
TMP_ROOT=$(fm_test_tmproot fm-bridge-verify-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/project" "$case_dir/wt"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project"
}

# fake_bridge <case_dir> <exit_code>: drop a fakebin `bridge` stub that records
# the exact argv it was called with (so tests can assert it targets the
# project clone, not the worktree) and exits with the given code.
fake_bridge() {
  local case_dir=$1 code=$2 fakebin
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/bridge" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/bridge-calls.log"
exit $code
SH
  chmod +x "$fakebin/bridge"
  printf '%s\n' "$fakebin"
}

run_bridge_verify() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$BRIDGE_VERIFY" "$@"
}

test_missing_bridge_binary_is_a_skip() {
  local case_dir out code path_no_bridge
  case_dir=$(make_case no-bridge)
  write_task_meta "$case_dir"
  # Strip any real `bridge` off PATH so the skip path is exercised regardless
  # of what is installed on the host running these tests.
  path_no_bridge=$(printf '%s' "$PATH" | tr ':' '\n' | while read -r d; do
    [ -x "$d/bridge" ] || printf '%s:' "$d"
  done)

  set +e
  out=$(PATH="$path_no_bridge" run_bridge_verify "$case_dir" task-x1 2>&1)
  code=$?
  set -e

  expect_code 0 "$code" "no-bridge: skip must exit 0"
  assert_contains "$out" "skipping verify gate" "no-bridge: must report a skip, not silence"
  pass "fm-bridge-verify skips cleanly when bridge is not installed"
}

test_green_bridge_passes_and_targets_project_clone() {
  local case_dir out code fakebin log
  case_dir=$(make_case green)
  write_task_meta "$case_dir"
  fakebin=$(fake_bridge "$case_dir" 0)

  set +e
  out=$(PATH="$fakebin:$PATH" run_bridge_verify "$case_dir" task-x1 2>&1)
  code=$?
  set -e

  expect_code 0 "$code" "green: passing gates must exit 0"
  assert_contains "$out" "gates green" "green: must report the pass"
  log=$(cat "$case_dir/bridge-calls.log")
  assert_contains "$log" "verify $case_dir/project" "green: must verify the project clone path"
  assert_not_contains "$log" "$case_dir/wt" "green: must not target the worktree path"
  pass "fm-bridge-verify passes on a green run and targets the project clone"
}

test_red_bridge_blocks() {
  local case_dir out code fakebin
  case_dir=$(make_case red)
  write_task_meta "$case_dir"
  fakebin=$(fake_bridge "$case_dir" 1)

  set +e
  out=$(PATH="$fakebin:$PATH" run_bridge_verify "$case_dir" task-x1 2>&1)
  code=$?
  set -e

  expect_code 1 "$code" "red: failing gates must exit non-zero"
  assert_contains "$out" "BLOCKED: bridge verify failed - gates are red" \
    "red: must report the block verbatim"
  pass "fm-bridge-verify blocks when bridge verify reports red gates"
}

test_missing_meta_errors() {
  local case_dir out code
  case_dir=$(make_case no-meta)

  set +e
  out=$(run_bridge_verify "$case_dir" task-x1 2>&1)
  code=$?
  set -e

  expect_code 1 "$code" "no-meta: must error without a meta file"
  assert_contains "$out" "no meta for task" "no-meta: error must name the missing meta"
  pass "fm-bridge-verify errors when the task has no meta file"
}

test_missing_project_dir_errors() {
  local case_dir out code
  case_dir=$(make_case no-project-dir)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/does-not-exist"

  set +e
  out=$(run_bridge_verify "$case_dir" task-x1 2>&1)
  code=$?
  set -e

  expect_code 1 "$code" "no-project-dir: must error when project= points nowhere"
  assert_contains "$out" "project for task" "no-project-dir: error must name the missing project"
  pass "fm-bridge-verify errors when the recorded project clone is missing"
}

test_missing_bridge_binary_is_a_skip
test_green_bridge_passes_and_targets_project_clone
test_red_bridge_blocks
test_missing_meta_errors
test_missing_project_dir_errors
