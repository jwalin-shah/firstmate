#!/usr/bin/env bash
# bin/fm-session-agenda.sh — Create/update session agenda + report deltas.
# Called at SessionStart (--write) to create fresh agenda from backlog + wakes.
# Called from Stop hook (--check-only) to inject agenda delta ONLY when changed.
set -u

FM_ROOT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$FM_ROOT" ] || [ ! -d "$FM_ROOT/state" ]; then
  FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd 2>/dev/null)" || exit 0
fi

cd "$FM_ROOT" 2>/dev/null || exit 0

AGENDA="state/session-agenda.md"
INJECTED_MARKER="state/.agenda-last-injected"

# Mode dispatch
MODE="${1:-write}"

case "$MODE" in
  --check-only)
    # Stop hook: only output agenda if it changed since last injection.
    # This prevents injecting the same 3-5 lines every single turn.
    if [ ! -f "$AGENDA" ]; then
      exit 0  # no agenda yet — first session turn
    fi

    AGENDA_MTIME=$(stat -f '%m' "$AGENDA" 2>/dev/null || echo 0)
    INJECTED_AT=$(cat "$INJECTED_MARKER" 2>/dev/null || echo 0)

    if [ "$AGENDA_MTIME" -gt "$INJECTED_AT" ]; then
      echo "$AGENDA_MTIME" > "$INJECTED_MARKER"
      echo "--- Session Agenda (updated) ---"
      awk 'NR==1 || /^- \[.\] /' "$AGENDA" 2>/dev/null | head -10
      echo "---"
    fi
    exit 0
    ;;

  --write|*)
    # Write fresh agenda
    cat > "$AGENDA" <<AGENDA
# Session Agenda — $(date '+%Y-%m-%d %H:%M')

## This session I commit to:

AGENDA

    # Read in-flight tasks from state/*.meta
    for meta in state/*.meta; do
      [ -f "$meta" ] || continue
      ID=$(basename "$meta" .meta)
      HARNESS=$(grep '^harness=' "$meta" 2>/dev/null | cut -d= -f2 || echo "?")
      KIND=$(grep '^kind=' "$meta" 2>/dev/null | cut -d= -f2 || echo "?")
      echo "- [ ] $ID (${KIND}, ${HARNESS})" >> "$AGENDA"
    done

    # Read queued items from backlog
    if [ -f "data/backlog.md" ]; then
      QUEUED=$(sed -n '/^## Queued/,/^## /p' data/backlog.md 2>/dev/null | grep '^- \[' || true)
      if [ -n "$QUEUED" ]; then
        printf '\n## Queued (from backlog)\n' >> "$AGENDA"
        echo "$QUEUED" >> "$AGENDA"
      fi
    fi

    # Read pending wakes
    if [ -f "state/.wake-queue" ] && [ -s "state/.wake-queue" ]; then
      WAKES=$(wc -l < state/.wake-queue)
      printf '\n**%d pending wakes** — run ! bin/fm-wake-drain.sh\n' "$WAKES" >> "$AGENDA"
    fi

    # Reset injection tracker so --check-only fires on first turn
    echo "0" > "$INJECTED_MARKER"
    exit 0
    ;;
esac
