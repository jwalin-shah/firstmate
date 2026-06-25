#!/usr/bin/env bash
# Pre-spawn pattern enforcement: validate a brief against ALL active patterns
# before fm-spawn.sh launches the crewmate.
# Updated 2026-06-25: added routing classification, decomposition check, brief length gate.
# Usage: fm-pattern-check.sh <task-id> [--scout]
# Exits 0 if brief passes all checks, exits 1 with warnings otherwise.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ID="${1:-}"
[ -n "$ID" ] || { echo "usage: fm-pattern-check.sh <task-id> [--scout]"; exit 1; }

BRIEF="$FM_ROOT/data/$ID/brief.md"
[ -f "$BRIEF" ] || { echo "FAIL: brief not found at $BRIEF"; exit 1; }

shift
KIND=ship
for a in "$@"; do
  case "$a" in --scout) KIND=scout ;; esac
done

SCORE=0
WARNINGS=""
ERRORS=""

# === PHASE 0: Todo gate (session-level contract) ===
# Firstmate must have an active session todo item before spawning any crewmate.
# This makes the session agenda a structural enforcement, not just injection.
# Override: FM_SKIP_TODO_GATE=1
if [ "${FM_SKIP_TODO_GATE:-0}" != "1" ]; then
  if command -v "$FM_ROOT/bin/fm-track.sh" >/dev/null 2>&1; then
    if ! TODO_OUTPUT=$("$FM_ROOT/bin/fm-track.sh" check-gate 2>&1); then
      ERRORS="$ERRORS  - FAIL: No active session todo. Firstmate must call 'fm-track start <item>' before spawning.\n"
      ERRORS="$ERRORS    $TODO_OUTPUT\n"
    fi
  fi
fi

check() {
  local label="$1" pattern="$2" hint="$3"
  if grep -q -E "$pattern" "$BRIEF" 2>/dev/null; then
    SCORE=$((SCORE + 1))
  else
    WARNINGS="$WARNINGS  - MISSING: $label ($hint)\n"
  fi
}

# === PHASE 1: Routing classification (mandatory for ALL tasks) ===
# Every brief must declare its routing classification so the pre-spawn gate
# can verify the decomposition matches the complexity tier.

ROUTING_CLASS=$(grep -iE '^Classification:' "$BRIEF" 2>/dev/null | head -1 | sed 's/.*Classification:[[:space:]]*//i' | tr '[:upper:]' '[:lower:]' || true)
ROUTING_TIER=$(grep -iE '^Tier:' "$BRIEF" 2>/dev/null | head -1 | sed 's/.*Tier:[[:space:]]*//i' | tr '[:upper:]' '[:lower:]' || true)

if [ -z "$ROUTING_CLASS" ]; then
  ERRORS="$ERRORS  - FAIL: Missing routing classification. Add '## Routing' section with Classification: ship|scout|parallel\n"
fi
if [ -z "$ROUTING_TIER" ]; then
  ERRORS="$ERRORS  - FAIL: Missing routing tier. Add 'Tier: L1|L2|L3|L3+' in the Routing section\n"
fi

# Routing consistency check: scout flag matches routing classification
if [ -n "$ROUTING_CLASS" ]; then
  if [ "$KIND" = "scout" ] && [ "$ROUTING_CLASS" != "scout" ]; then
    ERRORS="$ERRORS  - FAIL: --scout flag passed but Classification is '$ROUTING_CLASS' (should be 'scout')\n"
  fi
  if [ "$KIND" != "scout" ] && [ "$ROUTING_CLASS" = "scout" ]; then
    ERRORS="$ERRORS  - FAIL: No --scout flag but Classification is 'scout' (add --scout to spawn)\n"
  fi
fi

# If any routing errors, exit immediately (no point checking fields)
if [ -n "$ERRORS" ]; then
  echo "=== PATTERN ENFORCEMENT: $ID ($KIND) — ROUTING GATE FAILED ==="
  printf "$ERRORS"
  echo ""
  echo "Consult data/patterns/routing.md before writing the brief."
  echo "Use --skip-routing to bypass this gate (emergency only)."
  exit 1
fi

# === PHASE 2: Brief length gate ===
# Briefs over 30 lines for ship tasks are a sign of monolithic decomposition.
# Require a Decomposition section that lists the independent pieces.
# Scouts can be longer (they're open-ended investigations).

BRIEF_LINES=$(wc -l < "$BRIEF" 2>/dev/null || echo 0)
if [ "$BRIEF_LINES" -gt 30 ] && [ "$KIND" = "ship" ]; then
  HAS_DECOMP=$(grep -qiE '(^## Decomposit|^## Subtask|^## Parallel)' "$BRIEF" 2>/dev/null && echo 1 || echo 0)
  if [ "$HAS_DECOMP" = "0" ]; then
    WARNINGS="$WARNINGS\n  - BRIEF TOO LARGE: $BRIEF_LINES lines. Ship briefs > 30 lines must have a '## Decomposition' section.\n"
    WARNINGS="$WARNINGS    $BRIEF_LINES lines suggests the task should be decomposed into smaller pieces.\n"
    WARNINGS="$WARNINGS    Consult data/patterns/routing.md (Step 2) and data/patterns/parallelization.md.\n"
  fi
fi

# L3+ tier requires decomposition even for shorter briefs
if [ "$ROUTING_TIER" = "l3+" ] || [ "$ROUTING_TIER" = "l3" ]; then
  if [ "$KIND" = "ship" ]; then
    HAS_DECOMP=$(grep -qiE '(^## Decomposit|^## Subtask|^## Parallel)' "$BRIEF" 2>/dev/null && echo 1 || echo 0)
    if [ "$HAS_DECOMP" = "0" ]; then
      WARNINGS="$WARNINGS\n  - FAIL: L3/L3+ Ship tasks must have a '## Decomposition' section listing independent pieces.\n"
      WARNINGS="$WARNINGS    Either decompose the brief or lower the Tier classification.\n"
    fi
  fi
fi

# === PHASE 3: Contractor fields ===
check "Goal" "Goal:" "Fill the Goal field: one sentence, what to achieve"
check "Context" "Context:" "Fill the Context field: why this matters"
check "Inputs" "Inputs:" "Fill the Inputs field: specific files/PRs/reports"
check "Output artifact" "Output artifact" "Fill the Output artifact field: exact path or PR URL"
check "Acceptance check" "Acceptance check" "Fill the Acceptance check: verifiable criteria"

# Scout-specific checks
if [ "$KIND" = "scout" ]; then
  check "Report path" "data/$ID/report.md" "Scout tasks need an Output artifact pointing to report.md"
fi

# Tool hierarchy check — brief should mention coco-axi for research-heavy tasks
if grep -qi 'investigat\|find out\|audit\|search\|look into\|research' "$BRIEF" 2>/dev/null; then
  if ! grep -qi 'coco-axi\|cocoindex\|llm-tldr\|memjuice' "$BRIEF" 2>/dev/null; then
    WARNINGS="$WARNINGS  - SUGGEST: Add coco-axi or llm-tldr to Context/Inputs — first tool for research tasks\n"
  fi
fi

if [ -n "$WARNINGS" ]; then
  echo "=== Pattern Enforcement: $ID ($KIND) ==="
  echo "Score: $SCORE/5"
  printf "$WARNINGS"
  echo "Fix these before spawning, or use FM_SKIP_PATTERN_CHECK=1 to bypass."
  exit 1
fi

echo "OK: $ID ($KIND) — routing=$ROUTING_CLASS tier=$ROUTING_TIER lines=$BRIEF_LINES checks=all-pass"
exit 0
