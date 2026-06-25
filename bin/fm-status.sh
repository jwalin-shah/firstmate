#!/usr/bin/env bash
# Firstmate status report. Prints a structured, TUI-free summary suitable for
# paste into chat, capture by the SessionStart hook, or attach to a handoff.
# Sections: services, in-flight, queue head, recent done, watcher state.
# Designed to never include raw TUI escape sequences (no capture-pane output)
# because the captain has been getting paged with mm-ctl capture noise and
# wants a clean signal at a glance.
#
# Usage:
#   fm-status.sh                  # full report to stdout
#
# Reads from data/tasks.db (via the fm-tasks binary) +
# state/.last-watcher-beat. Never writes; this is observation only.
set -eu

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_ROOT/state}"

# Resolve tools once. We prefer fm-tasks (single binary, no SQL knowledge
# needed in the script) and fall back to sqlite3 if it's not on PATH.
have_fm_tasks=0
command -v fm-tasks >/dev/null 2>&1 && have_fm_tasks=1

# Backend detection: mm-ctl + socket, or tmux, or nothing.
watcher_backend=none
if command -v mm-ctl >/dev/null 2>&1 && [ -S "${TMPDIR:-/tmp}/mintmux.sock" ] \
   && mm-ctl ping -sock="${TMPDIR:-/tmp}/mintmux.sock" >/dev/null 2>&1; then
  watcher_backend=mintmux
elif command -v tmux >/dev/null 2>&1; then
  watcher_backend=tmux
fi

# Count of live crewmate panes (sessions prefixed fm-).
live_panes=0
case "$watcher_backend" in
  mintmux)
    live_panes=$(mm-ctl list-panes -sock="${TMPDIR:-/tmp}/mintmux.sock" 2>/dev/null \
                 | awk '{print $NF}' | grep -c '^fm-' || true)
    ;;
  tmux)
    live_panes=$(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null \
                 | grep -c ':fm-' || true)
    ;;
esac

# Watcher liveness: how stale is .last-watcher-beat?
watcher_age=-1
if [ -e "$STATE/.last-watcher-beat" ]; then
  if [ "$(uname)" = Darwin ]; then
    watcher_age=$(( $(date +%s) - $(stat -f %m "$STATE/.last-watcher-beat" 2>/dev/null || echo 0) ))
  else
    watcher_age=$(( $(date +%s) - $(stat -c %Y "$STATE/.last-watcher-beat" 2>/dev/null || echo 0) ))
  fi
fi
if [ "$watcher_age" -ge 0 ] 2>/dev/null; then
  if [ "$watcher_age" -lt 60 ]; then watcher_state="alive (${watcher_age}s)"
  elif [ "$watcher_age" -lt 300 ]; then watcher_state="stale (${watcher_age}s)"
  else watcher_state="dead (${watcher_age}s)"; fi
else
  watcher_state="no beat recorded"
fi

# Section: services alive.
printf '%s\n' '## Services'
printf '%s\n' "- watcher backend: $watcher_backend"
printf '%s\n' "- watcher state:   $watcher_state"
printf '%s\n' "- live crewmates:  $live_panes"

# fm-tasks ls --fields prints "id,kind,repo,..." per line. The
# "tasks[N]{...}:" header from the multi-field path is suppressed by the
# --fields flag, but we still drop it defensively for older versions.
inflight_section() {
  local status=$1 limit=$2
  if [ "$have_fm_tasks" -ne 1 ]; then
    printf '%s\n' '(fm-tasks not on PATH)'
    return
  fi
  local out
  out=$(fm-tasks ls --status "$status" --fields id,kind,repo,blocked_by,pr_url 2>/dev/null || true)
  out=$(printf '%s' "$out" | sed -E -e '/^tasks\[[0-9]+\]\{/d' -e '/^[[:space:]]*$/d')
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | head -"$limit"
  else
    printf '%s\n' '(none)'
  fi
}

printf '%s\n' '## In flight'
inflight_section inflight 20
printf '%s\n' ''

printf '%s\n' '## Queue head (top 10 queued)'
inflight_section queued 10
printf '%s\n' ''

printf '%s\n' '## Recent done (last 10)'
# `done` is a bash reserved word; shellcheck SC1010 fires wherever it
# appears followed by a newline/`.`. The disable is scoped to the line
# so the linter still flags anything else in this block.
# shellcheck disable=SC1010
inflight_section done 10
printf '%s\n' ''

# Watcher state one-liner at the end so a downstream parser can grep the
# final line for liveness without scanning the full report.
printf '%s\n' '## Watcher'
printf '%s\n' "backend: $watcher_backend | $watcher_state | live panes: $live_panes"
