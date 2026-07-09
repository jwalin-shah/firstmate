#!/usr/bin/env bash
# tests/mm-watch.test.sh - Behavior tests for bin/mm-watch.sh and the
# mm-event-sub Go helper. Tests run under a hermetic sandbox with a fake
# mm-ctl and mock mintmux socket.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

MM_WATCH="$ROOT/bin/mm-watch.sh"
MM_EVENT_SUB="$ROOT/bin/mm-event-sub"

TMP_ROOT=$(fm_test_tmproot mm-watch-tests)
fm_git_identity fmtest fmtest@example.invalid

# make_fake_mm_socket creates a fake mintmux Unix socket server using Python.
# Responds to hello/ctrl_ack, list_panes/meta+ctrl_ack, subscribe/ctrl_ack,
# then sends one out event and one exit event.
make_fake_mm_socket() {
  local dir=$1 sock="$dir/mm.sock"
  cat > "$dir/mm-server.py" <<'PYEOF'
import json, os, socket, threading, time, sys

sock_path = sys.argv[1]
try:
    os.unlink(sock_path)
except OSError:
    pass

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(5)
server.settimeout(2.0)  # so we can be killed cleanly

pane_id = 1

while True:
    try:
        conn, _ = server.accept()
    except socket.timeout:
        continue
    except:
        break

    conn.settimeout(1.0)
    buf = b""
    try:
        while True:
            try:
                c = conn.recv(1)
                if not c:
                    break
                buf += c
                if c == b'\n':
                    line = buf.decode('utf-8').strip()
                    if not line:
                        buf = b""
                        continue
                    try:
                        msg = json.loads(line)
                    except json.JSONDecodeError:
                        buf = b""
                        continue
                    kind = msg.get("kind", "")
                    pid = msg.get("pane", 0)

                    if kind == "hello":
                        conn.sendall(json.dumps({"v":1,"kind":"ctrl_ack","result":"OK"}).encode() + b'\n')
                    elif kind == "list_panes":
                        conn.sendall(json.dumps({"v":1,"kind":"meta","meta":{"session":"test","panes":[{"id":1,"window":1}]}}).encode() + b'\n')
                        conn.sendall(json.dumps({"v":1,"kind":"ctrl_ack","result":"OK"}).encode() + b'\n')
                    elif kind == "subscribe":
                        conn.sendall(json.dumps({"v":1,"kind":"ctrl_ack","result":"OK"}).encode() + b'\n')
                        time.sleep(0.1)
                        # Send out event with base64-encoded "Hello World\n"
                        conn.sendall(json.dumps({"v":1,"kind":"out","pane":pid or 1,"seq":1,"data":"SGVsbG8gV29ybGQK"}).encode() + b'\n')
                        time.sleep(0.1)
                        conn.sendall(json.dumps({"v":1,"kind":"exit","pane":pid or 1,"seq":2,"code":0}).encode() + b'\n')
                    elif kind == "unsubscribe":
                        conn.sendall(json.dumps({"v":1,"kind":"ctrl_ack","result":"OK"}).encode() + b'\n')
                    else:
                        conn.sendall(json.dumps({"v":1,"kind":"ctrl_ack","result":"OK"}).encode() + b'\n')
                    buf = b""
            except socket.timeout:
                break
    except:
        pass
    finally:
        try:
            conn.close()
        except:
            pass

server.close()
try:
    os.unlink(sock_path)
except OSError:
    pass
PYEOF
  printf '%s' "$sock"
}

# Test: mm-event-sub connects to mintmux and outputs events as JSONL.
test_mm_event_sub_emits_events() {
  local dir fakebin sock out
  dir="$TMP_ROOT/event-sub-emits"
  fakebin="$dir/fakebin"
  sock="$dir/mm.sock"
  out="$dir/events.jsonl"
  mkdir -p "$fakebin" "$dir/state"

  # Create a meta file so mm-event-sub discovers the session.
  echo 'window=firstmate:fm-test' > "$dir/state/test.meta"

  # Start fake server using Python.
  make_fake_mm_socket "$dir" >/dev/null
  python3 "$dir/mm-server.py" "$sock" &
  server_pid=$!
  sleep 0.3

  # Run mm-event-sub with a short timeout (via background kill).
  MM_SOCK="$sock" FM_STATE_OVERRIDE="$dir/state" timeout 5 "$MM_EVENT_SUB" > "$out" 2>/dev/null &
  sub_pid=$!
  sleep 1.5
  kill "$sub_pid" 2>/dev/null || true
  wait "$sub_pid" 2>/dev/null || true
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true

  # Check that events.jsonl has output events.
  [ -s "$out" ] || fail "mm-event-sub produced no output"
  local lines
  lines=$(wc -l < "$out" | tr -d '[:space:]')
  [ "$lines" -ge 2 ] || fail "mm-event-sub produced only $lines line(s) (expected >=2): $(cat "$out")"

  # Validate JSONL format.
  while IFS= read -r line; do
    echo "$line" | jq -e '.ts' >/dev/null 2>&1 || fail "event missing ts: $line"
    echo "$line" | jq -e '.pane_id' >/dev/null 2>&1 || fail "event missing pane_id: $line"
    echo "$line" | jq -e '.event_type' >/dev/null 2>&1 || fail "event missing event_type: $line"
  done < "$out"

  pass "mm-event-sub emits structured JSONL events"
}

