#!/usr/bin/env bash
# Tests for bin/fm-status-bridge.lua without requiring a live mintmux daemon.
#
# Strategy: load the bridge inside a Lua harness that fakes the global `mm`
# table (run + on_event) and a temporary FM_ROOT. Fire synthetic pane events
# with the new self-contained format "state:task-id: note" and assert the
# bridge issued the right mm.run shell command.
#
# Format: <state>:<task-id>: <note>
# No pane-map needed — the task id is on the status line itself.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$ROOT/bin/fm-status-bridge.lua"
TMP_ROOT=

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then rm -rf "$TMP_ROOT"; fi
}
trap cleanup EXIT

if ! command -v lua >/dev/null 2>&1; then
  printf '1..0 # SKIP lua not installed\n'
  exit 0
fi
if [ ! -r "$BRIDGE" ]; then
  fail "bridge not found at $BRIDGE"
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-bridge-tests.XXXXXX")
mkdir -p "$TMP_ROOT/state"

HARNESS=$TMP_ROOT/harness.lua
cat > "$HARNESS" <<LUA_HARNESS
local bridge_path = os.getenv("BRIDGE_PATH")
local fm_root     = os.getenv("FM_ROOT")
local home        = os.getenv("HOME")
local calls = {}
mm = {}
function mm.run(cmd, _t)
  -- Bridge boot: printf %s "\$FM_ROOT" / "\$HOME" → return real env value.
  if cmd:match("FM_ROOT") then return fm_root, 0 end
  if cmd:match("HOME")    then return home, 0 end
  calls[#calls+1] = cmd
  return "", 0
end
local cb
function mm.on_event(f) cb = f end
local chunk = assert(loadfile(bridge_path), "loadfile failed")
chunk()
assert(cb, "no callback registered")
-- Calls during boot (printf for FM_ROOT/HOME) are benign; keep them for
-- the first test but reset after.
LUA_HARNESS

run_harness() {
  local script_body=$1
  local driver=$TMP_ROOT/driver.lua
  /bin/cat "$HARNESS" > "$driver"
  printf '%s\n' "$script_body" >> "$driver"
  printf 'for _, c in ipairs(calls) do print(c) end\n' >> "$driver"
  BRIDGE_PATH="$BRIDGE" FM_ROOT="$TMP_ROOT" HOME="$HOME" lua "$driver"
}

# Test 1: terminal done routes to fm-tasks done
OUT=$(run_harness "calls={}; cb({kind='out', pane=99, data='done:task-a: shipped fix\n'})")
echo "$OUT" | /usr/bin/grep -q "^fm-tasks done task-a$" \
  || fail "done not routed; got: $OUT"
pass "terminal done routed to fm-tasks done (no pane-map)"

# Test 2: terminal failed routes to fm-tasks fail
OUT=$(run_harness "calls={}; cb({kind='out', pane=77, data='failed:task-b: tests red\n'})")
echo "$OUT" | /usr/bin/grep -q "^fm-tasks fail task-b$" \
  || fail "failed not routed; got: $OUT"
pass "terminal failed routed to fm-tasks fail"

# Test 3: non-terminal state appends to status file
OUT=$(run_harness "calls={}; cb({kind='out', pane=1, data='working:task-a: setup\n'})")
echo "$OUT" | /usr/bin/grep -qF "echo working: setup >> $TMP_ROOT/state/task-a.status" \
  || fail "non-terminal not appended; got: $OUT"
pass "non-terminal state falls back to status-file append"

# Test 4: non-out event ignored
OUT=$(run_harness "calls={}; cb({kind='in', pane=1, data='done:task-a: typed\n'})")
[ -z "$OUT" ] || fail "kind=in produced output: $OUT"
pass "non-out event ignored"

# Test 5: terminal state dedup (no reprocess)
OUT=$(run_harness "
  calls={}
  cb({kind='out', pane=1, data='done:task-a: first\\n'})
  cb({kind='out', pane=1, data='done:task-a: again\\n'})
")
COUNT=$(echo "$OUT" | /usr/bin/grep -c "task-a" || true)
[ "$COUNT" = "1" ] || fail "task-a reprocessed after done; got $COUNT lines: $OUT"
pass "terminal state dedup (no reprocess)"

# Test 6: unknown state ignored
OUT=$(run_harness "calls={}; cb({kind='out', pane=1, data='foo:task-a: ignored\n'})")
[ -z "$OUT" ] || fail "unknown state produced output: $OUT"
pass "unknown state ignored"

# Test 7: any pane — the event.pane field is irrelevant now
OUT=$(run_harness "calls={}; cb({kind='out', pane=99999, data='done:task-c: any pane\n'})")
echo "$OUT" | /usr/bin/grep -q "^fm-tasks done task-c$" \
  || fail "done on unknown pane not routed; got: $OUT"
pass "any pane accepted (pane-id-free routing)"

# Test 8: note is optional
OUT=$(run_harness "calls={}; cb({kind='out', pane=1, data='done:task-d:\n'})")
echo "$OUT" | /usr/bin/grep -q "^fm-tasks done task-d$" \
  || fail "done with no note not routed; got: $OUT"
pass "empty note ok"

# Test 9: task-id with hyphens
OUT=$(run_harness "calls={}; cb({kind='out', pane=1, data='done:fix-login-k3: built auth\n'})")
echo "$OUT" | /usr/bin/grep -q "^fm-tasks done fix-login-k3$" \
  || fail "hyphenated task-id not routed; got: $OUT"
pass "hyphenated task-id routed"

# Test 10: done task-a, failed task-b in same event chunk
OUT=$(run_harness "
  calls={}
  cb({kind='out', pane=1, data='done:task-a: ok\\nfailed:task-b: boom\\n'})
")
echo "$OUT" | /usr/bin/grep -q "^fm-tasks done task-a$" \
  || fail "first status in chunk not routed; got: $OUT"
pass "only first status line per chunk processed (break on match)"

printf '1..10\n'