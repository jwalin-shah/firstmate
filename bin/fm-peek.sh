#!/usr/bin/env bash
# Print the tail of a crewmate pane (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <window> [lines=40]
#   <window> may be a bare window name (fm-xyz) or session:window.
set -eu

"$(dirname "${BASH_SOURCE[0]}")/fm-guard.sh" || true
FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-mm-lib.sh
. "$FM_ROOT/bin/fm-mm-lib.sh"

N=${2:-40}
BACKEND=$(mm_available 2>/dev/null || echo tmux)

if [ "$BACKEND" = mintmux ]; then
  case "$1" in
    *:*) SES=${1%%:*} ;;
    *)   SES=$1 ;;
  esac
  PANE=$(mm_get_pane_for_session "$SES") || true
  if [ -z "$PANE" ]; then
    echo "error: no mintmux pane for session $SES" >&2
    exit 1
  fi
  # Approximate "last N lines" by capturing a generous byte window and tailing
  # on the byte boundary. mm-ctl's --bytes cap is the cheapest knob we have
  # without a separate "scrollback lines" subcommand; 256 bytes/line * N lines
  # is enough headroom for ANSI escapes. Callers that want exact -S -N like
  # tmux can post-process.
  bytes=$(( N * 256 ))
  mm_capture_pane "$PANE" "$bytes" 2>/dev/null | tr -d '\r' | tail -n "$N"
else
  T=$1
  case "$T" in
    *:*) : ;;
    *) T=$(tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$T\$" \
         || { echo "error: no window named $T" >&2; exit 1; }) ;;
  esac
  tmux capture-pane -p -t "$T" -S -"$N"
fi