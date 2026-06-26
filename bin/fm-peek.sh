#!/usr/bin/env bash
# Print the tail of a crewmate pane (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <window> [lines=40]
#   <window> may be a bare window name (fm-xyz) or session:window.
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$FM_ROOT/bin/fm-init.sh"
"$FM_ROOT/bin/fm-guard.sh" || true

N=${2:-40}
mm_ping || { echo "error: mintmux is not running; start it with mintmux (see bin/fm-bootstrap.sh)" >&2; exit 1; }

case "$1" in
  *:*) SES=${1%%:*} ;;
  *)   SES=$1 ;;
esac
PANE=$(mm_get_pane_for_session "$SES") || true
if [ -z "$PANE" ]; then
  echo "error: no mintmux pane for session $SES" >&2
  exit 1
fi
# Approximate "last N lines" by capturing a generous byte window and tailing.
# 256 bytes/line gives enough headroom for ANSI escapes.
bytes=$(( N * 256 ))
mm_capture_pane "$PANE" "$bytes" 2>/dev/null | tr -d '\r' | tail -n "$N"