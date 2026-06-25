#!/usr/bin/env bash
# Pre-spawn pattern enforcement: validate a brief against the contractor pattern
# before fm-spawn.sh launches the crewmate.
# Usage: fm-pattern-check.sh <task-id> [--scout]
# Exits 0 if brief passes all checks, prints warnings and exits 1 otherwise.
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

check() {
  local label="$1" pattern="$2" hint="$3"
  if grep -q -E "$pattern" "$BRIEF" 2>/dev/null; then
    SCORE=$((SCORE + 1))
  else
    WARNINGS="$WARNINGS  - MISSING: $label ($hint)\n"
  fi
}

check "Goal" "Goal:" "Fill the Goal field: one sentence, what to achieve"
check "Context" "Context:" "Fill the Context field: why this matters"
check "Inputs" "Inputs:" "Fill the Inputs field: specific files/PRs/reports"
check "Output artifact" "Output artifact|Output artifact" "Fill the Output artifact field: exact path or PR URL"
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
  echo "Fix these before spawning, or proceed if the gaps are intentional."
  exit 1
fi

echo "OK: $ID ($KIND) — all pattern checks passed"
exit 0
