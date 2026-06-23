#!/usr/bin/env bash
# Shared mintmux (mm) helpers for firstmate.
#
# Mintmux replaces tmux as firstmate's window manager. Each crewmate pane is a
# mintmux session named `fm-<task-id>`. firstmate scripts read pane IDs from
# state/<id>.meta (`pane=` line) and talk to mintmux over its unix socket.
#
# Configuration (all optional):
#   FM_MM_BIN       path to mintmux binary (default: PATH lookup; ~/bin/mintmux wins)
#   FM_MM_CTL       path to mm-ctl binary   (default: <bindir>/mm-ctl)
#   FM_MM_SOCK      unix socket path        (default: $TMPDIR/mintmux.sock or /tmp/mintmux.sock)
#   FM_MM_LOG       mintmux log file        (default: /tmp/mintmux.log)
#   FM_MM_FALLBACK_TMUX=1   force tmux fallback even when mintmux is available
#
# Compatibility: every helper falls back to tmux when mintmux is unavailable
# (binary missing, socket not present, FM_MM_FALLBACK_TMUX=1). This keeps
# existing firstmate workflows intact during the transition.
set -u

FM_MM_DEFAULT_BIN_DIR="${FM_MM_DEFAULT_BIN_DIR:-/Users/jwalinshah/bin}"

# Resolve this lib's location once at source time so no-filter mm_list_panes
# can find state/ when the caller has not exported FM_ROOT. Use BASH_SOURCE
# when present (bash, or zsh in sh/bash emulation), otherwise fall back to
# $0 (zsh when not emulating bash). The default-value form leaves FM_ROOT
# alone when the caller already set it (e.g. fm-watch.sh via FM_ROOT_OVERRIDE).
if [ -z "${FM_ROOT:-}" ]; then
  _fm_mm_self="${BASH_SOURCE[0]:-$0}"
  if [ -n "$_fm_mm_self" ] && [ "$_fm_mm_self" != "fm-mm-lib.sh" ] && [ "$_fm_mm_self" != "sh" ]; then
    case "$_fm_mm_self" in
      /*) _FM_MM_LIB_DIR=$(cd "$(dirname "$_fm_mm_self")" && pwd) ;;
      */*) _FM_MM_LIB_DIR=$(cd "$(dirname "$_fm_mm_self")" && pwd) ;;
      *) _FM_MM_LIB_DIR=$(pwd) ;;
    esac
    FM_ROOT=$(cd "$_FM_MM_LIB_DIR/.." && pwd)
  fi
fi

# Pick the mintmux binary. FM_MM_BIN wins; then ~/bin/mintmux; then PATH.
mm_bin() {
  if [ -n "${FM_MM_BIN:-}" ] && [ -x "$FM_MM_BIN" ]; then
    printf '%s\n' "$FM_MM_BIN"; return 0
  fi
  if [ -x "$FM_MM_DEFAULT_BIN_DIR/mintmux" ]; then
    printf '%s\n' "$FM_MM_DEFAULT_BIN_DIR/mintmux"; return 0
  fi
  command -v mintmux 2>/dev/null || true
}

mm_ctl_bin() {
  if [ -n "${FM_MM_CTL:-}" ] && [ -x "$FM_MM_CTL" ]; then
    printf '%s\n' "$FM_MM_CTL"; return 0
  fi
  local mm
  mm=$(mm_bin) || return 1
  local dir
  dir=$(dirname "$mm")
  if [ -x "$dir/mm-ctl" ]; then
    printf '%s\n' "$dir/mm-ctl"; return 0
  fi
  command -v mm-ctl 2>/dev/null || true
}

mm_sock() {
  if [ -n "${FM_MM_SOCK:-}" ]; then
    printf '%s\n' "$FM_MM_SOCK"; return 0
  fi
  local t="${TMPDIR:-/tmp}"
  printf '%s\n' "$t/mintmux.sock"
}

mm_log() {
  printf '%s\n' "${FM_MM_LOG:-/tmp/mintmux.log}"
}

# mm_available: prints "mintmux" or "tmux" and exits 0 if a usable backend is
# present; non-zero only when both backends are missing.
mm_available() {
  if [ "${FM_MM_FALLBACK_TMUX:-0}" = "1" ]; then
    if command -v tmux >/dev/null 2>&1; then
      printf '%s\n' "tmux"; return 0
    fi
    return 1
  fi
  local bin ctl sock
  bin=$(mm_bin) || true
  ctl=$(mm_ctl_bin) || true
  sock=$(mm_sock)
  if [ -n "$bin" ] && [ -n "$ctl" ] && [ -S "$sock" ]; then
    # Verify socket actually responds to a ping.
    if "$ctl" ping -sock="$sock" >/dev/null 2>&1; then
      printf '%s\n' "mintmux"; return 0
    fi
  fi
  if command -v tmux >/dev/null 2>&1; then
    printf '%s\n' "tmux"; return 0
  fi
  return 1
}

