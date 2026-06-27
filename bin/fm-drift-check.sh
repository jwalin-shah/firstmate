#!/usr/bin/env bash
# fm-drift-check.sh — Full staleness & drift detector for Jwalin's fleet.
# Uses agent-doctor for structural checks + gh-axi for GitHub state.
#
# Usage:
#   fm-drift-check.sh              — full check, plain text output
#   fm-drift-check.sh --json       — JSON output for fm-status-server.py
#   fm-drift-check.sh --quick      — skip slow checks (cocoindex, CI)
#
# Exit code: 0 = no drift, 1 = drift found

set -uo pipefail
shopt -s nullglob  # empty globs expand to nothing instead of literal *
FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME="${HOME:-/Users/jwalinshah}"
JSON_MODE=0
QUICK=0
for a in "$@"; do
  case "$a" in
    --json) JSON_MODE=1 ;;
    --quick) QUICK=1 ;;
  esac
done

output=""
fail_count=0
section_count=0

section() {
  local title="$1"
  if [ "$JSON_MODE" -eq 1 ]; then
    local comma=""
    [ "$section_count" -gt 0 ] && comma=","
    output="$output$comma{\"section\":$(printf '%s' "$title" | jq -R -s '.'),\"checks\":["
    section_count=$((section_count + 1))
  else
    echo ""
    echo "=== $title ==="
  fi
  SECTION_OPEN=1
  FIRST_CHECK=1
}

check() {
  local status="$1"  # ok, warn, fail, missing, shadow, atrisk, info
  local msg="$2"
  if [ "$JSON_MODE" -eq 1 ]; then
    local sep=""
    [ "$FIRST_CHECK" -eq 0 ] && sep=","
    FIRST_CHECK=0
    output="$output$sep{\"status\":$(printf '%s' "$status" | jq -R -s '.'),\"msg\":$(printf '%s' "$msg" | jq -R -s '.')}"
  else
    printf "  %-8s %s\n" "$status" "$msg"
  fi
  [ "$status" != "ok" ] && [ "$status" != "info" ] && fail_count=$((fail_count + 1))
}

section_close() {
  if [ "$JSON_MODE" -eq 1 ]; then
    output="$output]}"
  fi
}

# ── 1. agent-doctor structural checks ──────────────────────────────────────
section "agent-doctor"
agent_doctor=$(~/.local/bin/agent-doctor 2>/dev/null || true)
if echo "$agent_doctor" | grep -q "DRIFT"; then
  shadows=$(echo "$agent_doctor" | grep "SHADOW" | wc -l | tr -d ' ' || echo 0)
  missing=$(echo "$agent_doctor" | grep "MISSING" | wc -l | tr -d ' ' || echo 0)
  atrisk=$(echo "$agent_doctor" | grep "AT-RISK" | wc -l | tr -d ' ' || echo 0)
  check "warn" "Drift detected: $shadows shadows, $missing missing, $atrisk at-risk"
  echo "$agent_doctor" | grep "SHADOW\|MISSING\|AT-RISK" | while read -r line; do
    s=$(echo "$line" | awk '{print $1}' | tr 'A-Z' 'a-z')
    m=$(echo "$line" | sed 's/^[^ ]* *//')
    check "$s" "$m"
  done
else
  check "ok" "No structural drift"
fi
section_close

# ── 2. Git repo dirtiness ──────────────────────────────────────────────────
section "git-dirty"
dirty_count=0
for d in /Users/jwalinshah/projects/*/; do
  repo=$(basename "$d")
  if [ -d "$d/.git" ]; then
    s=$(git -C "$d" status --short 2>/dev/null || true)
    b=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    if [ -n "$s" ]; then
      dirty_count=$((dirty_count + 1))
      modified=$(echo "$s" | wc -l | tr -d ' ' || echo 0)
      check "warn" "$repo ($b): $modified uncommitted files"
    fi
  fi
done
if [ "$dirty_count" -eq 0 ]; then
  check "ok" "All repos clean"
else
  check "info" "$dirty_count repos with uncommitted changes"
fi
section_close

# ── 3. CI status via gh-axi ────────────────────────────────────────────────
section "ci-status"
if [ "$QUICK" -eq 1 ]; then
  check "info" "Skipped (--quick)"
else
  for repo in machine-bootstrap firstmate treehouse mintmux voice; do
    rpath=""
    [ -d "/Users/jwalinshah/projects/$repo" ] && rpath="/Users/jwalinshah/projects/$repo"
    [ -d "/Users/jwalinshah/code/$repo" ] && rpath="/Users/jwalinshah/code/$repo"
    [ -z "$rpath" ] && continue
    
    ci=$(cd "$rpath" && gh-axi run list 2>/dev/null | head -5 || true)
    if echo "$ci" | grep -q "failure"; then
      check "fail" "$repo: CI failures detected"
    elif echo "$ci" | grep -q "success"; then
      check "ok" "$repo: CI passing"
    else
      check "info" "$repo: no CI data"
    fi
  done
fi
section_close

# ── 4. Launchd job binary freshness ────────────────────────────────────────
section "launchd-jobs"
for plist in /Users/jwalinshah/Library/LaunchAgents/com.jwalin.*.plist; do
  [ -f "$plist" ] || continue
  job=$(basename "$plist" .plist)
  # Extract the first ProgramArguments string that looks like a path
  binary=$(grep -A1 'ProgramArguments' "$plist" 2>/dev/null | tail -1 | sed 's/.*<string>//;s/<\/string>.*//' 2>/dev/null || echo "")
  # Filter out flags and non-path strings
  if [ -n "$binary" ] && echo "$binary" | grep -q '^/'; then
    if [ ! -f "$binary" ]; then
      check "fail" "$job: binary MISSING at $binary"
    else
      bin_mtime=$(stat -f "%m" "$binary" 2>/dev/null || echo 0)
      plist_mtime=$(stat -f "%m" "$plist" 2>/dev/null || echo 0)
      if [ "$bin_mtime" -gt "$plist_mtime" ]; then
        check "warn" "$job: binary newer than plist (may need reload)"
      else
        check "ok" "$job: binary at $binary"
      fi
    fi
  else
    # Check if the binary exists at a known path pattern for this job
    known_bin="${HOME}/bin/${job#com.jwalin.}"
    if [ -f "$known_bin" ]; then
      check "ok" "$job: binary at $known_bin"
    elif [ "$job" = "com.jwalin.mintmux" ]; then
      check "ok" "$job: managed by launchd (PID $(launchctl list "$job" 2>/dev/null | grep -o '"PID" = [0-9]*' | cut -d' ' -f3))"
    else
      check "info" "$job: plist present, binary detection skipped"
    fi
  fi
