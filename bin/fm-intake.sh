#!/usr/bin/env bash
# Shell wrapper around the fm-intake binary.
# Accepts task description non-interactively, creates a brief, registers the task,
# and prints the fm-spawn.sh command.
#
# Usage:
#   fm-intake.sh <repo-name> <task-title> [--scout] [task-description]
#   echo "Implement the rate limiter" | fm-intake.sh orbit "Rate limiter"
#   cat task.txt | fm-intake.sh firstmate "Fix bug" --scout
#
# The MLX endpoint fix: fm-intake binary hardcodes :8080, we run on :8082.
# This wrapper starts a temporary port-forward (:8080 -> :8082) so the binary
# can reach the MLX server, or falls back to the fm-brief.sh scaffold without MLX.
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$FM_ROOT/bin/fm-init.sh"
FM_INTAKE_BIN="${FM_INTAKE_BIN:-$HOME/bin/fm-intake}"
KIND=ship

# Parse args
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
    *) POS+=("$a") ;;
  esac
done

if [ ${#POS[@]} -lt 2 ]; then
  echo "Usage: fm-intake.sh <repo-name> <task-title> [--scout] [task-description]" >&2
  echo "       Pipe description via stdin (reads until EOF)." >&2
  exit 1
fi

REPO="${POS[0]}"
TITLE="${POS[1]}"
DESC=""
# If there's a third positional, treat it as the description string
if [ ${#POS[@]} -ge 3 ]; then
  DESC="${POS[2]}"
fi

# If no description from args, read from stdin (pipe mode)
if [ -z "$DESC" ]; then
  if [ ! -t 0 ]; then
    DESC=$(cat)
  else
    echo "error: provide description as 3rd arg or pipe via stdin" >&2
    exit 1
  fi
fi

# Generate a task ID from the title with random suffix
ID=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
ID="${ID}-$(echo $RANDOM | md5sum | head -c 4)"

MODE=$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO" 2>/dev/null || echo "no-mistakes")

# Run the router to classify this task and suggest a harness
ROUTER_OUT=$(echo "$DESC" | "$FM_ROOT/bin/fm-router.sh" "$REPO" "$TITLE" 2>/dev/null || echo '{"harness":"opencode","task_type":"code-change","complexity":"simple"}')
SUGGESTED_HARNESS=$(echo "$ROUTER_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('harness','opencode'))" 2>/dev/null || echo "opencode")
TASK_TYPE=$(echo "$ROUTER_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task_type','code-change'))" 2>/dev/null || echo "code-change")
COMPLEXITY=$(echo "$ROUTER_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('complexity','simple'))" 2>/dev/null || echo "simple")

echo "[router] $TASK_TYPE ($COMPLEXITY) → $SUGGESTED_HARNESS"

echo "[intake] Creating task $ID (repo=$REPO, kind=$KIND, mode=$MODE, harness=$SUGGESTED_HARNESS)"

# Register with fm-tasks first
if command -v fm-tasks >/dev/null 2>&1; then
  # Build meta JSON with description
  META=$(printf '{"desc":%s}' "$(printf '%s' "$DESC" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')")
  if fm-tasks add --id "$ID" --repo "$REPO" --kind "$KIND" --title "$TITLE" --meta "$META" 2>/dev/null; then
    echo "[tasks] Registered $ID in tasks.db"
  else
    echo "[tasks] fm-tasks add failed; trying without meta"
    fm-tasks add --id "$ID" --repo "$REPO" --kind "$KIND" --title "$TITLE" 2>/dev/null || true
  fi
fi

# Create the brief using fm-brief.sh scaffold
SCOUT_FLAG=""
[ "$KIND" = scout ] && SCOUT_FLAG="--scout"
# shellcheck disable=SC2086
"$FM_ROOT/bin/fm-brief.sh" "$ID" "$REPO" $SCOUT_FLAG 2>/dev/null || {
  echo "[warn] fm-brief.sh failed, using fm-intake binary as fallback..."

  # Try the fm-intake binary with MLX proxy
  # Check if MLX is running on :8082
  if curl -sf http://127.0.0.1:8082/v1/models >/dev/null 2>&1; then
    echo "[mlx] MLX running on :8082 — proxying to :8080 for fm-intake"
    # Start a temporary proxy :8080 -> :8082
    socat TCP-LISTEN:8080,reuseaddr,fork TCP:127.0.0.1:8082 &
    SOCAT_PID=$!
    sleep 0.2
    printf "%s\n\n%s\n" "$DESC" "$REPO" | "$FM_INTAKE_BIN" 2>/dev/null || true
    kill "$SOCAT_PID" 2>/dev/null || true
  else
    echo "[mlx] No MLX server on :8082 either — fm-intake will emit placeholders"
    printf "%s\n\n%s\n" "$DESC" "$REPO" | "$FM_INTAKE_BIN" 2>/dev/null || true
  fi
}

BRIEF="$FM_ROOT/data/$ID/brief.md"
if [ ! -f "$BRIEF" ]; then
  echo "error: brief not created at $BRIEF" >&2
  exit 1
fi

# Fill in the contractor fields from the description using a temp Python script
# (avoiding shell-in-Python quoting issues)
TMP_PY=$(mktemp)
cat > "$TMP_PY" << 'PYEOF'
import os, sys, pathlib

brief_path = os.environ['BRIEF_PATH']
title = os.environ.get('TITLE', '')
desc = os.environ.get('DESC', '')
kind = os.environ.get('KIND', 'ship')
repo = os.environ.get('REPO', '')
task_id = os.environ.get('TASK_ID', '')

brief = pathlib.Path(brief_path).read_text()

# Replace the Goal placeholder
goal_marker = '{what to implement or fix, one sentence}'
if goal_marker in brief and title:
    brief = brief.replace(goal_marker, f'{title} — {desc[:200]}', 1)

# Replace Output artifact
output_marker = '{exact path or PR URL}'
if output_marker in brief:
    if kind == 'scout':
        brief = brief.replace(output_marker, f'data/{task_id}/report.md', 1)
    else:
        brief = brief.replace(output_marker, f'PR on {repo}', 1)

# Replace acceptance check
accept_marker = '{verifiable criteria — tests pass, PR open with CI green, etc.}'
if accept_marker in brief:
    brief = brief.replace(accept_marker, 'Task completes successfully. Review by firstmate passes.', 1)

# Insert description into Raw captain input section
raw_input_marker = 'Raw captain input (for reference):\n> '
if raw_input_marker in brief and desc:
    brief = brief.replace(raw_input_marker, f'Raw captain input (for reference):\n> {desc[:200]}', 1)

# Context marker
context_marker = '{why this matters; link to scout report, issue, or session that motivated this}'
if context_marker in brief and desc:
    brief = brief.replace(context_marker, desc[:150], 1)

pathlib.Path(brief_path).write_text(brief)
print(f'[brief] Filled contractor fields in {brief_path}')
PYEOF

BRIEF_PATH="$BRIEF" TITLE="$TITLE" DESC="$DESC" KIND="$KIND" REPO="$REPO" TASK_ID="$ID" python3 "$TMP_PY"
rm -f "$TMP_PY"

echo ""
echo "[intake] Task created"
echo "  ID:       $ID"
echo "  Repo:     $REPO"
echo "  Kind:     $KIND"
echo "  Brief:    $BRIEF"
echo ""
echo "  Next: fm-spawn.sh $ID projects/$REPO $([ "$KIND" = scout ] && echo "--scout")"
echo "  Batch: fm-spawn.sh $ID=projects/$REPO $([ "$KIND" = scout ] && echo "--scout")"
