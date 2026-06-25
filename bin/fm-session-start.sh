#!/usr/bin/env bash
# Firstmate SessionStart hook. Prints the current fleet status and the
# auto-derived backlog as `additionalContext` so the captain opens every
# session with a fresh view of in-flight work without paging mm-ctl capture
# output. Wired into ~/.claude/settings.json's SessionStart hook array.
#
# Output is plain text (no JSON wrapping) because Claude Code's hook
# contract is "stdout is the additionalContext body" — anything we write
# here shows up as assistant-side context before the first user turn.
#
# Usage:
#   bin/fm-session-start.sh                  # print the briefing
#
# This script is observation-only: it never mutates state, never spawns
# workers, never blocks for more than a few hundred ms (the SQLite query
# is the dominant cost; we cap it via `timeout 2` on the fm-tasks call).
set -u

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# 1. Make sure backlog.md is fresh. If the watcher already updated it
#    within the last few seconds, this is a noop (the script is idempotent
#    and ~30ms in the warm path). Failures here are silent: the SessionStart
#    hook must never block a session from opening.
if [ -x "$FM_ROOT/bin/fm-queue.sh" ]; then
  "$FM_ROOT/bin/fm-queue.sh" to-markdown >/dev/null 2>&1 || true
fi

# 2. Print the status report. We pipe the whole thing through head -c 8000
#    so a runaway backlog (e.g. a corrupted DB returning 10k rows) cannot
#    blow out the assistant's first-turn context window. 8KB is roughly
#    2000 tokens, which fits comfortably in the "first turn, before user
#    prompt" budget the captain is comfortable with.
if [ -x "$FM_ROOT/bin/fm-status.sh" ]; then
  "$FM_ROOT/bin/fm-status.sh" 2>/dev/null | head -c 8000
fi
