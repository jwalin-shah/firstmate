#!/usr/bin/env bash
# Behavior tests for bin/fm-verify.sh - the config-invariant checker.
#
# fm-verify.sh runs two kinds of check: static analysis of the real firstmate
# bin/ scripts (harness-adapter-consistency, dispatch-profile-validity's spawn
# lookup) - always exercised against THIS repo's actual bin/, since that is
# the point - and operational-home checks (dispatch profile content,
# crew/secondmate harness overrides, skills, secondmate branches, backlog/meta
# consistency, tool presence) - exercised against a hermetic fixture directory
# via FM_HOME/FM_CONFIG_OVERRIDE/FM_STATE_OVERRIDE/FM_DATA_OVERRIDE/
# FM_SKILLS_OVERRIDE, exactly like fm-bootstrap.test.sh's fixtures.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-verify-tests)

# A fakebin with every tool fm-verify.sh's tool-availability check requires.
# Pass extra tool names to OMIT from the stub set (to force a VIOLATED case).
full_fakebin() {
  local dir=$1 fakebin required omit t
  shift
  fakebin=$(fm_fakebin "$dir")
  required="tldr ccc githits no-mistakes jq gh-axi python3"
  for t in $required; do
    omit=0
    for o in "$@"; do [ "$o" = "$t" ] && omit=1; done
    [ "$omit" = 1 ] || fm_fake_exit0 "$fakebin" "$t"
  done
  printf '%s\n' "$fakebin"
}

# A fixture home: empty config/state/data dirs and an empty skills dir, so
# every operational-home check trivially passes on its own.
bare_home() {
  local dir=$1
  mkdir -p "$dir/home/config" "$dir/home/state" "$dir/home/data" "$dir/skills"
  printf '%s\n' "$dir/home"
}

run_verify() {
  local home=$1 fakebin=$2 skills=$3
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_SKILLS_OVERRIDE="$skills" "$ROOT/bin/fm-verify.sh" 2>&1
}

test_clean_fixture_passes_all_seven() {
  local dir home fakebin out rc
  dir="$TMP_ROOT/clean"
  home=$(bare_home "$dir")
  fakebin=$(full_fakebin "$dir")
  out=$(run_verify "$home" "$fakebin" "$dir/skills"); rc=$?
  expect_code 0 "$rc" "clean fixture exit code"
  assert_contains "$out" "PASS: harness-adapter-consistency" "harness-adapter-consistency should pass against this repo's real bin/"
  assert_contains "$out" "PASS: dispatch-profile-validity - no config/crew-dispatch.json" "no dispatch profile configured"
  assert_contains "$out" "PASS: crew-harness-validity - no explicit crew-harness/secondmate-harness override configured" "no harness overrides configured"
  assert_contains "$out" "PASS: skill-registration - 0 skills registered" "empty skills dir registers zero skills"
  assert_contains "$out" "PASS: secondmate-branch-check - 0 secondmate home(s) checked" "no secondmate metas present"
  assert_contains "$out" "PASS: tool-availability - all required tools on PATH" "every required tool stubbed"
  assert_contains "$out" "PASS: in-flight-consistency - no data/backlog.md" "no backlog present"
  assert_contains "$out" "fm-verify: OK (7/7 checks passed)" "summary line"
  pass "clean fixture passes all seven checks"
}

test_tool_availability_reports_missing() {
  local dir home fakebin out rc
  dir="$TMP_ROOT/missing-tool"
  home=$(bare_home "$dir")
  # jq is omitted from BASE_PATH deliberately (unlike githits/ccc/etc it can be
  # present under /usr/bin on some hosts), so omit two tools BASE_PATH never
  # provides to keep this deterministic across hosts.
  fakebin=$(full_fakebin "$dir" githits ccc)
  out=$(run_verify "$home" "$fakebin" "$dir/skills"); rc=$?
  expect_code 1 "$rc" "missing-tool fixture exit code"
  assert_contains "$out" "VIOLATED: tool-availability - missing:" "tool-availability reports the violation"
  assert_contains "$out" "ccc" "ccc listed as missing"
  assert_contains "$out" "githits" "githits listed as missing"
  assert_contains "$out" "fm-verify: VIOLATIONS FOUND" "summary reflects the violation"
  pass "tool-availability lists every missing required tool"
}

