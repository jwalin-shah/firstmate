#!/usr/bin/env bash
# bin/fm-session-start.sh — SessionStart hook for firstmate.
# Wired from ~/.claude/settings.json hooks.SessionStart.
# Runs at every Claude Code session start in any firstmate-managed project.
# Silent exit 0 on success; prints one-liner on any issue.
set -eu

FM_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$FM_ROOT"

# 1. Fleet lock — is another session holding it?
if [ -f "$FM_ROOT/state/.lock" ]; then
  LOCKED_BY=$(cat "$FM_ROOT/state/.lock" 2>/dev/null || echo "unknown")
  echo "⚠️ Fleet locked by $LOCKED_BY — operating read-only"
  exit 0
fi

# 2. Bootstrap — missing tools?
BOOTSTRAP_OUT=$("$FM_ROOT/bin/fm-bootstrap.sh" 2>/dev/null || true)
TOOL_ISSUE=$(echo "$BOOTSTRAP_OUT" | grep -i 'MISSING\|NEEDS_GH_AUTH' | tr '\n' ' ' || true)
if [ -n "$TOOL_ISSUE" ]; then
  echo "🛠 $TOOL_ISSUE"
  exit 0
fi

# 3. Wake queue — any pending wakes?
if [ -f "$FM_ROOT/state/.wake-queue" ] && [ -s "$FM_ROOT/state/.wake-queue" ]; then
  WAKE_COUNT=$(wc -l < "$FM_ROOT/state/.wake-queue" 2>/dev/null || echo 0)
  if [ "$WAKE_COUNT" -gt 0 ]; then
    echo "📬 $WAKE_COUNT pending wakes — run bin/fm-wake-drain.sh"
    exit 0
  fi
fi

# 4. Dead crewmates — any meta files with no live window?
META_COUNT=$(find "$FM_ROOT/state" -name '*.meta' -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$META_COUNT" -gt 0 ]; then
  DEAD_COUNT=0
  for m in "$FM_ROOT/state"/*.meta; do
    [ -f "$m" ] || continue
    WINDOW=$(grep '^window=' "$m" 2>/dev/null | cut -d= -f2 || true)
    if [ -n "$WINDOW" ]; then
      if ! tmux has-session -t "$WINDOW" 2>/dev/null && ! tmux list-windows -a 2>/dev/null | rg -q "$WINDOW"; then
        DEAD_COUNT=$((DEAD_COUNT + 1))
      fi
    fi
  done
  if [ "$DEAD_COUNT" -gt 0 ]; then
    echo "💀 $DEAD_COUNT dead crewmates — run fm-tasks ls to inspect"
    exit 0
  fi
fi

exit 0