# mm_ensure_daemon: start the mintmux server if its socket is missing. Prints
# the backend ("mintmux" or "tmux") on stdout. When started, returns after a
# successful ping.
mm_ensure_daemon() {
  local backend
  if ! backend=$(mm_available); then
    echo "error: neither mintmux nor tmux is available; install one (see bin/fm-bootstrap.sh)" >&2
    return 1
  fi
  if [ "$backend" = "tmux" ]; then
    printf '%s\n' "tmux"
    return 0
  fi

  local bin sock log
  bin=$(mm_bin)
  sock=$(mm_sock)
  log=$(mm_log)
  local ctl
  ctl=$(mm_ctl_bin)

  if "$ctl" ping -sock="$sock" >/dev/null 2>&1; then
    printf '%s\n' "mintmux"
    return 0
  fi

  # Stale socket: a previous mintmux process died without unlinking it. Drop it.
  if [ -S "$sock" ]; then
    rm -f "$sock" || true
  fi

  # Start the daemon detached. mintmux itself forks; we redirect both fds to
  # the log file. `&` is enough; nohup not needed because the session leader
  # outlives our shell.
  # shellcheck disable=SC2094  # log redirect; only writer is mintmux itself
  "$bin" -sock "$sock" -log "$log" </dev/null >>"$log" 2>&1 &
  disown || true

  # Wait for the socket to come up (or fail loudly).
  for _ in $(seq 1 50); do
    if "$ctl" ping -sock="$sock" >/dev/null 2>&1; then
      printf '%s\n' "mintmux"
      return 0
    fi
    sleep 0.1
  done
  echo "error: mintmux daemon failed to start; see $log" >&2
  return 1
}

# mm_ping: quick reachability check; exits 0 on success.
mm_ping() {
  local ctl sock
  ctl=$(mm_ctl_bin) || return 1
  sock=$(mm_sock)
  "$ctl" ping -sock="$sock" >/dev/null 2>&1
}

# mm_new_session name cmd [dir]: create a session, print its pane id on stdout.
# Uses mm-ctl directly: new-session creates a session with one pane, then
# list-panes returns the pane id (the only pane in a fresh session). We avoid
# the Lua bridge here because scripts must be loaded at server start (-script),
# so ad-hoc mm.list_panes() is not available from mm-ctl.
mm_new_session() {
  local name=$1 cmd=$2 dir=${3:-}
  local ctl sock
  ctl=$(mm_ctl_bin) || return 1
  sock=$(mm_sock)
  # Flags before positional so Go's flag package accepts them.
  local args=(-sock="$sock" -cmd="$cmd")
  [ -n "$dir" ] && args+=(-dir="$dir")
  if ! out=$("$ctl" new-session "${args[@]}" "$name" 2>&1); then
    echo "error: mm_new_session $name failed: $out" >&2
    return 1
  fi
  if [ "$out" != "OK" ]; then
    echo "error: mm_new_session $name did not return OK: $out" >&2
    return 1
  fi
  # list-panes emits exactly one "meta map[panes:[map[id:N window:M]] session:NAME]"
  # line for a session with one pane, followed by "OK".
  local meta
  meta=$("$ctl" list-panes -sock="$sock" -session="$name" 2>&1) || {
    echo "error: list-panes $name failed: $meta" >&2
    return 1
  }
  # Pull the pane id out of the meta line. Format is Go map print:
  #   meta map[panes:[map[id:1 window:1]] session:test-1]
  # We extract the first id:NN token after "map[id:".
  local pid
  pid=$(printf '%s\n' "$meta" | sed -n 's/^meta map\[panes:\[map\[id:\([0-9][0-9]*\).*$/\1/p')
  if [ -z "$pid" ]; then
    echo "error: could not parse pane id from list-panes output for $name: $meta" >&2
    return 1
  fi
  printf '%s\n' "$pid"
}

# mm_kill_session name
mm_kill_session() {
  local name=$1
  local ctl sock
  ctl=$(mm_ctl_bin) || return 1
  sock=$(mm_sock)
  "$ctl" kill-session -sock="$sock" "$name" 2>/dev/null || true
}

