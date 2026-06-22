#!/usr/bin/env bash
# Smoke test for fm-teardown.sh's scout gate.
#   - scout task with a report      -> fm-teardown passes the gate (exit 0)
#   - scout task without a report   -> fm-teardown refuses (non-zero exit)
# This is a brief test as the task brief asks, not a full unit suite.
# We exercise the gate by running fm-teardown.sh against a fake task
# whose meta says kind=scout, with/without a report file. The full
# teardown has many later steps (treehouse return, tmux kill, fm-tasks)
# that we mock out so the only meaningful difference between the two
# cases is the report-exists check we want to verify.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

FAKE_WT="$(mktemp -d)"
trap 'rm -rf "$FAKE_WT" "$ROOT/state/scout-yes.meta" "$ROOT/state/scout-no.meta" "$ROOT/data/scout-yes" 2>/dev/null || true' EXIT

write_meta() {
  local id=$1
  printf 'kind=scout\nmode=no-mistakes\nwindow=fake\nproject=/tmp\nworktree=%s\nharness=claude\n' "$FAKE_WT" \
    > "$ROOT/state/$id.meta"
}

# Stub treehouse, tmux, fm-tasks so the rest of fm-teardown is a no-op
# and the only thing the exit code reflects is the scout gate.
# We prepend the stub dir to PATH and rely on a fresh bash invocation,
# so the user's interactive grep alias is irrelevant (bash, not zsh).
# We also force PATH to start with /usr/bin so the harness uses the
# stock grep on this system rather than the zsh function wrapper.
TEMP_BIN="$(mktemp -d)"
trap 'rm -rf "$FAKE_WT" "$TEMP_BIN" "$ROOT/state/scout-yes.meta" "$ROOT/state/scout-no.meta" "$ROOT/data/scout-yes" 2>/dev/null || true' EXIT
cat > "$TEMP_BIN/treehouse" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TEMP_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TEMP_BIN/fm-tasks" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEMP_BIN/treehouse" "$TEMP_BIN/tmux" "$TEMP_BIN/fm-tasks"
# Stock-grep PATH: /usr/bin must come before anything that aliases grep.
STOCK_PATH=/usr/bin:/usr/sbin:/bin:/sbin

# Case 1: scout with report -> gate passes, teardown exits 0.
write_meta scout-yes
mkdir -p "$ROOT/data/scout-yes"
echo "findings" > "$ROOT/data/scout-yes/report.md"
if PATH="$TEMP_BIN:$STOCK_PATH" bash "$TEARDOWN" scout-yes >/dev/null 2>&1; then
  echo "PASS: fm-teardown.sh accepts scout with report (exits 0)"
else
  echo "FAIL: fm-teardown.sh should accept scout with report"; exit 1
fi

# Case 2: scout without report -> gate refuses, teardown exits non-zero.
write_meta scout-no
if PATH="$TEMP_BIN:$STOCK_PATH" bash "$TEARDOWN" scout-no >/dev/null 2>&1; then
  echo "FAIL: fm-teardown.sh should refuse scout without report"; exit 1
else
  echo "PASS: fm-teardown.sh refuses scout without report"
fi

echo "OK: scout teardown gate behaves correctly"
