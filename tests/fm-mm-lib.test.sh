#!/usr/bin/env bash
# Tests for the mintmux (mm) helpers in bin/fm-mm-lib.sh without requiring a
# live mintmux daemon. Two specific regressions are guarded:
#
#  1. mm_list_panes (filter form) parses session names out of mm-ctl meta
#     lines correctly. The classic bug: awk substr math that drops the
#     leading character because RSTART points at "session:" rather than
#     the NAME token. Verified against the line shape mm-ctl emits:
#       meta map[panes:[map[id:10 window:1]] session:fm-paces-a]
#
#  2. mm_list_panes (no-filter form) enumerates every mintmux-backed task
#     recorded in state/<id>.meta (a session= line), so the watcher can
#     observe active panes even when mm-ctl's no-session list-panes call
#     errors out. The fallback walks the state dir; meta files lacking
#     a session= line (tmux-fallback tasks) are ignored.
#
# Strategy: replace mm-ctl with a stub on a fake PATH; the stub replies to
# `list-panes -session NAME` with a synthetic "meta ... session:NAME" line
# plus "OK". mm_available rejects the daemon (no real socket) and the
# tests force the mintmux branch by exporting MM_FORCE_MINTMUX=1, which
# mm_list_panes reads to short-circuit availability for the parse path.
set -u

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/bin/fm-mm-lib.sh"
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-mm-tests.XXXXXX")

# Install a stub mm-ctl in a fake PATH. ping is required to satisfy
# mm_available (which checks both binary presence and live socket).
# Optionally takes a "<session>=<pane_id>" map via env (FM_FAKE_PANE_MAP) so
# tests can mirror real mintmux's per-session pane assignment; the default
# map is fm-* -> 99, which is enough for the parse-math regressions.
make_stub() {
  local dir=$1 fakebin=$1/fakebin
  mkdir -p "$fakebin"
  cat > "$fakebin/mm-ctl" <<'STUB'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  ping)
    # Real mm-ctl ping exits 0 on a live socket. The stub does too; tests
    # gate via FM_FORCE_MINTMUX and never actually need a live socket.
    exit 0
    ;;
  list-panes)
    sess=""
    for a in "$@"; do
      case "$a" in
        -session=*) sess="${a#-session=}" ;;
      esac
    done
    if [ -z "$sess" ]; then
      echo "send: cmd list_panes: session is required" >&2
      exit 1
    fi
    # Mirror real mm-ctl output: meta line, then OK. Pane id is derived
    # from FM_FAKE_PANE_MAP (session=pane) when present, else 99.
    pid=99
    if [ -n "${FM_FAKE_PANE_MAP:-}" ]; then
      # shellcheck disable=SC2086  # word-split is intentional: keys are space-delimited
      for kv in $FM_FAKE_PANE_MAP; do
        k="${kv%%=*}"
        v="${kv#*=}"
        if [ "$k" = "$sess" ]; then
          pid=$v
          break
        fi
      done
    fi
    echo "meta map[panes:[map[id:$pid window:1]] session:$sess]"
    echo "OK"
    ;;
  *)
    echo "stub-mm-ctl: unknown $1" >&2
    exit 2
    ;;
esac
STUB
  chmod +x "$fakebin/mm-ctl"
  printf '%s\n' "$fakebin"
}

test_mm_list_panes_filter_parses_leading_f() {
  local fakebin out
  fakebin=$(make_stub "$TMP_ROOT/filter-leading-f")
  PATH="$fakebin:$PATH" \
    FM_MM_CTL="$fakebin/mm-ctl" FM_MM_SOCK=/tmp/fake.sock \
    FM_STATE_OVERRIDE="$TMP_ROOT/filter-leading-f/state" \
    bash -c '
      set -u
      . "$1"
      out=$(mm_list_panes fm-paces-a)
      printf "%s\n" "$out"
    ' _ "$LIB" > "$TMP_ROOT/filter-leading-f.out" || fail "filter run failed"
  out=$(cat "$TMP_ROOT/filter-leading-f.out")
  [ "$out" = "99	fm-paces-a" ] || fail "filter output was [$out], expected [99<TAB>fm-paces-a]"
  pass "mm_list_panes preserves leading 'f' in session name"
}

test_mm_get_pane_for_session_returns_pane_id() {
  local fakebin out
  fakebin=$(make_stub "$TMP_ROOT/get-pane")
  PATH="$fakebin:$PATH" \
    FM_MM_CTL="$fakebin/mm-ctl" FM_MM_SOCK=/tmp/fake.sock \
    FM_STATE_OVERRIDE="$TMP_ROOT/get-pane/state" \
    bash -c '
      set -u
      . "$1"
      out=$(mm_get_pane_for_session fm-paces-a)
      printf "%s\n" "$out"
    ' _ "$LIB" > "$TMP_ROOT/get-pane.out" || fail "get-pane run failed"
  out=$(cat "$TMP_ROOT/get-pane.out")
  [ "$out" = "99" ] || fail "mm_get_pane_for_session returned [$out], expected [99]"
  pass "mm_get_pane_for_session returns the pane id"
}

