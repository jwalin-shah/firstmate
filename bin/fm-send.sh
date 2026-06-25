#!/usr/bin/env bash
# Send one line of literal text to a crewmate pane, then Enter.
# Usage: fm-send.sh <window> <text...>
#   <window> may be a bare window name (fm-xyz) or session:window. Resolved to
#   a mintmux pane id via mm_get_pane_for_session when the mintmux backend is
#   live; tmux fallback uses send-keys as before.
# Special keys instead of text: fm-send.sh <window> --key Escape   (or Enter, C-c, ...)
set -eu

"$(dirname "${BASH_SOURCE[0]}")/fm-guard.sh" || true
FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-mm-lib.sh
. "$FM_ROOT/bin/fm-mm-lib.sh"

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

BACKEND=$(mm_available 2>/dev/null || echo tmux)

if [ "$BACKEND" = mintmux ]; then
  # mm_get_pane_for_session expects a session name. The session is the part
  # before the colon (if any), or the whole arg if it has no colon (the bare
  # window == session name convention used by fm-spawn for mintmux).
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
    # mm-send always appends a newline by default; special keys (Escape, C-c)
    # must NOT be newline-terminated. --no-newline strips the suffix.
    out=$(MM_SEND_BIN=${MM_SEND_BIN:-$(command -v mm-send || true)} \
      "$(mm_ctl_bin | xargs dirname)/mm-send" \
      -sock="$(mm_sock)" -pane "$PANE" -data "$2" --no-newline 2>&1) || {
        # mm-send may not be on PATH; fall back to MM_SEND_BIN env or sibling
        # of mm-ctl. If that fails too, surface the error.
        echo "error: mm-send for key failed: $out" >&2
        exit 1
      }
  else
    out=$(mm_send_blocking "$PANE" "$*") || { echo "error: mm-send: $out" >&2; exit 1; }
    # Slash commands open a completion popup in some TUIs (verified on codex);
    # submitting too fast selects nothing. Give popups time to settle.
    case "$*" in /*) sleep 1.2 ;; *) sleep 0.3 ;; esac
    mm_send_blocking "$PANE" "" >/dev/null 2>&1 || true
  fi
  echo "send OK"
else
  # tmux fallback: keep the legacy bare-name -> session:window lookup so older
  # callers that pass window= still work.
  case "$1" in
    *:*) : ;;
    *) T=$(tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$T\$" \
         || { echo "error: no window named $T" >&2; exit 1; }) ;;
  esac
  if [ "${1:-}" = "--key" ]; then
    tmux send-keys -t "$T" "$2"
  else
    tmux send-keys -t "$T" -l "$*"
    case "$*" in /*) sleep 1.2 ;; *) sleep 0.3 ;; esac
    tmux send-keys -t "$T" Enter
  fi
fi