test_skill_registration_flags_broken_skills() {
  local dir home fakebin out rc skills
  dir="$TMP_ROOT/skills"
  home=$(bare_home "$dir")
  fakebin=$(full_fakebin "$dir")
  skills="$dir/skills2"
  mkdir -p "$skills/good" "$skills/no-frontmatter" "$skills/missing-md"
  cat > "$skills/good/SKILL.md" <<'EOF'
---
name: good
description: a fine skill
---
body
EOF
  cat > "$skills/no-frontmatter/SKILL.md" <<'EOF'
just a body, no frontmatter fields
EOF
  out=$(run_verify "$home" "$fakebin" "$skills"); rc=$?
  expect_code 1 "$rc" "broken-skills fixture exit code"
  assert_contains "$out" "VIOLATED: skill-registration -" "skill-registration violated"
  assert_contains "$out" "no-frontmatter (missing name:/description: frontmatter)" "flags missing frontmatter fields"
  assert_contains "$out" "missing-md (missing/unreadable SKILL.md)" "flags a directory with no SKILL.md"
  pass "skill-registration flags broken skill directories and counts nothing as broken silently"
}

test_dispatch_profile_flags_unverified_harness() {
  local dir home fakebin out rc real_jq
  dir="$TMP_ROOT/dispatch"
  home=$(bare_home "$dir")
  fakebin=$(full_fakebin "$dir")
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required on the test host to validate this check"
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  chmod +x "$fakebin/jq"
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{"rules":[{"when":"anything","use":{"harness":"spaceship"}}],"default":{"harness":"claude"}}
EOF
  out=$(run_verify "$home" "$fakebin" "$dir/skills"); rc=$?
  expect_code 1 "$rc" "unverified dispatch harness exit code"
  assert_contains "$out" "VIOLATED: dispatch-profile-validity -" "dispatch-profile-validity violated"
  assert_contains "$out" "spaceship (normalizes to spaceship, no launch template)" "names the unverified harness"
  pass "dispatch-profile-validity flags a harness with no spawn launch template"
}

test_crew_harness_override_validated() {
  local dir home fakebin out rc
  dir="$TMP_ROOT/crew-harness"
  home=$(bare_home "$dir")
  fakebin=$(full_fakebin "$dir")
  echo "spaceship" > "$home/config/crew-harness"
  out=$(run_verify "$home" "$fakebin" "$dir/skills"); rc=$?
  expect_code 1 "$rc" "bad crew-harness override exit code"
  assert_contains "$out" "VIOLATED: crew-harness-validity -" "crew-harness-validity violated"
  assert_contains "$out" "crew-harness=spaceship" "names the bad override"

  echo "ca" > "$home/config/crew-harness"
  out=$(run_verify "$home" "$fakebin" "$dir/skills"); rc=$?
  expect_code 0 "$rc" "aliased crew-harness override exit code"
  assert_contains "$out" "PASS: crew-harness-validity - crew-harness=ca(->claude)" "ca normalizes to claude and passes"
  pass "crew-harness-validity validates explicit overrides through normalize_harness"
}

test_secondmate_branch_check_flags_feature_branch() {
  local dir home fakebin out rc sm_home
  dir="$TMP_ROOT/secondmate"
  home=$(bare_home "$dir")
  fakebin=$(full_fakebin "$dir")
  sm_home="$dir/sm-home"
  fm_git_init_commit "$sm_home"
  git -C "$sm_home" checkout -q -b feature/not-default
  fm_write_meta "$home/state/sm1.meta" "kind=secondmate" "home=$sm_home"
  out=$(run_verify "$home" "$fakebin" "$dir/skills"); rc=$?
  expect_code 1 "$rc" "secondmate on feature branch exit code"
  assert_contains "$out" "VIOLATED: secondmate-branch-check -" "secondmate-branch-check violated"
  assert_contains "$out" "sm1 (home on feature branch 'feature/not-default'" "names the offending secondmate and branch"
  pass "secondmate-branch-check flags a secondmate home not on the default branch"
}

test_in_flight_consistency_flags_orphans() {
  local dir home fakebin out rc
  dir="$TMP_ROOT/in-flight"
  home=$(bare_home "$dir")
  fakebin=$(full_fakebin "$dir")
  printf '## In flight\n- [ ] ghost-task - a task with no meta (repo: x, since 2026-07-01)\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fm_write_meta "$home/state/windowless.meta" "kind=ship"
  out=$(run_verify "$home" "$fakebin" "$dir/skills"); rc=$?
  expect_code 1 "$rc" "in-flight orphans exit code"
  assert_contains "$out" "VIOLATED: in-flight-consistency -" "in-flight-consistency violated"
  assert_contains "$out" "in-flight 'ghost-task' has no state/ghost-task.meta" "flags the backlog id with no meta"
  assert_contains "$out" "windowless has no window= recorded" "flags a non-secondmate meta missing window="
  pass "in-flight-consistency flags a backlog orphan and a meta missing window="
}

test_clean_fixture_passes_all_seven
test_tool_availability_reports_missing
test_skill_registration_flags_broken_skills
test_dispatch_profile_flags_unverified_harness
test_crew_harness_override_validated
test_secondmate_branch_check_flags_feature_branch
test_in_flight_consistency_flags_orphans
