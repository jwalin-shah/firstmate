#!/usr/bin/env bash
# fm-router.sh — Task classifier + harness selector for firstmate.
# Every task goes through this before intake. Routes to the right
# harness (opencode vs ctoken) and model based on task characteristics.
# Learns from captain overrides over time.
#
# Usage:
#   fm-router.sh <repo> <title> <description>
#   echo "description" | fm-router.sh <repo> <title>
#
# Output: JSON with classification, harness, model, and reasoning.

set -uo pipefail
FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$FM_ROOT/data"
ROUTER_DB="$DATA/router.db"
mkdir -p "$DATA"

# ── Classification rules ─────────────────────────────────────────────────
# These are seeded defaults. Over time, captain overrides train them.

# Task types and their typical harness (using function instead of assoc array)
task_harness() {
  case "$1" in
    code-change)    echo "opencode" ;;
    bug-fix)        echo "ctoken" ;;
    research)       echo "opencode" ;;
    refactor)       echo "opencode" ;;
    config)         echo "opencode" ;;
    investigation)  echo "ctoken" ;;
    scout)          echo "opencode" ;;
    *)              echo "opencode" ;;
  esac
}

# Complexity indicators — words that suggest a task is complex
COMPLEX_WORDS="debug|investigat|root.cause|architectur|design|complex|multi.step|integration|refactor|migrate|optimize|security"

# Simple indicators — words that suggest a task is straightforward
SIMPLE_WORDS="typo|readme|config|bump|version|pin|gitignore|comment|rename|format|chore|docs?"

# ── SQLite for learning from overrides ────────────────────────────────────

init_db() {
  sqlite3 "$ROUTER_DB" "
    CREATE TABLE IF NOT EXISTS routes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      task_type TEXT NOT NULL,
      complexity TEXT NOT NULL DEFAULT 'simple',
      suggested_harness TEXT NOT NULL,
      overridden_harness TEXT,
      captain_approved INTEGER DEFAULT 1,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      task_title TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_routes_type ON routes(task_type);
  " 2>/dev/null || true
}

record_route() {
  local task_type="$1" complexity="$2" suggested="$3" title="$4"
  sqlite3 "$ROUTER_DB" "
    INSERT INTO routes (task_type, complexity, suggested_harness, task_title)
    VALUES ('$task_type', '$complexity', '$suggested', '${title//\'/''}');
  " 2>/dev/null || true
}

record_override() {
  local task_type="$1" old_harness="$2" new_harness="$3"
  sqlite3 "$ROUTER_DB" "
    UPDATE routes SET overridden_harness='$new_harness', captain_approved=0
    WHERE task_type='$task_type' AND suggested_harness='$old_harness'
    AND overridden_harness IS NULL
    ORDER BY created_at DESC LIMIT 1;
  " 2>/dev/null || true
}

get_learned_harness() {
  local task_type="$1"
  # Check if captain has consistently overridden this task type
  local total=$(sqlite3 "$ROUTER_DB" "SELECT COUNT(*) FROM routes WHERE task_type='$task_type';" 2>/dev/null || echo 0)
  local overrides=$(sqlite3 "$ROUTER_DB" "SELECT COUNT(*) FROM routes WHERE task_type='$task_type' AND captain_approved=0;" 2>/dev/null || echo 0)
  
  if [ "$total" -gt 2 ] && [ "$overrides" -gt "$((total / 2))" ]; then
    # Captain overrides more than half the time — learn the override
    local learned=$(sqlite3 "$ROUTER_DB" "SELECT overridden_harness FROM routes WHERE task_type='$task_type' AND overridden_harness IS NOT NULL ORDER BY created_at DESC LIMIT 1;" 2>/dev/null || echo "")
    echo "$learned"
  fi
}

# ── Classification ────────────────────────────────────────────────────────

classify() {
  local repo="$1" title="$2" description="$3"
  local combined="$title $description"
  combined=$(echo "$combined" | tr '[:upper:]' '[:lower:]')
  
  # Detect task type from keywords
  local task_type="code-change"
  if echo "$combined" | grep -qi "bug\|fix\|error\|crash\|broken\|fail"; then
    task_type="bug-fix"
  elif echo "$combined" | grep -qi "research\|investigat\|learn\|understand\|explore\|audit"; then
    task_type="research"
  elif echo "$combined" | grep -qi "refactor\|clean\|simplif\|consolidat"; then
    task_type="refactor"
  elif echo "$combined" | grep -qi "config\|setup\|install\|deploy\|bootstrap"; then
    task_type="config"
  elif echo "$combined" | grep -qi "scout\|report\|investigat"; then
    task_type="scout"
  fi
  
  # Detect complexity
  local complexity="simple"
  local complex_score=0
  local simple_score=0
  
  # Count complexity and simplicity word matches
  for w in debug investigat root.cause architectur design complex multi.step integration refactor migrat optimiz security; do
    echo "$combined" | grep -qi "$w" && complex_score=$((complex_score + 1))
  done
  for w in typo readme config bump version pin gitignore comment rename format chore doc; do
    echo "$combined" | grep -qi "$w" && simple_score=$((simple_score + 1))
  done
  
  # Repo-based heuristics
  case "$repo" in
    *machine-bootstrap*) complex_score=$((complex_score + 1)) ;;
    *firstmate*) complex_score=$((complex_score + 1)) ;;
    *treehouse*|*mintmux*) complex_score=$((complex_score + 2)) ;;
  esac
  
  [ "$complex_score" -gt "$simple_score" ] && complexity="complex"
  
  # Pick harness
  local default=$(task_harness "$task_type")
  local harness="$default"
  [ "$complexity" = "complex" ] && harness="ctoken"
  
  # Check for learned overrides
  local learned=$(get_learned_harness "$task_type")
  [ -n "$learned" ] && harness="$learned"
  
  # Output JSON
  cat <<JSON
{
  "task_type": "$task_type",
  "complexity": "$complexity",
  "harness": "$harness",
  "reasoning": "classified as $task_type ($complexity) → $harness"
}
JSON
  
  record_route "$task_type" "$complexity" "$harness" "$title"
}

# ── Main ──────────────────────────────────────────────────────────────────

init_db

if [ $# -lt 2 ]; then
  echo "Usage: fm-router.sh <repo> <title> [description]" >&2
  echo "       echo 'description' | fm-router.sh <repo> <title>" >&2
  exit 1
fi

REPO="$1"
TITLE="$2"
DESC="${3:-$(cat)}"

classify "$REPO" "$TITLE" "$DESC"
