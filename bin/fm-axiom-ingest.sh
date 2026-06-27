#!/usr/bin/env bash
# Post-teardown axiom extraction hook.
# Writes the task outcome as a grind-runs-v2 compatible input and calls
# axiom-ingestor --from-runs to extract engineering axioms.
# Called from fm-teardown.sh after the learn-log step.
# Gracefully skips if axiom-ingestor is not available.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$FM_ROOT/state"
ID="${1:-}"
[ -n "$ID" ] || { echo "usage: fm-axiom-ingest.sh <task-id>"; exit 1; }

# Check if axiom-ingestor is available
if ! command -v axiom-ingestor >/dev/null 2>&1; then
  echo "Skipping axiom extraction: axiom-ingestor not found in PATH"
  exit 0
fi

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for $ID" >&2; exit 1; }

# Read task metadata
KIND=$(grep '^kind=' "$META" | cut -d= -f2- || echo "ship")
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || echo "no-mistakes")
LAST_STATUS=$(tail -1 "$STATE/$ID.status" 2>/dev/null || echo "no status")

# Determine verdict from task outcome
case "$LAST_STATUS" in
  *done:*)   VERDICT="PASS" ;;
  *failed:*) VERDICT="REJECT" ;;
  *blocked:*) VERDICT="BLOCKED" ;;
  *)         VERDICT="PASS" ;;
esac

# Create temp grind-runs-v2-compatible input directory
AXIOM_INPUT="$FM_ROOT/data/$ID/axiom-input"
mkdir -p "$AXIOM_INPUT"

# Write decisions.jsonl
echo "{\"lane\":\"$KIND\",\"task\":0,\"verdict\":\"$VERDICT\",\"reason\":\"$LAST_STATUS\",\"impl_tokens\":0,\"total_tokens\":0}" > "$AXIOM_INPUT/decisions.jsonl"

# Write optional adversarial-reviewer.jsonl if a report exists
LANE_DIR="$AXIOM_INPUT/$KIND/task-00"
mkdir -p "$LANE_DIR"
REPORT="$FM_ROOT/data/$ID/report.md"
if [ -f "$REPORT" ]; then
  SUMMARY=$(head -20 "$REPORT" | tr '\n' ' ')
  echo "{\"response\":\"Reflection: $SUMMARY\"}" > "$LANE_DIR/adversarial-reviewer.jsonl"
fi

# Run axiom-ingestor from the data directory so the relative path "axioms/axioms.json" resolves
cd "$FM_ROOT/data"
AXIOM_OUTPUT=$(axiom-ingestor --from-runs "$AXIOM_INPUT" 2>&1) || true

# Parse the output for new axiom count
NEW_AXIOMS=$(echo "$AXIOM_OUTPUT" | grep '^result{status,new_axioms,ingested}:' | awk -F, '{print $2}' || echo "0")
NGESTED=$(echo "$AXIOM_OUTPUT" | grep '^result{status,new_axioms,ingested}:' | awk -F, '{print $3}' || echo "0")

if [ "$NEW_AXIOMS" -gt 0 ] 2>/dev/null; then
  echo "Axiom: $NEW_AXIOMS new axioms extracted (ingested: $NGESTED) for $ID"
else
  echo "Axiom: no new axioms extracted for $ID (no failure patterns)"
fi

# Cleanup temp input
rm -rf "$AXIOM_INPUT"
