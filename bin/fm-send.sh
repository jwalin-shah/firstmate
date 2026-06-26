#!/usr/bin/env bash
# Send one line of literal text to a crewmate pane, then Enter.
# Usage: fm-send.sh <window> <text...>
#   <window> may be a bare window name (fm-xyz) or session:window. Resolved to
#   a mintmux pane id via mm_get_pane_for_session when the mintmux backend is
#   live; tmux fallback uses send-keys as before.
# Special keys instead of text: fm-send.sh <window> --key Escape   (or Enter, C-c, ...)
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$FM_ROOT/bin/fm-init.sh"
"$FM_ROOT/bin/fm-guard.sh" || true

# resolve name: on mintmux, "<window>" or "<session>:<window>" -> pane id;
# on tmux, return session:window (legacy) unchanged.
resolve() {
  case "$1" in
    *:*) echo "$1" ;;
    *)   echo "$1" ;;
  esac
}

T=$(resolve "$1")
shift

mm_ping || { echo "error: mintmux is not running; start it with mintmux (see bin/fm-bootstrap.sh)" >&2; exit 1; }

# mm_get_pane_for_session expects a session name (bare or session:window).
case "$T" in
  *:*) SES=${T%%:*} ;;
  *)   SES=$T ;;
esac
PANE=$(mm_get_pane_for_session "$SES") || true
if [ -z "$PANE" ]; then
  echo "error: no mintmux pane for session $SES" >&2
  exit 1
fi
if [ "${1:-}" = "--key" ]; then
  # Special keys (Escape, C-c) must NOT be newline-terminated.
  out=$(MM_SEND_BIN=${MM_SEND_BIN:-$(command -v mm-send || true)} \
    "$(mm_ctl_bin | xargs dirname)/mm-send" \
    -sock="$(mm_sock)" -pane "$PANE" -data "$2" --no-newline 2>&1) || {
      echo "error: mm-send for key failed: $out" >&2
      exit 1
    }
else
  out=$(mm_send_blocking "$PANE" "$*") || { echo "error: mm-send: $out" >&2; exit 1; }
  # Slash commands open a completion popup in some TUIs; submitting too fast selects nothing.
  case "$*" in /*) sleep 1.2 ;; *) sleep 0.3 ;; esac
  mm_send_blocking "$PANE" "" >/dev/null 2>&1 || true
fi
echo "send OK"