# mm_list_panes [session]: prints "<pane_id>\t<session>" per line.
# The meta event is "meta map[panes:[map[id:N window:M]] session:NAME]"
# (Go's fmt %v for a map[string]any). For a fresh session there is exactly
# one pane per window, so we pull the first id:NN and the session:NAME token.
#
# Substr math: `match()` reports RSTART at the START of the matched range.
# For the "session:([^ ]+)" patterns the match starts at "s" of "session",
# so the captured NAME begins RSTART+8 (skip "session:"). For the trailing
# `]`-terminated form we subtract 1 extra char from the length to exclude it.
#
# No-filter mode: mm-ctl currently requires -session for list-panes
# (verified: "send: cmd list_panes: session is required"). When called
# without a session filter, enumerate fm-* sessions from state/<id>.meta
# (recorded by fm-spawn with backend=mintmux) and call list-panes once
# per session. state/ is the local firstmate state dir; FM_STATE_OVERRIDE
# honors the watcher's knob, with a sensible default for direct callers.
mm_list_panes() {
  local filter=${1:-}
  local ctl sock
  ctl=$(mm_ctl_bin) || return 1
  sock=$(mm_sock)
  if [ -n "$filter" ]; then
    "$ctl" list-panes -sock="$sock" -session="$filter" 2>/dev/null | \
      awk '/^meta /{
        # Extract first id:N inside panes:[map[id:N
        pid=""; sess=""
        if (match($0, /id:([0-9]+)/)) { pid = substr($0, RSTART+3, RLENGTH-3) }
        if (match($0, /session:([^ ]+)\]/)) { sess = substr($0, RSTART+8, RLENGTH-9) }
        else if (match($0, /session:([^ ]+)$/)) { sess = substr($0, RSTART+8, RLENGTH-8) }
        if (pid != "" && sess != "") print pid "\t" sess
      }'
    return 0
  fi
  # No-filter path: walk state/<id>.meta for sessions fm-spawn recorded.
  local state_dir="${FM_STATE_OVERRIDE:-$FM_ROOT/state}"
  [ -d "$state_dir" ] || return 0
  local meta ses
  for meta in "$state_dir"/*.meta; do
    [ -f "$meta" ] || continue
    # Only mintmux-backed tasks have a session= line. Use awk (not
    # grep|head|cut) so the ugrep shim some shells install for `grep`
    # doesn't inject a "N matches in M files:" summary header.
    ses=$(awk -F= '/^session=/ { print $2; exit }' "$meta" 2>/dev/null)
    [ -n "$ses" ] || continue
    "$ctl" list-panes -sock="$sock" -session="$ses" 2>/dev/null | \
      awk -v want="$ses" '/^meta /{
        pid=""; sess=""
        if (match($0, /id:([0-9]+)/)) { pid = substr($0, RSTART+3, RLENGTH-3) }
        if (match($0, /session:([^ ]+)\]/)) { sess = substr($0, RSTART+8, RLENGTH-9) }
        else if (match($0, /session:([^ ]+)$/)) { sess = substr($0, RSTART+8, RLENGTH-8) }
        if (pid != "" && sess != "" && sess == want) print pid "\t" sess
      }'
  done
}

# mm_get_pane_for_session name: prints pane id for given session (or empty).
mm_get_pane_for_session() {
  local name=$1
  mm_list_panes "$name" | awk -F'\t' '$2=="'"$name"'" {print $1; exit}'
}

# mm_send_blocking pane text timeout_ms: forwards to mm-send. mm-send waits
# synchronously for the send_ack. Falls back to mm-send's default behavior of
# appending a newline (the harness expects that). `timeout_ms` is currently a
# documentation knob: mm-send doesn't expose a timeout, but the send_ack
# arrives in well under any reasonable pty latency.
mm_send_blocking() {
  local pane=$1 text=$2 # timeout_ms=${3:-5000}
  local sock
  sock=$(mm_sock)
  MM_SEND_BIN=${MM_SEND_BIN:-$(command -v mm-send || true)}
  if [ -z "${MM_SEND_BIN:-}" ]; then
    local ctl_bin
    ctl_bin=$(mm_ctl_bin) || return 1
    MM_SEND_BIN="$(dirname "$ctl_bin")/mm-send"
  fi
  "$MM_SEND_BIN" -sock="$sock" -pane "$pane" -data "$text" 2>&1
}

# mm_capture_pane pane [max_bytes]: prints the pane's scrollback to stdout.
# Uses the mm-ctl capture subcommand (added alongside firstmate's mintmux
# wire-up). Bytes are raw PTY output (CR/LF/ANSI included); callers that
# want plain text pipe through `tr -d '\r' | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'`.
mm_capture_pane() {
  local pane=$1 max=${2:-0}
  local ctl sock
  ctl=$(mm_ctl_bin) || return 1
  sock=$(mm_sock)
  if [ "$max" -gt 0 ] 2>/dev/null; then
    "$ctl" capture -sock="$sock" --bytes "$max" "$pane" 2>/dev/null
  else
    "$ctl" capture -sock="$sock" "$pane" 2>/dev/null
  fi
}