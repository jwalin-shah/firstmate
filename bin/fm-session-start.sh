#!/usr/bin/env bash
# bin/fm-session-start.sh — SessionStart hook for firstmate.
# Wired from ~/.claude/settings.json hooks.SessionStart.
# Must complete within 5s timeout. Silent exit 0 on success.
# Combines: backlog regeneration, status report, pattern injection,
# session agenda + track init — all in one shot.
set -euo pipefail

FM_ROOT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$FM_ROOT" ] || [ ! -d "$FM_ROOT/state" ]; then
  FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd 2>/dev/null)" || exit 0
fi

cd "$FM_ROOT" 2>/dev/null || exit 0

# 1. Fleet lock
[ -f "state/.lock" ] && echo "⚠ fleet locked by $(cat state/.lock 2>/dev/null || echo '?')" && exit 0

# 2. Pending wakes
if [ -f "state/.wake-queue" ] && [ -s "state/.wake-queue" ]; then
  echo "📬 $(wc -l < state/.wake-queue) pending wakes — drain with bin/fm-wake-drain.sh"
  exit 0
fi

# 3. Make sure backlog.md is fresh (idempotent, ~30ms warm path)
if [ -x "$FM_ROOT/bin/fm-queue.sh" ]; then
  "$FM_ROOT/bin/fm-queue.sh" to-markdown >/dev/null 2>&1 || true
fi

# 4. Write session agenda + init track
"$FM_ROOT/bin/fm-session-agenda.sh" --write 2>/dev/null || true
"$FM_ROOT/bin/fm-track.sh" list >/dev/null 2>&1 || true

# 5. Print the status report (capped at 8KB for context budget)
if [ -x "$FM_ROOT/bin/fm-status.sh" ]; then
  "$FM_ROOT/bin/fm-status.sh" 2>/dev/null | head -c 8000
fi

echo ""
echo "--- Session track ---"
"$FM_ROOT/bin/fm-track.sh" current 2>/dev/null || echo "(no active track item)"

exit 0
