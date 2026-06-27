#!/usr/bin/env bash
# Retry handler for failed crewmate spawns.
# Usage: fm-retry.sh <task-id> [--force]
# Reads/writes retry=N and last_error=<reason> in state/<id>.meta.
# Exponential backoff: 30s, 60s, 120s. Max 3 retries per task.
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$FM_ROOT/bin/fm-init.sh"

ID="" FORCE=false
for a in "$@"; do case "$a" in --force) FORCE=true ;; *) ID=$a ;; esac; done
[ -n "$ID" ] || usage "<task-id> [--force]"

META="$STATE/$ID.meta"
[ -f "$META" ] || die "$ID: no meta at $META"

CUR=$(grep '^retry=' "$META" 2>/dev/null | cut -d= -f2 || echo 0)
if [ "${CUR:-0}" -ge 3 ] && ! $FORCE; then
  echo "last_error=max_retries_exceeded" >> "$META"
  echo "$ID: max retries (3) exceeded — marking failed" >&2
  fm-tasks fail "$ID" 2>/dev/null || true
  exit 1
fi

NEXT=$((CUR + 1))
BACKOFF=$((30 * (2 ** CUR)))
grep -v '^retry=' "$META" 2>/dev/null > "$META.tmp" || true
echo "retry=$NEXT" >> "$META.tmp"
mv "$META.tmp" "$META"

echo "$ID: retry $NEXT/3 — waiting ${BACKOFF}s before re-spawn"
sleep "$BACKOFF"

# Kill stale session if pane still exists
SESS="fm-$ID"
PANES=$(mm_list_panes "$SESS" 2>/dev/null || true)
if [ -n "$PANES" ]; then
  echo "$ID: stale session $SESS exists — cleaning up"
  mm_kill_session "$SESS" 2>/dev/null || true
  sleep 1
fi

PROJ=$(grep '^project=' "$META" 2>/dev/null | cut -d= -f2- || true)
HARNESS=$(grep '^harness=' "$META" 2>/dev/null | cut -d= -f2- || true)
KIND=$(grep '^kind=' "$META" 2>/dev/null | cut -d= -f2- || echo "ship")

SPAWN=("$ID" "$PROJ")
[ -n "$HARNESS" ] && SPAWN+=("$HARNESS")
[ "$KIND" = "scout" ] && SPAWN+=("--scout")

echo "re-spawning: fm-spawn.sh ${SPAWN[*]}"
if "$FM_ROOT/bin/fm-spawn.sh" "${SPAWN[@]}"; then
  echo "$ID: re-spawn ok"; exit 0
fi
echo "$ID: re-spawn failed — try again with fm-retry.sh $ID [--force]" >&2
exit 1
