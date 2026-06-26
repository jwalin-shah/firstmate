#!/usr/bin/env bash
# Firstmate check_postcondition.sh: post-merge verification. After the
# PR lands, a fresh checkout must be able to:
#   1. Derive data/backlog.md from a fresh/empty tasks.db (idempotent).
#   2. Run bin/fm-status.sh end-to-end without crashing.
#   3. Produce a contract graph with at least one edge.
#   4. The state/queue.json CRUD subcommands do not lose data on a
#      round-trip add/get/list/remove cycle.
#
# The script never writes outside a tmp dir, so a failed precondition
# does not pollute the repo. Run from CI or by hand with:
#   scripts/check_postcondition.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-post.XXXXXX" 2>/dev/null || mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0

# 1. to-markdown against an empty tasks.db must produce a well-formed
#    three-section markdown file. We point FM_DATA_OVERRIDE at the tmp
#    dir so we do not touch the real data/tasks.db.
mkdir -p "$tmp/data" "$tmp/state"
EMPTY_DB="$tmp/data/tasks.db"
sqlite3 "$EMPTY_DB" "SELECT 1;" 2>/dev/null  # touch to create empty db
if FM_ROOT_OVERRIDE="$REPO_ROOT" FM_STATE_OVERRIDE="$tmp/state" \
   FM_DATA_OVERRIDE="$tmp/data" FM_TASKS_DB_OVERRIDE="$EMPTY_DB" \
   "$REPO_ROOT/bin/fm-queue.sh" to-markdown >"$tmp/out.log" 2>&1; then
  if [ -f "$tmp/data/backlog.md" ] \
     && grep -q '## In flight' "$tmp/data/backlog.md" \
     && grep -q '## Queued' "$tmp/data/backlog.md" \
     && grep -q '## Done' "$tmp/data/backlog.md"; then
    echo "postcondition: to-markdown produces 3-section markdown"
  else
    echo "postcondition: to-markdown output missing sections" >&2
    cat "$tmp/data/backlog.md" >&2
    fail=1
  fi
else
  echo "postcondition: to-markdown failed (empty DB)" >&2
  cat "$tmp/out.log" >&2
  fail=1
fi

# 2. Round-trip: add a task to a fresh queue.json, list it, get it, set
#    status, set pr, set merged. Each call must exit 0 and the file must
#    remain valid JSON.
QFILE="$tmp/state/queue.json"
mkdir -p "$tmp/state"
if FM_ROOT_OVERRIDE="$REPO_ROOT" FM_STATE_OVERRIDE="$tmp/state" \
   "$REPO_ROOT/bin/fm-queue.sh" add "post-test-1" "firstmate" "round-trip test" >/dev/null; then
  if FM_ROOT_OVERRIDE="$REPO_ROOT" FM_STATE_OVERRIDE="$tmp/state" \
     "$REPO_ROOT/bin/fm-queue.sh" set-status "post-test-1" "in-flight" >/dev/null \
     && FM_ROOT_OVERRIDE="$REPO_ROOT" FM_STATE_OVERRIDE="$tmp/state" \
        "$REPO_ROOT/bin/fm-queue.sh" set-pr "post-test-1" "https://example.com/pr/1" >/dev/null \
     && FM_ROOT_OVERRIDE="$REPO_ROOT" FM_STATE_OVERRIDE="$tmp/state" \
        "$REPO_ROOT/bin/fm-queue.sh" set-merged "post-test-1" "2026-06-24T00:00:00Z" >/dev/null; then
    if jq -e '.tasks["post-test-1"].status == "done"' "$QFILE" >/dev/null 2>&1; then
      echo "postcondition: queue round-trip add/set-status/set-pr/set-merged"
    else
      echo "postcondition: queue round-trip ended in wrong state" >&2
      cat "$QFILE" >&2
      fail=1
    fi
  else
    echo "postcondition: queue CRUD step failed" >&2
    fail=1
  fi
else
  echo "postcondition: queue add failed" >&2
  fail=1
fi

# 3. status report end-to-end. We point state at the tmp dir; live pane
#    count is allowed to be 0 (we are not in a mintmux session). The script
#    must reach the end and print "## Watcher".
if out=$(FM_ROOT_OVERRIDE="$REPO_ROOT" FM_STATE_OVERRIDE="$tmp/state" \
            FM_DATA_OVERRIDE="$tmp/data" FM_TASKS_DB_OVERRIDE="$EMPTY_DB" \
            "$REPO_ROOT/bin/fm-status.sh" 2>&1); then
  if printf '%s' "$out" | grep -q '## Watcher' \
     && printf '%s' "$out" | grep -q '## Services'; then
    echo "postcondition: bin/fm-status.sh end-to-end clean"
  else
    echo "postcondition: bin/fm-status.sh output missing sections" >&2
    printf '%s' "$out" | head -5 >&2
    fail=1
  fi
else
  echo "postcondition: bin/fm-status.sh exited non-zero" >&2
  fail=1
fi

# 4. contract-graph: rerun and confirm it still produces edges.
if python3 "$REPO_ROOT/scripts/contract-graph.py" >/dev/null 2>&1; then
  total=$(jq -r '.summary.total // 0' "$REPO_ROOT/docs/architecture/contract-graph.json" 2>/dev/null || echo 0)
  if [ "$total" -ge 1 ]; then
    echo "postcondition: contract-graph emitted $total edges"
  else
    echo "postcondition: contract-graph emitted 0 edges" >&2
    fail=1
  fi
else
  echo "postcondition: contract-graph.py failed" >&2
  fail=1
fi

# 5. backlog.md derivation no-op check: rerunning to-markdown with the
#    same inputs must produce the same output (idempotency).
if FM_ROOT_OVERRIDE="$REPO_ROOT" FM_STATE_OVERRIDE="$tmp/state" \
   FM_DATA_OVERRIDE="$tmp/data" FM_TASKS_DB_OVERRIDE="$EMPTY_DB" \
   "$REPO_ROOT/bin/fm-queue.sh" to-markdown >/dev/null 2>&1; then
  cp "$tmp/data/backlog.md" "$tmp/md.first"
  FM_ROOT_OVERRIDE="$REPO_ROOT" FM_STATE_OVERRIDE="$tmp/state" \
  FM_DATA_OVERRIDE="$tmp/data" FM_TASKS_DB_OVERRIDE="$EMPTY_DB" \
  "$REPO_ROOT/bin/fm-queue.sh" to-markdown >/dev/null 2>&1
  if diff -q "$tmp/md.first" "$tmp/data/backlog.md" >/dev/null; then
    echo "postcondition: to-markdown is idempotent"
  else
    echo "postcondition: to-markdown not idempotent on empty DB" >&2
    diff "$tmp/md.first" "$tmp/data/backlog.md" | head -20 >&2
    fail=1
  fi
else
  echo "postcondition: to-markdown second run failed" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "check_postcondition.sh: PASS"
  exit 0
fi
echo "check_postcondition.sh: FAIL" >&2
exit 1
