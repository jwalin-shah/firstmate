#!/usr/bin/env bash
# bin/fm-reflection-check.sh — post-done reflection / critic pass.
# Reads a crewmate's brief (acceptance criteria) and their last status,
# checks if the output satisfies the acceptance check.
# Used by fm-teardown.sh as the reflection pattern hook.
#
# Usage: bin/fm-reflection-check.sh <task-id>
# Exit 0 = passes (or brief not found), 1 = gaps found.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ID="${1:-}"
[ -n "$ID" ] || { echo "usage: fm-reflection-check.sh <task-id>"; exit 1; }

BRIEF="$FM_ROOT/data/$ID/brief.md"
STATUS_FILE="$FM_ROOT/state/$ID.status"
META="$FM_ROOT/state/$ID.meta"

[ -f "$BRIEF" ] || { echo "reflection: no brief for $ID — skipping"; exit 0; }
[ -f "$STATUS_FILE" ] || { echo "reflection: no status for $ID — skipping"; exit 0; }

# Read the last status line
LAST_STATUS=$(tail -1 "$STATUS_FILE" 2>/dev/null || echo "")

# Read the acceptance check from the brief
ACCEPTANCE=$(sed -n '/^Acceptance check/,/^##/p' "$BRIEF" 2>/dev/null | grep -E '^[0-9]|^[A-Za-z]' | head -5 || echo "")
[ -z "$ACCEPTANCE" ] && ACCEPTANCE=$(rg -A5 "^## Acceptance check" "$BRIEF" 2>/dev/null | grep -E '^\d+\.|^- ' | head -5 || echo "")

# Extract key verbs from acceptance criteria
KEY_TERMS=$(echo "$ACCEPTANCE" | tr '[:upper:]' '[:lower:]' | rg -o '\b(pr|merge|test|run|pass|green|coco-axi|open|push|commit|verify|clean|check)\b' 2>/dev/null | sort -u || echo "")

# Reflection: does the last status mention any of the key terms?
GAPS=""
if [ -n "$KEY_TERMS" ]; then
  STATUS_LOWER=$(echo "$LAST_STATUS" | tr '[:upper:]' '[:lower:]')
  for term in $KEY_TERMS; do
    if ! echo "$STATUS_LOWER" | rg -q "\b$term\b"; then
      GAPS="$GAPS  - status doesn't mention: $term (from acceptance check)\n"
    fi
  done
fi

# Check that the meta has a PR URL for ship tasks
KIND="ship"
if [ -f "$META" ]; then
  KIND=$(rg '^kind=' "$META" 2>/dev/null | cut -d= -f2 || echo "ship")
fi

if [ "$KIND" = "ship" ]; then
  if ! echo "$LAST_STATUS" | rg -q 'https://github.com'; then
    GAPS="$GAPS  - no PR URL in final status (ship tasks require one)\n"
  fi
fi

if [ -n "$GAPS" ]; then
  echo "=== Reflection: $ID ($KIND) ==="
  printf "$GAPS"
  echo "---"
  echo "Acceptance criteria:"
  echo "$ACCEPTANCE" | head -3
  echo "---"
  echo "Crewmate's last status: $LAST_STATUS"
  echo "Reflection: gaps found — review before declaring done."
  exit 1
fi

exit 0
