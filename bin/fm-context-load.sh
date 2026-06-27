#!/usr/bin/env bash
# fm-context-load.sh — print the last N context entries for a project
#
# Usage: fm-context-load.sh <project-name> [count]
#   count: number of entries to show (default: 5; max: 20)
#
# Output format: markdown rendering of context entries.
# Called by fm-brief.sh to inject per-project context into crewmate briefs.
# Called by firstmate directly to recall what happened in a project.
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROJECT="${1:?usage: fm-context-load.sh <project-name> [count]}"
COUNT="${2:-5}"
[ "$COUNT" -gt 20 ] && COUNT=20

CONTEXT_FILE="$FM_ROOT/data/context/$PROJECT.md"

if [ ! -f "$CONTEXT_FILE" ]; then
  exit 0
fi

python3 - "$CONTEXT_FILE" "$COUNT" <<'PYEOF'
import sys
path, n = sys.argv[1], int(sys.argv[2])
with open(path) as f:
    text = f.read()
# Split on --- separators, drop empty leading/trailing chunks
entries = [e.strip() for e in text.split('---') if e.strip()]
for e in entries[-n:]:
    print(e)
    print('---')
PYEOF