done
section_close

# ── 5. opencode config consistency ─────────────────────────────────────────
section "opencode-config"
canonical="/Users/jwalinshah/code/machine-bootstrap/opencode/opencode.json"
deployed="/Users/jwalinshah/.config/opencode/opencode.json"
if [ -f "$canonical" ] && [ -f "$deployed" ]; then
  c_hash=$(md5 -q "$canonical" 2>/dev/null || md5sum "$canonical" | cut -d' ' -f1)
  d_hash=$(md5 -q "$deployed" 2>/dev/null || md5sum "$deployed" | cut -d' ' -f1)
  if [ "$c_hash" != "$d_hash" ]; then
    check "warn" "Canonical and deployed opencode.json differ"
  else
    check "ok" "Configs match"
  fi
elif [ ! -f "$deployed" ]; then
  check "fail" "Deployed opencode.json not found at $deployed"
else
  check "warn" "Canonical opencode.json not found at $canonical"
fi
section_close

# ── 6. CocoIndex stale chunks ─────────────────────────────────────────────
section "cocoindex-stale"
if [ "$QUICK" -eq 1 ]; then
  check "info" "Skipped (--quick)"
elif command -v cocoindex &>/dev/null && [ -f "$HOME/cocoindex_data.db" ]; then
  stale_count=$(sqlite3 "$HOME/cocoindex_data.db" \
    "SELECT COUNT(*) FROM chunks WHERE path LIKE '%firstmate/projects/orbit%' OR path LIKE '%firstmate/projects/odysseus%' OR path LIKE '%firstmate/projects/platform%';" 2>/dev/null || echo "0")
  if [ "$stale_count" -gt 0 ] && [ "$stale_count" != "0" ]; then
    check "warn" "$stale_count chunks reference deleted paths (orbit/odysseus/platform)"
  else
    check "ok" "No stale path references detected"
  fi
else
  check "info" "CocoIndex not accessible for staleness check"
fi
section_close

# ── 7. GitHub open issues/PRs ─────────────────────────────────────────────
section "github-state"
if [ "$QUICK" -eq 1 ]; then
  check "info" "Skipped (--quick)"
else
  for repo in machine-bootstrap firstmate; do
    rpath=""
    [ -d "/Users/jwalinshah/projects/$repo" ] && rpath="/Users/jwalinshah/projects/$repo"
    [ -z "$rpath" ] && continue
    
    issues=$(cd "$rpath" && gh-axi issue list 2>/dev/null | grep "^[0-9]" | wc -l | tr -d ' ' || echo "0")
    prs=$(cd "$rpath" && gh-axi pr list 2>/dev/null | grep "^[0-9]" | wc -l | tr -d ' ' || echo "0")
    if [ "$issues" -gt 0 ] || [ "$prs" -gt 0 ]; then
      check "info" "$repo: $issues open issues, $prs open PRs"
    else
      check "ok" "$repo: clean"
    fi
  done
fi
section_close

# ── Output ──────────────────────────────────────────────────────────────────
if [ "$JSON_MODE" -eq 1 ]; then
  echo "{\"drift\":true,\"total_fail\":$fail_count,\"sections\":[$output]}"
else
  echo ""
  echo "========================================"
  if [ "$fail_count" -gt 0 ]; then
    echo "DRIFT FOUND: $fail_count issues"
    exit 1
  else
    echo "ALL CLEAN — no drift detected"
    exit 0
  fi
fi
