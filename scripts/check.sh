#!/usr/bin/env bash
# Firstmate check.sh: cheap pre-push gate that validates the script set is
# syntactically clean, shellcheck-clean, and that the queue + status
# binaries respond to `--help`-style invocations. Run by no-mistakes's
# review step and by hand before pushing. Exits 0 on success, 1 on any
# failure; each failing step prints a one-line explanation.
#
# Usage: scripts/check.sh
#
# We deliberately do NOT spawn crewmates, do NOT push, do NOT modify state.
# This is a static + smoke gate, not a behavior gate.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail=0

# 1. bash -n on every new/changed script. shellcheck runs after this.
SCRIPTS=(bin/fm-queue.sh bin/fm-status.sh bin/fm-session-start.sh
         bin/fm-bootstrap.sh bin/fm-watch.sh)
for s in "${SCRIPTS[@]}"; do
  if [ ! -f "$s" ]; then
    echo "check.sh: missing $s" >&2
    fail=1
    continue
  fi
  if ! bash -n "$s"; then
    echo "check.sh: bash -n failed on $s" >&2
    fail=1
  fi
done
if [ "$fail" -eq 0 ]; then
  echo "check.sh: bash -n clean (${#SCRIPTS[@]} scripts)"
fi

# 2. shellcheck -S warning on the same set. Skip with SKIP_SHELLCHECK=1
#    in case the local environment does not have shellcheck installed.
if [ "${SKIP_SHELLCHECK:-0}" = "1" ] || ! command -v shellcheck >/dev/null 2>&1; then
  echo "check.sh: shellcheck skipped (not installed or SKIP_SHELLCHECK=1)"
else
  if shellcheck -S warning "${SCRIPTS[@]}"; then
    echo "check.sh: shellcheck clean"
  else
    echo "check.sh: shellcheck reported issues" >&2
    fail=1
  fi
fi

# 3. python3 syntax check on the contract-graph script.
if [ -f scripts/contract-graph.py ]; then
  if ! python3 -c 'import ast,sys; ast.parse(open("scripts/contract-graph.py").read())'; then
    echo "check.sh: scripts/contract-graph.py has a Python syntax error" >&2
    fail=1
  else
    echo "check.sh: scripts/contract-graph.py parses"
  fi
fi

# 4. contract-graph edge count: the diagram must have at least one edge
#    (proves the script walks the repo and emits a real graph, not a
#    stub that would still pass `--help`).
if [ -f scripts/contract-graph.py ] && command -v python3 >/dev/null 2>&1; then
  if python3 scripts/contract-graph.py >/dev/null 2>&1; then
    total=$(jq -r '.summary.total // 0' docs/architecture/contract-graph.json 2>/dev/null || echo 0)
    if [ "$total" -lt 1 ]; then
      echo "check.sh: contract-graph has 0 edges" >&2
      fail=1
    else
      echo "check.sh: contract-graph has $total edges"
    fi
  else
    echo "check.sh: contract-graph.py failed to run" >&2
    fail=1
  fi
fi

# 5. Smoke test: bin/fm-queue.sh with no args prints the usage banner
#    and exits 2.
if ! out=$(bin/fm-queue.sh 2>&1); then
  if printf '%s' "$out" | grep -q "fm-queue.sh"; then
    echo "check.sh: bin/fm-queue.sh usage banner present"
  else
    echo "check.sh: bin/fm-queue.sh usage banner missing" >&2
    fail=1
  fi
else
  echo "check.sh: bin/fm-queue.sh with no args should exit 2 (usage)" >&2
  fail=1
fi

# 6. Smoke test: bin/fm-status.sh runs and prints a Watcher section.
if out=$(bin/fm-status.sh 2>&1); then
  if printf '%s' "$out" | grep -q '## Watcher'; then
    echo "check.sh: bin/fm-status.sh prints ## Watcher"
  else
    echo "check.sh: bin/fm-status.sh missing ## Watcher section" >&2
    fail=1
  fi
else
  echo "check.sh: bin/fm-status.sh failed" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "check.sh: PASS"
  exit 0
fi
echo "check.sh: FAIL" >&2
exit 1
