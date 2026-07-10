#!/usr/bin/env bash
# tests/fm-service-status.test.sh — behavior tests for bin/fm-service-status.sh

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT_UNDER_TEST="$ROOT/bin/fm-service-status.sh"

# ── helpers ────────────────────────────────────────────────────────────────────

# Build a fakebin with stub pgrep and curl that always succeed.
setup_all_ok() {
  local tmp
  tmp=$(fm_test_tmproot "fm-svc-status-all-ok")
  local fakebin
  fakebin=$(fm_fakebin "$tmp")

  # pgrep always succeeds
  cat > "$fakebin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/pgrep"

  # curl always succeeds
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/curl"

  echo "$fakebin"
}

# Build a fakebin where pgrep fails for one specific pattern.
setup_pgrep_fail_for() {
  local tmp pattern_to_fail="$1"
  tmp=$(fm_test_tmproot "fm-svc-status-pgrep-fail")
  local fakebin
  fakebin=$(fm_fakebin "$tmp")

  # pgrep fails when the pattern matches the target
  cat > "$fakebin/pgrep" <<SH
#!/usr/bin/env bash
# pgrep stub: fails for a specific pattern, succeeds otherwise.
# Usage: pgrep -f <pattern>
for arg in "\$@"; do
  case "\$arg" in
    -*|pgrep) continue ;;
  esac
  if [ "\$arg" = "$pattern_to_fail" ]; then
    exit 1
  fi
done
exit 0
SH
  chmod +x "$fakebin/pgrep"

  # curl always succeeds
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/curl"

  echo "$fakebin"
}

# Build a fakebin where pgrep succeeds but curl fails for one port.
setup_curl_fail_for() {
  local tmp port_to_fail="$1"
  tmp=$(fm_test_tmproot "fm-svc-status-curl-fail")
  local fakebin
  fakebin=$(fm_fakebin "$tmp")

  # pgrep always succeeds
  cat > "$fakebin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/pgrep"

  # curl fails when the URL contains the target port
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
# curl stub: fails when the URL contains a specific port.
for arg in "\$@"; do
  case "\$arg" in
    *:${port_to_fail}/*) exit 1 ;;
  esac
done
exit 0
SH
  chmod +x "$fakebin/curl"

  echo "$fakebin"
}

# ── tests ─────────────────────────────────────────────────────────────────────

# Test 1: All services ok
test_all_ok() {
  local fakebin
  fakebin=$(setup_all_ok)
  local output rc

  output=$(PATH="$fakebin:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1) || rc=$?
  expect_code 0 "${rc:-0}" "all services ok should exit 0"

  # Every known service should report ok
  assert_contains "$output" "ok: cocoindex" "cocoindex should be ok"
  assert_contains "$output" "ok: cognee" "cognee should be ok"
  assert_contains "$output" "ok: mlx-chat" "mlx-chat should be ok"
  assert_contains "$output" "ok: llama-embed" "llama-embed should be ok"
  assert_contains "$output" "ok: coderank-embed" "coderank-embed should be ok"
  assert_contains "$output" "ok: quota-core" "quota-core should be ok"
  assert_contains "$output" "ok: voice-engine" "voice-engine should be ok"

  pass "all services ok"
}

# Test 2: One service process down
test_process_down() {
  local fakebin
  fakebin=$(setup_pgrep_fail_for "cocoindex")
  local output rc

  output=$(PATH="$fakebin:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1) || rc=$?
  expect_code 1 "${rc:-0}" "one down should exit 1"

  assert_contains "$output" "down: cocoindex - process not running" "cocoindex should be down"
  # Other services should still be ok
  assert_contains "$output" "ok: cognee" "cognee should still be ok"
  assert_contains "$output" "ok: mlx-chat" "mlx-chat should still be ok"

  pass "process down detected"
}

# Test 3: Health endpoint unreachable
test_health_down() {
  local fakebin
  fakebin=$(setup_curl_fail_for "8000")
  local output rc

  output=$(PATH="$fakebin:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1) || rc=$?
  expect_code 1 "${rc:-0}" "health down should exit 1"

  assert_contains "$output" "down: cognee - health endpoint unreachable" "cognee health should be down"
  # Other HTTP services on different ports should be ok
  assert_contains "$output" "ok: mlx-chat" "mlx-chat should still be ok"

  pass "health endpoint unreachable detected"
}

# Test 4: Filter by single service name
test_filter_by_name() {
  local fakebin
  fakebin=$(setup_all_ok)
  local output rc line_count

  output=$(PATH="$fakebin:$PATH" bash "$SCRIPT_UNDER_TEST" cocoindex 2>&1) || rc=$?
  expect_code 0 "${rc:-0}" "single service ok should exit 0"

  assert_contains "$output" "ok: cocoindex" "should report cocoindex"
  # Should NOT contain other services
  assert_not_contains "$output" "cognee" "should not mention cognee"
  assert_not_contains "$output" "mlx-chat" "should not mention mlx-chat"

  # Should have exactly one line
  line_count=$(echo "$output" | wc -l | tr -d ' ')
  [ "$line_count" -eq 1 ] || fail "expected 1 line for single service, got $line_count"

  pass "filter by name works"
}

# Test 5: Unknown service name
test_unknown_service() {
  local fakebin
  fakebin=$(setup_all_ok)
  local output rc

  output=$(PATH="$fakebin:$PATH" bash "$SCRIPT_UNDER_TEST" bogus-svc 2>&1) || rc=$?
  expect_code 1 "${rc:-0}" "unknown service should exit 1"

  assert_contains "$output" "down: bogus-svc - unknown service" "should report unknown"

  pass "unknown service detected"
}

# ── run ────────────────────────────────────────────────────────────────────────

test_all_ok
test_process_down
test_health_down
test_filter_by_name
test_unknown_service

printf '\nAll tests passed.\n'
