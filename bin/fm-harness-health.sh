#!/usr/bin/env bash
# Check whether a harness can accept work right now. Run before spawn, not after
# the crewmate is already frozen at a dialog.
# Usage: fm-harness-health.sh [<harness>]
#   Prints "ok: <harness>" and exits 0 when the harness is ready.
#   Prints "blocked: <harness> - <reason>" and exits 1 when blocked.
#   The check is cheap: a single HEAD/OPTIONS request with a 2s timeout.
#   When the check cannot be performed (no API endpoint defined for this harness,
#   no credentials), it prints "unknown: <harness>" and exits 0 — never block
#   work on a missing health check.
#   Without an argument, resolves the crewmate harness from config.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

HARNESS="${1:-$("$SCRIPT_DIR/fm-harness.sh" crew)}"

# ── per-harness checks ────────────────────────────────────────────────────────

check_anthropic() {
  # Anthropic API: a 200/4xx on the base URL doesn't prove quota, but a 402
  # (Payment Required) or 429 (Rate Limited) are hard blocks. A 401 means the
  # key exists but is invalid — also a block. Anything else is "unknown, let it
  # try" because we can't cheaply check spend-limit state without a real request.
  local url="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
  local key="${ANTHROPIC_API_KEY:-}"
  local status

  # Prefer an explicit API key. When absent, try OAuth from the stored token
  # (ca uses OAuth, ct sets ANTHROPIC_BASE_URL to the TokenRouter).
  if [ -z "$key" ]; then
    # ca stores OAuth credentials in the keychain; we can't extract them here.
    # Fall through to unknown — don't block on missing credentials.
    return 0
  fi

  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
    -H "x-api-key: $key" \
    -H "anthropic-version: 2023-06-01" \
    "$url/v1/messages" 2>/dev/null) || return 0  # network error: unknown

  case "$status" in
    402) echo "blocked: Anthropic spend limit or payment required — raise cap at claude.ai/settings/usage" >&2; return 1 ;;
    429) echo "blocked: Anthropic rate limited — wait for reset" >&2; return 1 ;;
    401) echo "blocked: Anthropic API key invalid or expired" >&2; return 1 ;;
    403) echo "blocked: Anthropic API key lacks permission" >&2; return 1 ;;
    *)   return 0 ;;  # 400 (missing body), 200, or anything else: unknown
  esac
}

check_tokenrouter() {
  # TokenRouter proxies to DeepSeek/Grok/etc. Its base URL is in
  # ANTHROPIC_BASE_URL. A 402/429 at the TokenRouter level blocks all backends.
  local url="${ANTHROPIC_BASE_URL:-}"
  if [ -z "$url" ]; then
    return 0  # no URL configured: unknown
  fi

  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
    "$url/v1/messages" 2>/dev/null) || return 0

  case "$status" in
    402) echo "blocked: TokenRouter billing limit — top up or switch harness" >&2; return 1 ;;
    429) echo "blocked: TokenRouter rate limited — wait for reset" >&2; return 1 ;;
    *)   return 0 ;;
  esac
}

check_binary() {
  # Does the harness launcher exist? This catches "tool not installed" before
  # spawn, but not quota issues.
  local bin="${1:-}"
  [ -n "$bin" ] || { echo "blocked: harness binary not found" >&2; return 1; }
  command -v "$bin" >/dev/null 2>&1 || {
    echo "blocked: $bin not installed or not on PATH" >&2
    return 1
  }
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "$(echo "$HARNESS" | tr '[:upper:]' '[:lower:]')" in
  claude|ca|ct)
    # ca: Anthropic direct OAuth. ct: TokenRouter -> DeepSeek/Grok.
    # Both use the Claude binary and talk the Anthropic protocol.
    # ct's binary is `ct` (a launcher wrapper), ca's is `ca`.
    local_bin="$HARNESS"
    [ "$local_bin" = "claude" ] && local_bin="claude"

    check_binary "$local_bin" || exit 1

    # TokenRouter health: check the proxy endpoint.
    check_tokenrouter || exit 1

    # When ANTHROPIC_API_KEY is set AND the base URL is TokenRouter, the key is
    # for the proxy, not Anthropic direct. Skip the direct check in that case.
    if [ "${ANTHROPIC_BASE_URL:-}" != "${ANTHROPIC_BASE_URL:-https://api.anthropic.com}" ] \
        && echo "${ANTHROPIC_BASE_URL:-}" | grep -qi 'tokenrouter'; then
      # ct path: TokenRouter check is sufficient.
      :
    else
      check_anthropic || exit 1
    fi
    echo "ok: $HARNESS"
    exit 0
    ;;
  codex|cx)
    # OpenAI/Codex: check the binary, skip API check (requires interactive auth).
    check_binary codex || exit 1
    echo "ok: $HARNESS"
    exit 0
    ;;
  opencode|ot)
    check_binary opencode || exit 1
    echo "ok: $HARNESS"
    exit 0
    ;;
  pi)
    check_binary pi || exit 1
    echo "ok: $HARNESS"
    exit 0
    ;;
  grok)
    check_binary grok || exit 1
    echo "ok: $HARNESS"
    exit 0
    ;;
  agy)
    check_binary agy || exit 1
    echo "ok: $HARNESS"
    exit 0
    ;;
  *)
    echo "ok: $HARNESS (unverified harness — no health check available)"
    exit 0
    ;;
esac
