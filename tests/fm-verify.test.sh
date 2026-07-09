#!/usr/bin/env bash
# Behavior test for bin/fm-verify.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-verify)

# Build a temporary firstmate home with minimal fixtures.
FM_HOME=$TMP_ROOT/fm-home
mkdir -p "$FM_HOME/config" "$FM_HOME/state" "$FM_HOME/data"
# Skills dir under $HOME/.agents/skills (script reads $HOME/.agents/skills)
mkdir -p "$TMP_ROOT/.agents/skills"

# --- config files ---

# crew-harness: valid
echo "claude" > "$FM_HOME/config/crew-harness"

# secondmate-harness: valid (ca normalizes->claude via normalize_harness)
echo "ca" > "$FM_HOME/config/secondmate-harness"

# crew-dispatch.json: ct and agy have templates; fakewormhole does not.
cat > "$FM_HOME/config/crew-dispatch.json" <<'EOF'
{
  "rules": [
    { "when": "mechanical work", "use": { "harness": "ct", "effort": "low" } },
    { "when": "google work", "use": { "harness": "agy", "model": "gemini-3-pro", "effort": "high" } }
  ],
  "default": { "harness": "fakewormhole", "model": "sonnet", "effort": "medium" }
}
EOF

# --- skill registration: 2 valid + 2 broken ---

mkdir -p "$TMP_ROOT/.agents/skills/valid-one"
cat > "$TMP_ROOT/.agents/skills/valid-one/SKILL.md" <<'EOF'
---
name: valid-one
description: A valid skill for testing
---
EOF

mkdir -p "$TMP_ROOT/.agents/skills/valid-two"
cat > "$TMP_ROOT/.agents/skills/valid-two/SKILL.md" <<'EOF'
---
name: valid-two
description: Another valid skill
---
EOF

mkdir -p "$TMP_ROOT/.agents/skills/broken-no-file"
# no SKILL.md here

mkdir -p "$TMP_ROOT/.agents/skills/broken-no-desc"
cat > "$TMP_ROOT/.agents/skills/broken-no-desc/SKILL.md" <<'EOF'
---
name: broken-no-desc
# intentionally missing description
---
EOF

# --- state meta files ---

# Normal ship task with window=
fm_write_meta "$FM_HOME/state/ship-one.meta" \
  "window=firstmate:fm-ship-one" \
  "worktree=$TMP_ROOT/wt-ship-one" \
  "project=$TMP_ROOT" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "yolo=off"

# Ship task missing window= (should violate check 7)
fm_write_meta "$FM_HOME/state/ship-no-window.meta" \
  "worktree=$TMP_ROOT/wt-ship-no-window" \
  "project=$TMP_ROOT" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "yolo=off"

# Secondmate on main (should pass check 5)
sm_main=$TMP_ROOT/sm-main-git
mkdir -p "$sm_main"
GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid \
GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid \
git -C "$sm_main" init -q
echo "# sm-main" > "$sm_main/README.md"
GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid \
GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid \
git -C "$sm_main" add README.md
GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid \
GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid \
git -C "$sm_main" commit -q -m initial --allow-empty
# Ensure on main branch regardless of git default
git -C "$sm_main" branch -m main 2>/dev/null || true
fm_write_secondmate_meta "$FM_HOME/state/secondmate-ok.meta" "$sm_main" "firstmate:fm-domain" "alpha"

# Secondmate on a feature branch (should violate check 5)
sm_feat=$TMP_ROOT/sm-feat-base
feat_wt=$TMP_ROOT/sm-feat-wt
GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid \
GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid \
fm_git_worktree "$sm_feat" "$feat_wt" "fm/some-feature"
fm_write_secondmate_meta "$FM_HOME/state/secondmate-feature.meta" "$feat_wt" "firstmate:fm-feat" "beta"

# --- backlog ---
cat > "$FM_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-one - a task (repo: test, since 2026-07-09)
- [ ] ship-no-window - a task (repo: test, since 2026-07-09)
- [ ] non-existent-missing - an orphan (repo: test, since 2026-07-09)
## Queued
- [ ] later-item - a queued item (repo: test)
## Done
- [x] past-item - done (2026-07-08)
EOF

