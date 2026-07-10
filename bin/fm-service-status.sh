#!/usr/bin/env bash
# Check liveness of fleet services.
# Usage: fm-service-status.sh [<service>]
#   No arg: check all known services and report each.
#   One arg: check only that named service.
#   Prints "ok: <service>" or "down: <service> - <reason>".
#   Exits 0 if all checked services are ok, 1 if any is down.
#   Checks the live PROCESS first (pgrep); logs are NEVER used to infer state.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# ── service definitions ────────────────────────────────────────────────────────
# Each entry: "name:check_type[:port]"
# check_type: pgrep_only | http
SERVICES=(
  "cocoindex:pgrep_only"
  "cognee:http:8000"
  "mlx-chat:http:8080"
  "llama-embed:http:8081"
  "coderank-embed:http:8082"
  "quota-core:pgrep_only"
  "voice-engine:pgrep_only"
)

# ── helpers ────────────────────────────────────────────────────────────────────

pgrep_pattern() {
  # Return a pgrep -f pattern for a service name. Some daemons run with an
  # underscore or different binary name than the service key.
  case "$1" in
    cocoindex)     printf 'cocoindex' ;;
    cognee)        printf 'cognee' ;;
    mlx-chat)      printf 'mlx.chat' ;;      # matches mlx_chat_server, mlx-chat
    llama-embed)   printf 'llama-embed' ;;
    coderank-embed) printf 'coderank-embed' ;;
    quota-core)    printf 'quota-core' ;;
    voice-engine)  printf 'voice-engine' ;;
    *)             printf '%s' "$1" ;;
  esac
}

process_running() {
  # Check if a service's process is running via pgrep.
  local svc="$1" pattern
  pattern=$(pgrep_pattern "$svc")
  pgrep -f "$pattern" >/dev/null 2>&1
}

health_ok() {
  # Check if a service's health endpoint responds 2xx.
  local port="$1"
  curl -sf --max-time 2 "http://localhost:${port}/health" >/dev/null 2>&1
}

# ── per-service checks ─────────────────────────────────────────────────────────

check_pgrep_only() {
  local svc="$1"
  if process_running "$svc"; then
    echo "ok: $svc"
    return 0
  else
    echo "down: $svc - process not running"
    return 1
  fi
}

check_http() {
  local svc="$1" port="$2"
  if ! process_running "$svc"; then
    echo "down: $svc - process not running"
    return 1
  fi
  if health_ok "$port"; then
    echo "ok: $svc"
    return 0
  else
    echo "down: $svc - health endpoint unreachable"
    return 1
  fi
}

check_one() {
  local name="$1" check_type="$2" port="${3:-}"
  case "$check_type" in
    pgrep_only) check_pgrep_only "$name" ;;
    http)       check_http "$name" "$port" ;;
    *)          echo "down: $name - unknown check type: $check_type"; return 1 ;;
  esac
}

# ── main ───────────────────────────────────────────────────────────────────────

main() {
  local target="${1:-}"
  local any_down=0

  if [ -n "$target" ]; then
    # Single-service mode: find the definition and check it.
    local found=0
    for entry in "${SERVICES[@]}"; do
      IFS=':' read -r name check_type port <<< "$entry"
      if [ "$name" = "$target" ]; then
        found=1
        check_one "$name" "$check_type" "$port" || any_down=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      echo "down: $target - unknown service"
      any_down=1
    fi
  else
    # All-services mode.
    for entry in "${SERVICES[@]}"; do
      IFS=':' read -r name check_type port <<< "$entry"
      check_one "$name" "$check_type" "$port" || any_down=1
    done
  fi

  return "$any_down"
}

main "$@"
