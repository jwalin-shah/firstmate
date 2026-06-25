#!/usr/bin/env bash
# bin/fm-session-start.sh — SessionStart hook for firstmate.
# Wired from ~/.claude/settings.json hooks.SessionStart.
# Must complete within 5s timeout. Silent exit 0 on success.
set -u

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

exit 0
