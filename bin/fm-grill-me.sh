#!/usr/bin/env bash
# bin/fm-grill-me.sh — pre-dispatch checklist (the "grill me" pattern, automated).
# Loads the 5 pattern cards from data/patterns/ and asks the captain (or
# firstmate) to verify a ship task brief is well-scoped before spawn.
#
# Usage:
#   bin/fm-grill-me.sh <brief-file>
#   bin/fm-grill-me.sh --checklist      # just print the checklist
#
# Returns 0 if the brief passes all gates; non-zero otherwise.

set -u

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATTERNS_DIR="$FM_ROOT/data/patterns"
REQUIRED_PATTERNS=(contractor memory routing parallelization reflection)

if [ "${1:-}" = "--checklist" ] || [ -z "${1:-}" ]; then
  echo "=== firstmate grill-me checklist ==="
  echo ""
  echo "Before dispatching a ship task, verify:"
  echo ""
  echo "□ Goal is one sentence, says WHAT not HOW"
  echo "□ Context cites why this matters (link to scout, prior session, or blocker)"
  echo "□ Inputs are specific files/PRs/reports, not 'look at the repo'"
  echo "□ Output artifact is exact: PR URL or file path"
  echo "□ Acceptance check is verifiable: 'tests pass', 'PR is MERGEABLE', 'file X has line N'"
  echo "□ Constraints are explicit: what NOT to touch, mode override"
  echo "□ Routing decision documented: scout vs ship vs parallel (data/patterns/routing.md)"
  echo "□ Memory check: any durable project knowledge that should go in AGENTS.md?"
  echo "□ Parallelization check: any independent subtasks that could ship in parallel?"
  echo "□ Reflection trigger: any review/test/docs that needs explicit attention?"
  echo ""
  echo "Pattern cards: data/patterns/{contractor,memory,routing,parallelization,reflection}.md"
  exit 0
fi

brief="$1"
[ -f "$brief" ] || { echo "error: $brief not found" >&2; exit 1; }

# Check that all 5 pattern cards exist
for p in "${REQUIRED_PATTERNS[@]}"; do
  if [ ! -f "$PATTERNS_DIR/$p.md" ]; then
    echo "  ✗ pattern card missing: $PATTERNS_DIR/$p.md"
    exit 1
  fi
done

# Check that the brief has the contractor 7 fields
required_fields=(Goal Context Inputs "Output artifact" "Acceptance check" Constraints)
missing=0
echo "=== grill-me: $brief ==="
for f in "${required_fields[@]}"; do
  if rg -q "^## ${f}\$" "$brief" 2>/dev/null; then
    echo "  ✓ ${f}: present"
  else
    # Try without "##" prefix (some briefs use just the field name)
    if rg -q "^${f}:" "$brief" 2>/dev/null; then
      echo "  ✓ ${f}: present (inline)"
    else
      echo "  ✗ ${f}: MISSING"
      missing=$((missing+1))
    fi
  fi
done

# Check for empty Goal (a vague goal is the most common brief failure)
goal_line=$(rg -A2 "^## Goal" "$brief" 2>/dev/null | tail -2 | head -1)
if [ -z "$goal_line" ] || [ ${#goal_line} -lt 20 ]; then
  echo "  ✗ Goal is empty or too short (<20 chars)"
  missing=$((missing+1))
fi

# Check that Output artifact names a concrete file/URL
artifact=$(rg -A2 "^## Output artifact" "$brief" 2>/dev/null | tail -2 | head -1)
if ! echo "$artifact" | rg -q '(/|http|bin/|data/)'; then
  echo "  ⚠ Output artifact doesn't reference a concrete file/URL: $artifact"
fi

# Check that Acceptance check has a verification verb
acc=$(rg -A3 "^## Acceptance check" "$brief" 2>/dev/null | tail -3)
if ! echo "$acc" | rg -q -i '(pass|merge|run|verify|test|open)'; then
  echo "  ✗ Acceptance check has no verification verb (pass/merge/run/verify/test/open)"
  missing=$((missing+1))
fi

if [ "$missing" = 0 ]; then
  echo ""
  echo "  brief passes all gates. ready to dispatch."
  exit 0
else
  echo ""
  echo "  brief has $missing issue(s). fix before dispatch."
  exit 1
fi
