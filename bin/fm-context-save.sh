#!/usr/bin/env bash
# fm-context-save.sh — append a structured context entry to data/context/<project>.md
#
# Usage: fm-context-save.sh <project-name> <task-id> <key-learnings> <status> [pr-link]
#   key-learnings: short single-line summary (or use --file for multiline)
#   status: done, failed, scout, needs-decision
#   pr-link: optional URL or "local"
#
# Or via stdin:
#   echo "key learnings" | fm-context-save.sh <project> <task-id> - <status> [pr-link]
#
# Creates data/context/<project>.md and data/context/ if they don't exist.
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$FM_ROOT/bin/fm-init.sh"

PROJECT="${1:?usage: fm-context-save.sh <project-name> <task-id> <key-learnings> <status> [pr-link]}"
TASK_ID="${2:?}"
LEARNINGS="${3:-}"
STATUS="${4:-}"
PR_LINK="${5:-}"

CONTEXT_DIR="$FM_ROOT/data/context"
CONTEXT_FILE="$CONTEXT_DIR/$PROJECT.md"
mkdir -p "$CONTEXT_DIR"

DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

{
  echo ""
  echo "## $DATE — $TASK_ID"
  echo "status: $STATUS"
  [ -n "$PR_LINK" ] && echo "pr: $PR_LINK"
  echo ""
  echo "$LEARNINGS"
  echo ""
  echo "---"
} >> "$CONTEXT_FILE"

printf '%s\n' "📚 Context saved: $CONTEXT_FILE ($TASK_ID)"
