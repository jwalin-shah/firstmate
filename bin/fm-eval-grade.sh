#!/usr/bin/env bash
# Grade a completed firstmate task and write data/evals/<id>.json.
#
# Usage: fm-eval-grade.sh <task-id> [--grader <human|auto|llm-judge>]
#
# Grade schema (data/evals/<id>.json):
#   id            task id
#   grader        who/what assigned the grade: "auto" | "human" | "llm-judge"
#   grade         "pass" | "fail" | "partial" | "needs-review"
#   runs          number of times this task has been attempted (1 by default;
#                 delete the .json and re-run fm-eval-grade to record a retry)
#   evidence      raw signals used to determine the grade
#   graded_at     ISO-8601 UTC timestamp
#
# Auto-grade logic (grader=auto):
#   - tasks.db status=done AND report exists           → pass
#   - tasks.db status=done, no report, scout kind      → needs-review
#   - tasks.db status=failed                           → fail
#   - learn-log last_status starts with "done:"       → pass
#   - learn-log last_status starts with "failed:"     → fail
#   - everything else (no status, inflight)            → needs-review
#
# Note: learn-log entries created before 2026-06-27 all show outcome="no status"
# due to a bug where the status file was read after deletion. Only tasks torn down
# after commit 50a487a produce reliable learn-log outcomes. Use tasks.db as the
# primary signal for historical tasks.
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$FM_ROOT/bin/fm-init.sh"

ID="${1:-}"
[ -n "$ID" ] || die "usage: fm-eval-grade.sh <task-id> [--grader auto|human|llm-judge]"

GRADER="auto"
for arg in "$@"; do
  case "$arg" in --grader) shift; GRADER="${1:-auto}" ;; esac
done

EVAL_DIR="$FM_ROOT/data/evals"
mkdir -p "$EVAL_DIR"
OUT="$EVAL_DIR/$ID.json"

DB="$FM_ROOT/data/tasks.db"
LEARN_LOG="$FM_ROOT/data/learn-log.md"

# Pull task row from SQLite
db_status=""
db_kind=""
db_report_path=""
db_pr_url=""
if [ -f "$DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  row=$(sqlite3 "$DB" "SELECT status,kind,COALESCE(report_path,''),COALESCE(pr_url,'') FROM tasks WHERE id='$ID' LIMIT 1;" 2>/dev/null || true)
  if [ -n "$row" ]; then
    db_status=$(printf '%s' "$row" | cut -d'|' -f1)
    db_kind=$(printf '%s'   "$row" | cut -d'|' -f2)
    db_report_path=$(printf '%s' "$row" | cut -d'|' -f3)
    db_pr_url=$(printf '%s' "$row" | cut -d'|' -f4)
  fi
fi

# Pull outcome from learn-log (last matching entry)
learn_outcome="no status"
if [ -f "$LEARN_LOG" ]; then
  learn_outcome=$(awk "/^## [0-9]{4}-[0-9]{2}-[0-9]{2}.*— $ID /,/^---$/" "$LEARN_LOG" \
    | grep '^outcome:' | tail -1 | sed 's/^outcome: *//' || true)
  [ -n "$learn_outcome" ] || learn_outcome="no status"
fi

# Check report exists
has_report="false"
report_path=""
if [ -n "$db_report_path" ] && [ -f "$db_report_path" ]; then
  has_report="true"
  report_path="$db_report_path"
elif [ -f "$FM_ROOT/data/$ID/report.md" ]; then
  has_report="true"
  report_path="$FM_ROOT/data/$ID/report.md"
fi

# Determine previous runs count (increment if re-grading)
prev_runs=0
if [ -f "$OUT" ] && command -v python3 >/dev/null 2>&1; then
  prev_runs=$(python3 -c "import json,sys; d=json.load(open('$OUT')); print(d.get('runs',1))" 2>/dev/null || echo 0)
fi
runs=$(( prev_runs + 1 ))

# Auto-grade
grade="needs-review"
if [ "$GRADER" = "auto" ]; then
  if [ "$db_status" = "failed" ]; then
    grade="fail"
  elif [ "$db_status" = "done" ] && [ "$has_report" = "true" ]; then
    grade="pass"
  elif [ "$db_status" = "done" ] && [ "$db_kind" = "ship" ] && [ -n "$db_pr_url" ]; then
    grade="pass"
  elif [ "$db_status" = "done" ]; then
    grade="partial"
  else
    case "$learn_outcome" in
      done:*)   grade="pass" ;;
      failed:*) grade="fail" ;;
    esac
  fi
fi

graded_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

python3 - <<EOF
import json
def nonempty(s): return s if s else None
data = {
    "id": "$ID",
    "grader": "$GRADER",
    "grade": "$grade",
    "runs": $runs,
    "evidence": {
        "db_status": nonempty("$db_status"),
        "db_kind": nonempty("$db_kind"),
        "db_pr_url": nonempty("$db_pr_url"),
        "learn_outcome": "$learn_outcome",
        "has_report": "$has_report" == "true",
        "report_path": nonempty("$report_path"),
    },
    "graded_at": "$graded_at",
}
with open("$OUT", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"grade=$grade grader=$GRADER runs=$runs -> $OUT")
EOF
