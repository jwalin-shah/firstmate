#!/usr/bin/env bash
# Tear down a finished task: return the treehouse worktree, kill the mintmux session,
# clear volatile state, refresh/prune the project's clone for PR-based ship tasks,
# then print a backlog-refresh reminder.
# REFUSES if the worktree holds work not on any remote, because treehouse return
# hard-resets the worktree and kills its processes.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the report at data/<task-id>/report.md is the work
# product - teardown proceeds once the report exists, and refuses without it.
# Usage: fm-teardown.sh <task-id> [--force]
#   --force skips the unpushed-work check. Only use it when the captain has
#   explicitly said to discard the work.
#
# fm-tasks integration: before clearing the meta/status files, transition the
# SQLite AXI task store row for this task. The store mirrors what the markdown
# backlog tracks (queued/inflight/done/failed), so we either `done` (for ship
# tasks whose work landed locally or as a PR) or `fail` (for everything else).
# The call is non-fatal - missing/broken fm-tasks does not block teardown, the
# backlog.md mirror remains canonical for that run. Subcommands:
#   fm-tasks done   <id> --pr <url>|--local
#   fm-tasks fail   <id>
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$FM_ROOT/bin/fm-init.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
STATE="$FM_ROOT/state"
ID=$1
FORCE=${2:-}

META="$STATE/$ID.meta"
[ -f "$META" ] || die "$ID: meta not found"
WT=$(meta_get "$ID" worktree)
T=$(meta_get "$ID" window)
PROJ=$(meta_get "$ID" project)
# backend= and pane=/session= are recorded by fm-spawn when running under mintmux.
# pane= is kept in meta for downstream consumers (fm-peek, fm-send) and shell tooling
# that may want to inspect the live pane id; teardown only needs session= to kill.
BACKEND=$(meta_get "$ID" backend)
[ -n "$BACKEND" ] || BACKEND=mintmux
SESS=$(meta_get "$ID" session)

KIND=$(meta_get "$ID" kind)
[ -n "$KIND" ] || KIND=ship
MODE=$(meta_get "$ID" mode)
[ -n "$MODE" ] || MODE=no-mistakes

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

if [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
  if [ "$KIND" = scout ]; then
    # Scout worktrees are scratch by contract, but only once the deliverable exists.
    REPORT="$FM_ROOT/data/$ID/report.md"
    if [ ! -f "$REPORT" ]; then
      echo "REFUSED: scout task $ID has no report at $REPORT." >&2
      echo "The report is the work product. Have the crewmate write it (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    fi
  elif [ "$MODE" = local-only ]; then
    # local-only ships have no remote, so the "on a remote" test never passes.
    # The work is safe once it is merged into the local default branch (firstmate
    # does that merge on the captain's approval). Refuse until then.
    DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; exit 1; }
    dirty=$(git -C "$WT" status --porcelain 2>/dev/null | grep -vE '^\?\? \.claude/' | head -1 || true)
    unmerged=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null | head -5 || true)
    if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
      echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT." >&2
      [ -n "$dirty" ] && echo "uncommitted changes present" >&2
      [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
      echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or get the captain's explicit OK to discard, then --force." >&2
      exit 1
    fi
  else
    # The fm-spawn hook file is ours, never work product; ignore it in the dirty check.
    dirty=$(git -C "$WT" status --porcelain 2>/dev/null | grep -vE '^\?\? \.claude/' | head -1 || true)
    unpushed=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null | head -5 || true)
    if [ -n "$dirty" ] || [ -n "$unpushed" ]; then
      echo "REFUSED: worktree $WT has work not on any remote." >&2
      [ -n "$dirty" ] && echo "uncommitted changes present" >&2
      [ -n "$unpushed" ] && printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      echo "Push the branch (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    fi
  fi
fi

# Capture learn-log signals BEFORE the worktree is returned (line ~107) and state is
# cleared (the status file is removed below). Three signals decide whether the task
# produced anything worth recording:
#   (a) STATUS_MEANINGFUL - the status file carries non-whitespace content
#   (b) HAD_COMMITS        - the crewmate created commits beyond the worktree's base
#   (c) a scout report     - checked later (data/ is not cleared by teardown)
# When all three are absent the task produced nothing, so the learn-log append is
# skipped. LAST_STATUS is captured here too because the status file is deleted before
# the learn block runs.
STATUS_FILE="$STATE/$ID.status"
LAST_STATUS=$(tail -1 "$STATUS_FILE" 2>/dev/null || echo "no status")
STATUS_MEANINGFUL=""
if [ -s "$STATUS_FILE" ] && grep -q '[^[:space:]]' "$STATUS_FILE" 2>/dev/null; then
  STATUS_MEANINGFUL=1
fi
HAD_COMMITS=""
if [ -d "$WT" ]; then
  LEARN_DEFAULT=$(default_branch 2>/dev/null || true)
  if [ -n "$LEARN_DEFAULT" ]; then
    HAD_COMMITS=$(git -C "$WT" log --oneline HEAD --not "$LEARN_DEFAULT" -- 2>/dev/null | head -1 || true)
  fi
