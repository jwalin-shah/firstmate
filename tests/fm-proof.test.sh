#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for the development-contract proof ledger and write gate
# (docs/proof-enforcement.md).
#
# bin/fm-proof.sh owns ordered steps, evidence rules, and implement_ready.
# bin/fm-proof-pretool-check.sh is the PreToolUse transport. This suite proves
# ordered recording, write deny/allow, loop reset, inactive enforcement, hook
# tool/bash classification, and ledger-path exemption. No live harness is
# spawned.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-proof)
PROOF="$ROOT/bin/fm-proof.sh"
HOOK="$ROOT/bin/fm-proof-pretool-check.sh"

make_repo() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

assert_rc() {
  local want=$1
  shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq "$want" ] || fail "expected rc=$want from: $* (got $rc)"
}

complete_pre() {
  local dir=$1
  (
    cd "$dir" || exit 1
    env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" record githits --query "q" --evidence "prior art" || exit 1
    env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" record axioms --evidence "AX-1" --ids AX-1 || exit 1
    env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" record tensor_equation --evidence "∀x: P(x)" || exit 1
    env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" record pseudocode --evidence "steps..." || exit 1
    env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" record proof --gap "tests only" || exit 1
  ) || fail "complete_pre failed in $dir"
}

# --- ordered init + deny before ready --------------------------------------

REPO=$(make_repo "$TMP_ROOT/repo1")
cd "$REPO" || fail "cd repo1"
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" init t1 --summary "test"
assert_rc 2 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" check-write
assert_rc 2 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" record axioms --evidence "too early"
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" record githits --query "q" --evidence "prior art"
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" record axioms --evidence "AX-1" --ids AX-1
assert_rc 1 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" record tensor_equation --evidence "no quantifier here"
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" record tensor_equation --evidence "∀x: P(x)"
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" record pseudocode --evidence "steps..."
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" record proof --gap "tests only"
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" check-write
ready=$(env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["implement_ready"])')
[ "$ready" = "True" ] || [ "$ready" = "true" ] || fail "implement_ready not true ($ready)"
pass "ordered record reaches implement_ready and admits writes"

# --- loop clears from tensor_equation --------------------------------------

assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" loop --counterexample "invariant broke"
assert_rc 2 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" check-write
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" record tensor_equation --evidence "∀x: P'(x)"
assert_rc 2 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" check-write
pass "loop keeps githits/axioms and blocks writes until re-proved"

# --- inactive enforcement allows -------------------------------------------

REPO2=$(make_repo "$TMP_ROOT/repo2")
cd "$REPO2" || fail "cd repo2"
assert_rc 0 env -u FM_PROOF_ENFORCE FM_ROOT_OVERRIDE="$ROOT" "$PROOF" check-write
assert_rc 0 env -u FM_PROOF_ENFORCE FM_ROOT_OVERRIDE="$ROOT" "$HOOK" --tool write --path "$REPO2/foo.ts"
pass "inactive enforcement allows writes"

# --- hook denies write tool when incomplete --------------------------------

REPO3=$(make_repo "$TMP_ROOT/repo3")
cd "$REPO3" || fail "cd repo3"
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" init t3
assert_rc 2 env FM_ROOT_OVERRIDE="$ROOT" "$HOOK" --tool write --path "$REPO3/src/a.go"
assert_rc 2 env FM_ROOT_OVERRIDE="$ROOT" "$HOOK" --command 'cat >src/a.go <<EOF
hi
EOF'
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$HOOK" --command "FM_ROOT_OVERRIDE=$ROOT $PROOF status"
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$HOOK" --tool write --path "$REPO3/.proof/ledger.json"
complete_pre "$REPO3"
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$HOOK" --tool write --path "$REPO3/src/a.go"
pass "hook denies incomplete writes and allows after ready + exemptions"

# --- stdin Claude-shaped deny keeps stdout empty ---------------------------

REPO4=$(make_repo "$TMP_ROOT/repo4")
cd "$REPO4" || fail "cd repo4"
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" init t4
errf="$TMP_ROOT/hook.err"
outf="$TMP_ROOT/hook.out"
payload=$(printf '%s' '{"tool_name":"Write","tool_input":{"path":"x.go","content":"x"}}')
set +e
printf '%s' "$payload" | env FM_ROOT_OVERRIDE="$ROOT" "$HOOK" --claude >"$outf" 2>"$errf"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "expected deny rc=2 (got $rc)"
[ ! -s "$outf" ] || fail "stdout not empty under --claude: $(cat "$outf")"
grep -q 'pre-implement-incomplete' "$errf" || fail "stderr missing deny detail: $(cat "$errf")"
pass "claude-shaped stdin deny is stderr-only exit 2"

# --- post steps + gate failure ---------------------------------------------

cd "$REPO3" || fail "cd repo3"
assert_rc 2 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" gate --exit-code 1 --evidence "build failed"
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" gate --exit-code 0 --evidence "build ok" --command "true"
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" invariant --evidence "TestAX covers equation"
assert_rc 0 env FM_ROOT_OVERRIDE="$ROOT" "$PROOF" ingest --evidence "no new axiom"
pass "gate refuses non-zero and records post steps"

pass "fm-proof suite complete"
