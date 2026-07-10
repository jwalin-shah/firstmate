#!/usr/bin/env bash
# tests/fm-backend-tmux-edge-cases.test.sh - edge-case session names for the
# tmux session-provider adapter (bin/backends/tmux.sh). Exercises the
# `-t "$ses:"` target-resolution paths with numeric, hex, special-char,
# tmux-keyword, and space-containing session names to catch regressions in
# how tmux parses session-name targets.
#
# Uses a private tmux socket (`-L`) so edge-case session names never pollute
# the host's real sessions. Follows the same private-socket isolation pattern
# as tests/fm-backend-tmux-smoke.test.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-edge-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-edge.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

# ── helpers ────────────────────────────────────────────────────────────────

# make_session <name>: create a detached session with the given name, exit
# non-zero if tmux refuses it (e.g. invalid characters, name collision).
make_session() {
  local name=$1
  tmux new-session -d -s "$name" -x 80 -y 24 2>/dev/null
}

# kill_session <name>: best-effort session teardown.
kill_session() {
  local name=$1
  tmux kill-session -t "$name" 2>/dev/null || true
}

# assert_window_exists <session> <window-name>
assert_window_exists() {
  local ses=$1 wname=$2
  tmux list-windows -t "$ses:" -F '#{window_name}' 2>/dev/null | grep -qx "$wname" \
    || fail "window '$wname' should exist in session '$ses' but was not found"
}

# assert_window_gone <session> <window-name>
assert_window_gone() {
  local ses=$1 wname=$2
  if tmux list-windows -t "$ses:" -F '#{window_name}' 2>/dev/null | grep -qx "$wname"; then
    fail "window '$wname' should be gone from session '$ses' but still exists"
  fi
}

# run_create_kill_cycle <session> <window>: the standard create-window,
# verify-exists, kill-window, verify-gone cycle that exercises
# fm_backend_tmux_create_task's `-t "$ses:"` target resolution.
run_create_kill_cycle() {
  local ses=$1 wname=$2

  # 1. Create the task window through the backend.
  fm_backend_tmux_create_task "$ses" "$wname" "$HOME" \
    || fail "fm_backend_tmux_create_task failed for session='$ses' window='$wname'"

  # 2. Assert window exists in the session.
  assert_window_exists "$ses" "$wname"

  # 3. Refuse a duplicate window name (mirrors fm-spawn.sh's duplicate guard).
  if fm_backend_tmux_create_task "$ses" "$wname" "$HOME" 2>/dev/null; then
    fail "fm_backend_tmux_create_task should refuse duplicate window '$wname' in session '$ses'"
  fi

  # 4. Kill the window.
  fm_backend_tmux_kill "$ses:$wname" \
    || fail "fm_backend_tmux_kill failed for '$ses:$wname'"

  # 5. Assert window is gone.
  assert_window_gone "$ses" "$wname"

  # 6. Killing an already-gone window must be idempotent (best-effort contract).
  fm_backend_tmux_kill "$ses:$wname" \
    || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"

  pass "edge-case session '$ses': create, duplicate-refuse, kill, idempotent-kill all pass"
}

# ── test cases ─────────────────────────────────────────────────────────────

# 1. Numeric session name: "0"
#    tmux distinguishes `-t "0"` (window index) from `-t "0:"` (session "0").
#    The colon suffix is critical; this test verifies the colon-suffixed form
#    used by fm_backend_tmux_create_task correctly targets the session.
make_session "0" || fail "tmux refused to create session named '0'"
run_create_kill_cycle "0" "fm-edge-num0"
kill_session "0"

# 2. Numeric session name: "10"
#    Multi-digit numeric names must also work with the colon suffix.
make_session "10" || fail "tmux refused to create session named '10'"
run_create_kill_cycle "10" "fm-edge-num10"
kill_session "10"

# 3. Hex session name: "0xdead"
#    Hex-prefix names start with digits but contain letters. The colon-suffix
#    form `-t "0xdead:"` must treat them as session names, not numeric indices.
make_session "0xdead" || fail "tmux refused to create session named '0xdead'"
run_create_kill_cycle "0xdead" "fm-edge-hex"
kill_session "0xdead"

# 4. Special chars: "-test" (leading dash)
#    A leading dash could be misparsed as a tmux flag. The backend always
#    passes the session name as the next argument after `-t`, so tmux must
#    not interpret the leading dash in the session-name position as a flag.
make_session "-test" || fail "tmux refused to create session named '-test'"
run_create_kill_cycle "-test" "fm-edge-dash"
kill_session "-test"

# 5. tmux keyword: "firstmate"
#    The hardcoded session name used by fm_backend_tmux_container_ensure.
#    This is the common real-world path and must work without surprises.
make_session "firstmate" || fail "tmux refused to create session named 'firstmate'"
run_create_kill_cycle "firstmate" "fm-edge-keyword"
kill_session "firstmate"

# 6. Spaces: "my session"
#    tmux allows spaces in session names. Every layer of quoting must preserve
#    the space so tmux receives the session name as a single token.
make_session "my session" || fail "tmux refused to create session named 'my session'"
run_create_kill_cycle "my session" "fm-edge-space"
kill_session "my session"

# 7. Empty session name: rejected by backend
#    An empty session name is dangerous because `-t ":"` targets the
#    *current* (most-recent) session rather than a session literally named "".
#    fm_backend_tmux_create_task must reject an empty session name before
#    reaching tmux, since tmux itself allows `new-session -d -s ""` and
#    creates an unreachable-by-name session. Empirically verified: with both
#    an empty-named session and a "firstmate" session present, `-t ":"` hits
#    the "firstmate" session, not the empty-named one (2026-07-09, tmux 3.5a).
make_session "" || fail "tmux refused to create a session with an empty name (this test validates the backend guard)"

# create_task with empty session must fail early (does not touch tmux targets)
if fm_backend_tmux_create_task "" "fm-edge-empty" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task must reject an empty session name instead of targeting the wrong session via '-t :'"
fi
pass "edge-case session '': fm_backend_tmux_create_task rejects empty session name (guards against ambiguous '-t :' targeting)"

# Verify the empty-named session is still intact (backend rejection must not
# have created any windows in the wrong session).
assert_window_gone "" "fm-edge-empty"

# Also verify no window leaked into the empty-named session.
# We already created a "firstmate" session above and killed it, so now there's
# only the empty-named session. list-windows -a shows every window; with only
# the empty session, the backend-created window must not appear.
all_windows=$(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null)
case "$all_windows" in
  *fm-edge-empty*)
    fail "fm-edge-empty window leaked into a session despite backend rejection"$'\n'"$all_windows" ;;
esac
pass "edge-case session '': no window leaked after backend rejection of empty session name"

kill_session ""

# ── teardown ───────────────────────────────────────────────────────────────

cleanup_all
trap - EXIT