fi

# Best-effort: drop the local task branch so the shared repo does not accumulate refs.
if [ -d "$WT" ]; then
  branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  if [ "$branch" != "HEAD" ]; then
    if git -C "$WT" checkout --detach -q 2>/dev/null; then
      git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
    fi
  fi
  # Remove our hook file so a reused pool worktree cannot fire signals for a dead task.
  rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js"
  # Kills remaining processes in the worktree (including the agent), resets, returns
  # to pool. treehouse resolves the pool from the working directory, so run it from
  # the project.
  ( cd "$PROJ" && treehouse return --force "$WT" )
fi

# Teardown the mintmux session. Tolerates a session already gone (re-run case).
if [ -n "$SESS" ]; then
  mm_kill_session "$SESS" 2>/dev/null || true
fi
rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.check.sh" "$STATE/$ID.meta" "$STATE/$ID.pi-ext.ts"

# Best-effort: finalize the SQLite task store row. For ship tasks whose work landed
# locally (no PR) we mark done --local; PR-based ships are recorded with --pr when
# fm-pr-check populated state/$ID.meta pr=, otherwise we fall through to fail so the
# row does not stay inflight. Scout and any other teardown without a clean ship path
# also goes to fail. Errors are swallowed - a missing/broken fm-tasks never blocks
# teardown, the markdown backlog stays canonical for that run.
if [ "$KIND" = scout ]; then
  fm-tasks fail "$ID" >/dev/null 2>&1 || true
else
  PR=$(grep '^pr=' "$STATE/$ID.meta" 2>/dev/null | cut -d= -f2- || true)
  if [ -n "$PR" ]; then
    fm-tasks done "$ID" --pr "$PR" >/dev/null 2>&1 || true
  elif [ "$MODE" = local-only ]; then
    fm-tasks done "$ID" --local >/dev/null 2>&1 || true
  else
    fm-tasks fail "$ID" >/dev/null 2>&1 || true
  fi
fi
# pr= was read from meta; meta is gone after the rm above, so clean up the temp var.
unset PR
if [ "$KIND" != scout ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
echo "teardown $ID complete (window $T, worktree $WT, backend=$BACKEND)"

# Reflection pattern: check crewmate output against acceptance criteria
if "$FM_ROOT/bin/fm-reflection-check.sh" "$ID" 2>/dev/null; then
  printf '%s\n' "✅ Reflection: $ID passes acceptance check"
else
  REFLECTION_ISSUES=$("$FM_ROOT/bin/fm-reflection-check.sh" "$ID" 2>&1 || true)
  printf '%s\n' "⚠️ Reflection: $ID has gaps — review recommended"
  printf '%s\n' "$REFLECTION_ISSUES" | head -5
fi

# Post-task learn: append a structured entry to data/learn-log.md, but only when the
# task produced meaningful outcome data. Skip when the status file had no content, no
# scout report exists, and the crewmate made no commits beyond its base - an empty or
# aborted task has nothing to learn from. LAST_STATUS / STATUS_MEANINGFUL / HAD_COMMITS
# were captured above, before the worktree and status file were cleared.
LEARN_LOG="$FM_ROOT/data/learn-log.md"
REPORT_SUMMARY=""
HAS_REPORT=""
if [ -f "$FM_ROOT/data/$ID/report.md" ]; then
  HAS_REPORT=1
  REPORT_SUMMARY=$(head -5 "$FM_ROOT/data/$ID/report.md" 2>/dev/null || true)
fi
if [ -z "$STATUS_MEANINGFUL" ] && [ -z "$HAS_REPORT" ] && [ -z "$HAD_COMMITS" ]; then
  printf '%s\n' "📚 Learn: skipped — task $ID produced no status, report, or commits"
else
  {
    echo ""
    echo "## $(date -u +%Y-%m-%d) — $ID ($KIND, $MODE)"
    echo "project: $PROJ"
    echo "outcome: $LAST_STATUS"
    [ -n "$REPORT_SUMMARY" ] && printf 'report-summary: %s\n' "$REPORT_SUMMARY"
    echo "---"
  } >> "$LEARN_LOG"
  printf '%s\n' "📚 Learn: appended task outcome to data/learn-log.md"
fi

# Axiom extraction: mine engineering axioms from task outcome
"$FM_ROOT/bin/fm-axiom-ingest.sh" "$ID"

# Mark the task done in fm-tasks (tasks.db is the durable queue; backlog.md is derived)
if command -v fm-tasks >/dev/null 2>&1; then
  fm-tasks done "$ID" 2>/dev/null && printf '%s\n' "✅ fm-tasks: marked $ID done" || true
fi

# Surface unblocked tasks
UNBLOCKED=$(fm-tasks unblocked-by "$ID" 2>/dev/null || true)
if [ -n "$UNBLOCKED" ]; then
  printf '%s\n' "🔓 Unblocked by $ID:"
  printf '%s\n' "$UNBLOCKED"
fi

printf '%s\n' "🌱 Queue: $ID finished — re-scan tasks.db for unblocked or time-due items and dispatch what's ready."
