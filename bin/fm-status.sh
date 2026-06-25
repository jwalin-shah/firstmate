#!/usr/bin/env bash
# bin/fm-status.sh — captain-facing live status report.
# Reads state/<id>.status, state/<id>.meta, fm-tasks queue, and service health.
# No TUI escape codes. No raw pane bytes. Just the facts.
#
# Usage:
#   bin/fm-status.sh                # one-line summary
#   bin/fm-status.sh --full         # full structured report
#   bin/fm-status.sh --json         # machine-readable
#
# This is the captain's "what's happening right now" surface.
# Replaces the prior habit of dumping mm-ctl capture output.

set -u

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$FM_ROOT/state"
DATA_DIR="$FM_ROOT/data"
if [ -n "${TMPDIR:-}" ]; then
  SOCK="$TMPDIR/mintmux.sock"
else
  SOCK="/tmp/mintmux.sock"
fi

# ---- helpers ----
probe_service() {
  local name="$1" url="$2"
  if curl -sf -m 2 -o /dev/null "$url" 2>/dev/null; then
    echo "  ${name}: alive"
  elif curl -sf -m 2 -o /dev/null -w "" "$url" 2>/dev/null; then
    # litellm /health may return 401; treat any TCP-responding as alive
    echo "  ${name}: alive (auth required on /health)"
  else
    echo "  ${name}: DOWN"
  fi
}

mintmux_pane_alive() {
  local pane="$1"
  [ -n "$pane" ] && [ "$pane" != "null" ]
}

# ---- collectors ----
in_flight_meta() {
  # read all state/<id>.meta files; for in-flight (kind=ship|scout, has turn-ended <30min)
  for m in "$STATE_DIR"/*.meta; do
    [ -f "$m" ] || continue
    grep -E '^(kind|harness|mode|backend|pane|session|window)=' "$m" 2>/dev/null | tr '\n' ' '
    echo ""
  done
}

last_status_line() {
  local s="$1"
  [ -f "$s" ] || { echo "(no status)"; return; }
  tail -1 "$s"
}

# ---- main ----
MODE="${1:-summary}"

case "$MODE" in
  --json)
    # machine-readable: one line per in-flight task with structured fields
    echo "{ \"in_flight\": ["
    first=1
    for m in "$STATE_DIR"/*.meta; do
      [ -f "$m" ] || continue
      id=$(basename "$m" .meta)
      kind=$(grep '^kind=' "$m" | cut -d= -f2)
      harness=$(grep '^harness=' "$m" | cut -d= -f2)
      pane=$(grep '^pane=' "$m" | cut -d= -f2)
      session=$(grep '^session=' "$m" | cut -d= -f2)
      last=$(last_status_line "$STATE_DIR/$id.status" 2>/dev/null)
      [ "$first" = 0 ] && echo ","
      printf '    {"id":"%s","kind":"%s","harness":"%s","pane":"%s","session":"%s","last":"%s"}' \
        "$id" "$kind" "$harness" "$pane" "$session" "$last"
      first=0
    done
    echo ""
    echo "  ], \"queue\": \"$(fm-tasks ls 2>/dev/null | head -3 | tr '\n' '|')\" }"
    ;;

  --full|summary|"")
    echo "=== firstmate status @ $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo ""
    echo "--- Services ---"
    probe_service ":4002 tokenrouter" "http://127.0.0.1:4002/"
    probe_service ":8082 mlx"        "http://127.0.0.1:8082/health"
    if [ -S "$SOCK" ]; then
      if mm-ctl ping -sock="$SOCK" >/dev/null 2>&1; then
        echo "  mintmux:     alive"
      else
        echo "  mintmux:     socket present but daemon not responding"
      fi
    else
      echo "  mintmux:     DOWN (no socket)"
    fi
    echo ""
    echo "--- In flight ---"
    count=0
    for m in "$STATE_DIR"/*.meta; do
      [ -f "$m" ] || continue
      id=$(basename "$m" .meta)
      kind=$(grep '^kind=' "$m" | cut -d= -f2 2>/dev/null)
      [ -z "$kind" ] && continue
      # skip torn-down or done tasks (no kind)
      pane=$(grep '^pane=' "$m" | cut -d= -f2 2>/dev/null)
      harness=$(grep '^harness=' "$m" | cut -d= -f2 2>/dev/null)
      mode=$(grep '^mode=' "$m" | cut -d= -f2 2>/dev/null)
      # liveness check
      live="?"
      if mintmux_pane_alive "$pane"; then
        # liveness check via mm-ctl
        if mm-ctl list-panes -sock="$SOCK" -session="fm-$id" 2>/dev/null | grep -q "id:$pane"; then
          live="live"
        else
          live="phantom"
        fi
      else
        live="no-pane"
      fi
      last=$(last_status_line "$STATE_DIR/$id.status" 2>/dev/null)
      printf '  %-40s %-6s %-8s %-12s %-8s | %s\n' "$id" "$kind" "$harness" "$mode" "$live" "$last"
      count=$((count+1))
    done
    if [ "$count" = 0 ]; then
      echo "  (none)"
    fi
    echo ""
    echo "--- Queue (fm-tasks) ---"
    fm-tasks ls 2>/dev/null | head -8
    echo ""
    echo "--- Done recently ---"
    ls -la "$DATA_DIR"/*/report.md 2>/dev/null | tail -3 | awk '{print "  " $9 " (" $5 " bytes, " $6 " " $7 " " $8 ")"}'
    echo ""
    echo "--- Watcher ---"
    if pgrep -f "fm-watch.sh" >/dev/null 2>&1; then
      wp=$(pgrep -f "fm-watch.sh" | head -1)
      echo "  alive (pid $wp)"
    else
      echo "  NOT running — arm with: bin/fm-watch.sh &"
    fi
    ;;

  *)
    echo "usage: bin/fm-status.sh [--full|--json]" >&2
    exit 1
    ;;
esac
