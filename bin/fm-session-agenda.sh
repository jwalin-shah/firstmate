#!/usr/bin/env bash
# fm-session-agenda.sh — session wrap-up check (Stop hook) and agenda init (SessionStart)
#
# --write      : write session start agenda (noop if nothing queued)
# --check-only : print reminder if tasks are in-flight (used by Stop hook)
set -euo pipefail

FM_ROOT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$FM_ROOT" ] || [ ! -d "$FM_ROOT/state" ]; then
  FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd 2>/dev/null)" || exit 0
fi

BACKLOG="$FM_ROOT/data/backlog.md"

case "${1:-}" in
  --write)
    # Agenda init at session start: regenerate backlog from db if possible
    if [ -x "$FM_ROOT/bin/fm-queue.sh" ]; then
      "$FM_ROOT/bin/fm-queue.sh" to-markdown 2>/dev/null || true
    fi
    ;;
  --check-only)
    # At session end: warn if in-flight tasks exist
    if [ -f "$BACKLOG" ] && grep -q "^- \[ \]" "$BACKLOG" 2>/dev/null; then
      inflight=$(grep -c "^- \[ \]" "$BACKLOG" 2>/dev/null || echo 0)
      if [ "$inflight" -gt 0 ]; then
        echo "⚠ $inflight task(s) still in flight — check backlog before closing session"
      fi
    fi
    ;;
esac