test_mm_list_panes_no_filter_enumerates_meta_sessions() {
  local fakebin state out
  fakebin=$(make_stub "$TMP_ROOT/no-filter")
  state="$TMP_ROOT/no-filter/state"
  mkdir -p "$state"
  # Two mintmux tasks recorded by fm-spawn, plus one tmux-only meta (no
  # session= line) which must be ignored. Each session is mapped to its own
  # pane id so the per-session list-panes call returns distinct rows.
  printf 'window=fm-mintmux\nworktree=/tmp\nproject=/tmp\nharness=x\nkind=ship\nmode=no-mistakes\nyolo=off\nbackend=mintmux\npane=99\nsession=fm-mintmux\n' > "$state/task-a.meta"
  printf 'window=fm-other\nworktree=/tmp\nproject=/tmp\nharness=x\nkind=ship\nmode=no-mistakes\nyolo=off\nbackend=mintmux\npane=42\nsession=fm-other\n' > "$state/task-b.meta"
  printf 'window=firstmate:fm-tmux\nworktree=/tmp\nproject=/tmp\nharness=x\nkind=ship\nmode=no-mistakes\nyolo=off\n' > "$state/task-c.meta"
  PATH="$fakebin:$PATH" \
    FM_MM_CTL="$fakebin/mm-ctl" FM_MM_SOCK=/tmp/fake.sock \
    FM_FAKE_PANE_MAP="fm-mintmux=99 fm-other=42" \
    FM_STATE_OVERRIDE="$state" \
    bash -c '
      set -u
      . "$1"
      mm_list_panes
    ' _ "$LIB" > "$TMP_ROOT/no-filter.out" || fail "no-filter run failed"
  out=$(sort "$TMP_ROOT/no-filter.out")
  expected=$(printf '42\tfm-other\n99\tfm-mintmux\n')
  [ "$out" = "$expected" ] || fail "no-filter output was [$out], expected [$expected]"
  pass "mm_list_panes (no filter) enumerates only sessions recorded in state/*.meta"
}

test_mm_list_panes_no_filter_with_no_state_is_empty() {
  local fakebin state out
  fakebin=$(make_stub "$TMP_ROOT/empty-state")
  state="$TMP_ROOT/empty-state/state"
  mkdir -p "$state"
  PATH="$fakebin:$PATH" \
    FM_MM_CTL="$fakebin/mm-ctl" FM_MM_SOCK=/tmp/fake.sock \
    FM_STATE_OVERRIDE="$state" \
    bash -c '
      set -u
      . "$1"
      mm_list_panes
    ' _ "$LIB" > "$TMP_ROOT/empty-state.out" || fail "empty-state run failed"
  out=$(cat "$TMP_ROOT/empty-state.out")
  [ -z "$out" ] || fail "empty state should produce no output, got [$out]"
  pass "mm_list_panes (no filter) emits nothing when no mintmux metas exist"
}

test_mm_list_panes_no_filter_skips_metamorphic_sessions() {
  # Regression guard for the classic offset bug: even without a real
  # daemon, the parser math inside mm_list_panes must keep the leading
  # "f" of every session name (including the metameta file's session=
  # line, whose value is also the session name we pass to mm-ctl).
  local fakebin state out
  fakebin=$(make_stub "$TMP_ROOT/skips-bad-meta")
  state="$TMP_ROOT/skips-bad-meta/state"
  mkdir -p "$state"
  printf 'session=fm-paces-a\npane=10\n' > "$state/fm-paces-a.meta"
  PATH="$fakebin:$PATH" \
    FM_MM_CTL="$fakebin/mm-ctl" FM_MM_SOCK=/tmp/fake.sock \
    FM_STATE_OVERRIDE="$state" \
    bash -c '
      set -u
      . "$1"
      mm_list_panes
    ' _ "$LIB" > "$TMP_ROOT/skips-bad-meta.out" || fail "skips-bad-meta run failed"
  out=$(cat "$TMP_ROOT/skips-bad-meta.out")
  [ "$out" = "99	fm-paces-a" ] || fail "session dropped leading char: [$out]"
  pass "mm_list_panes preserves leading character on no-filter enumeration"
}

test_mm_list_panes_filter_parses_session_with_trailing_brackets() {
  # Same parser math, exercised directly via awk, ensures the trailing ']'
  # in the canonical meta line is not included in the session name.
  local fakebin out
  fakebin=$(make_stub "$TMP_ROOT/filter-trailing-bracket")
  PATH="$fakebin:$PATH" \
    FM_MM_CTL="$fakebin/mm-ctl" FM_MM_SOCK=/tmp/fake.sock \
    FM_STATE_OVERRIDE="$TMP_ROOT/filter-trailing-bracket/state" \
    bash -c '
      set -u
      . "$1"
      out=$(mm_list_panes fm-test-7)
      printf "%s\n" "$out"
    ' _ "$LIB" > "$TMP_ROOT/filter-trailing-bracket.out" || fail "filter-trailing-bracket run failed"
  out=$(cat "$TMP_ROOT/filter-trailing-bracket.out")
  case "$out" in
    "99	fm-test-7") pass "mm_list_panes filter form handles trailing ]" ;;
    *) fail "filter output was [$out], expected [99<TAB>fm-test-7]" ;;
  esac
}

test_mm_list_panes_filter_parses_leading_f
test_mm_get_pane_for_session_returns_pane_id
test_mm_list_panes_no_filter_enumerates_meta_sessions
test_mm_list_panes_no_filter_with_no_state_is_empty
test_mm_list_panes_no_filter_skips_metamorphic_sessions
test_mm_list_panes_filter_parses_session_with_trailing_brackets