# --- tool mock: fake firstmate-specific tools. jq comes from /usr/bin via PATH ---
fakebin=$(fm_fakebin "$TMP_ROOT")
fm_fake_exit0 "$fakebin" tldr ccc githits no-mistakes gh-axi

# Keep python3 mock in fakebin for reliable check 6 pass regardless of
# /usr/bin/python3 presence (CommandLineTools requirement).
fm_fake_exit0 "$fakebin" python3
# Restrict PATH to fakebin (mocks) and system dirs (jq comes from /usr/bin)
SCRIPT_PATH="$fakebin:/usr/bin:/bin"

export FM_HOME
export HOME=$TMP_ROOT
export PATH="$SCRIPT_PATH"

# Run the script and capture output
output=$(bash "$ROOT/bin/fm-verify.sh" 2>&1; RC=$?; echo "EXIT_CODE=$RC"; exit 0)

# --- assertions ---

assert_contains "$output" "PASS: harness-adapter-consistency" \
  "check 1: all verified adapters have launch templates"

assert_contains "$output" "VIOLATED: dispatch-profile-validity" \
  "check 2: dispatch profile has unverified harness fakewormhole"
assert_contains "$output" "fakewormhole" \
  "check 2: violation mentions fakewormhole"

assert_contains "$output" "PASS: crew-harness-validity" \
  "check 3: crew-harness configs are valid"

assert_contains "$output" "skill-registration (2 valid, 2 broken" \
  "check 4: counts skills correctly (2 valid, 2 broken)"

assert_contains "$output" "VIOLATED: secondmate-branch-check" \
  "check 5: detects secondmate on feature branch"
assert_contains "$output" "secondmate-feature" \
  "check 5: names the violating secondmate"

assert_contains "$output" "PASS: tool-availability" \
  "check 6: all required tools on PATH"

assert_contains "$output" "VIOLATED: in-flight-consistency" \
  "check 7: detects backlog/meta mismatch"
assert_contains "$output" "non-existent-missing" \
  "check 7: names orphan backlog entry"
assert_contains "$output" "ship-no-window" \
  "check 7: names meta missing window="

# Summary line: 4 violated checks (2,4,5,7), 3 passing (1,3,6)
assert_contains "$output" "fm-verify: 3 pass, 4 violated" \
  "summary line matches expected counts"

RC=$(echo "$output" | sed -n 's/^EXIT_CODE=//p')
expect_code 1 "$RC" "exits 1 when violations exist"

# --- clean scenario: all valid ---
FM_HOME_CLEAN=$TMP_ROOT/fm-home-clean
mkdir -p "$FM_HOME_CLEAN/config" "$FM_HOME_CLEAN/state" "$FM_HOME_CLEAN/data"
fm_write_meta "$FM_HOME_CLEAN/state/ship-clean.meta" \
  "window=firstmate:fm-ship-clean" \
  "worktree=$TMP_ROOT/wt-clean" \
  "project=$TMP_ROOT" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "yolo=off"
cat > "$FM_HOME_CLEAN/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-clean - a task (repo: test, since 2026-07-09)
## Done
- [x] past-item - done (2026-07-08)
EOF
fm_fake_exit0 "$fakebin" tldr ccc githits no-mistakes gh-axi python3
output_clean=$(FM_HOME="$FM_HOME_CLEAN" HOME="$TMP_ROOT/clean-home" PATH="$fakebin:$PATH" bash "$ROOT/bin/fm-verify.sh" 2>&1; RC=$?; echo "EXIT_CODE=$RC"; exit 0)

assert_contains "$output_clean" "PASS: harness-adapter-consistency" \
  "clean: adapter consistency passes"
assert_contains "$output_clean" "PASS: dispatch-profile-validity (no file)" \
  "clean: no dispatch file"
assert_contains "$output_clean" "PASS: crew-harness-validity" \
  "clean: harness configs valid (none present)"
assert_contains "$output_clean" "PASS: tool-availability" \
  "clean: all tools available"
assert_contains "$output_clean" "fm-verify: 7 pass, 0 violated" \
  "clean: all pass"

RC_CLEAN=$(echo "$output_clean" | sed -n 's/^EXIT_CODE=//p')
expect_code 0 "$RC_CLEAN" "clean: exits 0"

pass "fm-verify.sh: all checks pass"