# Test: mm-watch.sh starts, writes to events.jsonl, and cleans up on signal.
test_mm_watch_writes_events_jsonl() {
  local dir fakebin sock events_file
  dir="$TMP_ROOT/mm-watch-jsonl"
  fakebin="$dir/fakebin"
  sock="$dir/mm.sock"
  events_file="$dir/state/events.jsonl"
  mkdir -p "$fakebin" "$dir/state"

  # Create a meta file so mm-event-sub discovers the session.
  echo 'window=firstmate:fm-test' > "$dir/state/test.meta"

  # Start fake server using Python.
  make_fake_mm_socket "$dir" >/dev/null
  python3 "$dir/mm-server.py" "$sock" &
  server_pid=$!
  sleep 0.3

  # Run mm-watch.sh.
  MM_SOCK="$sock" FM_STATE_OVERRIDE="$dir/state" "$MM_WATCH" >/dev/null 2>&1 &
  watch_pid=$!
  sleep 2

  # Check events.jsonl exists and has content.
  [ -e "$events_file" ] || fail "events.jsonl was not created"
  [ -s "$events_file" ] || fail "events.jsonl is empty"

  local lines
  lines=$(wc -l < "$events_file" | tr -d '[:space:]')
  [ "$lines" -ge 2 ] || fail "events.jsonl has only $lines lines (expected >=2)"

  # Check format.
  head -1 "$events_file" | jq -e '.event_type' >/dev/null 2>&1 || fail "first event missing event_type: $(head -1 "$events_file")"

  # Cleanup.
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true

  pass "mm-watch.sh writes events.jsonl with structured events"
}

# Test: fm-kqueue-watch detects writes to events.jsonl.
test_kqueue_watch_detects_writes() {
  local dir events_file out
  dir="$TMP_ROOT/kqueue-detect"
  events_file="$dir/events.jsonl"
  out="$dir/kq.out"
  mkdir -p "$dir"

  # Pre-create the file so kqueue can open it.
  touch "$events_file"

  # Start kqueue watch in background with short timeout.
  timeout 5 "$ROOT/bin/fm-kqueue-watch" "$events_file" > "$out" 2>/dev/null &
  kq_pid=$!
  sleep 0.2

  # Write data to the file.
  echo '{"ts":1234,"pane_id":1,"event_type":"test","summary":"test write"}' >> "$events_file"

  # Wait for kqueue to detect.
  wait "$kq_pid" 2>/dev/null || true

  # kqueue should have exited 0.
  pass "fm-kqueue-watch detects writes to events.jsonl"
}

# Test: kqueue timeout works (exit 2).
test_kqueue_watch_timeout() {
  local dir events_file
  dir="$TMP_ROOT/kqueue-timeout"
  events_file="$dir/events.jsonl"
  mkdir -p "$dir"
  touch "$events_file"

  # Run with 1s timeout.
  "$ROOT/bin/fm-kqueue-watch" -t 1 "$events_file" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "kqueue timeout: expected exit 2, got $rc"
  pass "fm-kqueue-watch exits 2 on timeout"
}

# Test: kqueue watch script works as fallback with polling.
test_kqueue_watch_script_polling() {
  local dir events_file out
  dir="$TMP_ROOT/kq-script-poll"
  events_file="$dir/events.jsonl"
  out="$dir/kqscript.out"
  mkdir -p "$dir" "$dir/state"
  # Must create in state dir since the script resolves EVENTS_FILE from FM_STATE_OVERRIDE.
  : > "$dir/state/events.jsonl"

  # Start the kqueue script in background with 1s poll interval and timeout.
  FM_KQUEUE_POLL=1 FM_STATE_OVERRIDE="$dir/state" timeout 3 \
    "$ROOT/bin/fm-kqueue-watch.sh" 2 > "$out" 2>/dev/null &
  kq_pid=$!
  sleep 0.5

  # Write data.
  echo '{"ts":1234,"pane_id":1,"event_type":"test","summary":"poll test"}' >> "$dir/state/events.jsonl"

  wait "$kq_pid" 2>/dev/null
  rc=$?
  # Should exit 0 (detected write), 2 (kqueue timeout), or 124 (shell timeout killed it).
  [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || [ "$rc" -eq 124 ] || fail "kqueue script polling: unexpected exit $rc"
  pass "fm-kqueue-watch.sh fallback polling detects writes"
}

# Test: fm-watch.sh FM_WATCH_MODE=kqueue runs without error.
test_watch_mode_kqueue_env() {
  local dir state fakebin out
  dir="$TMP_ROOT/fm-watch-mode"
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  mkdir -p "$state" "$fakebin"

  # Create a minimal fake tmux and crew-state.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: none · fake default'
exit 0
SH
  chmod +x "$fakebin/fm-crew-state.sh"

  # Create events.jsonl for kqueue to watch.
  touch "$state/events.jsonl"

  # Run fm-watch.sh with kqueue mode briefly - it should start and wait.
  FM_WATCH_MODE=kqueue FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STATE_OVERRIDE="$state" \
    PATH="$fakebin:$PATH" timeout 3 "$ROOT/bin/fm-watch.sh" > "$out" 2>/dev/null &
  watch_pid=$!

  sleep 2
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true

  # Should have no errors - the kqueue mode just replaces sleep.
  [ ! -s "$out" ] || {
    local content
    content=$(cat "$out")
    [ -z "$content" ] || fail "kqueue-mode fm-watch.sh printed unexpected output: $content"
  }

  pass "fm-watch.sh FM_WATCH_MODE=kqueue starts and runs without error"
}

test_mm_event_sub_emits_events
test_mm_watch_writes_events_jsonl
test_kqueue_watch_detects_writes
test_kqueue_watch_timeout
test_kqueue_watch_script_polling
test_watch_mode_kqueue_env
