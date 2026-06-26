#!/usr/bin/env bash
# fm-lang-cache.sh — populate or read ~/.agent-rules/lang-cache/<lang>.md
#
# One canonical example per language, fetched once via `githits-axi example`
# and cached permanently. The cache never refreshes; delete the file to force
# a re-population on next read. Network call only happens when the file is
# missing, so firstmate brief generation stays network-free in the hot path.
#
# Usage:
#   bin/fm-lang-cache.sh <lang>           # print cached file (populate if absent)
#   bin/fm-lang-cache.sh <lang> --refresh # force re-population
#
# Exit codes:
#   0  success (file existed or was populated)
#   1  invalid arg or githits-axi failed
#   2  cache file absent and network call refused (offline mode)
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$FM_ROOT/bin/fm-init.sh"
CACHE_DIR="${FM_LANG_CACHE_DIR:-$HOME/.agent-rules/lang-cache}"
mkdir -p "$CACHE_DIR"

LANG="${1:-}"
REFRESH=0
for a in "$@"; do
  case "$a" in
    --refresh) REFRESH=1 ;;
  esac
done

if [ -z "$LANG" ]; then
  echo "usage: $0 <lang> [--refresh]" >&2
  exit 1
fi

# Allowlist: only the five canonical langs for now. Extend by editing this list
# AND adding an entry in AGENTS.md "Language cache" section.
case "$LANG" in
  go|swift|zig|lua|python) ;;
  *) echo "error: $LANG is not a supported language cache key (go|swift|zig|lua|python)" >&2; exit 1 ;;
esac

CACHE_FILE="$CACHE_DIR/$LANG.md"

# Hot path: cached file exists, print it.
if [ "$REFRESH" = 0 ] && [ -s "$CACHE_FILE" ]; then
  cat "$CACHE_FILE"
  exit 0
fi

# Cold path: populate via githits-axi. Pick a canonical pattern per language —
# the cache is one-shot, so pick something the crewmate is most likely to need.
case "$LANG" in
  go)     QUERY="go idiomatic error handling errors.Is errors.As" ;;
  swift)  QUERY="swift async actor concurrency" ;;
  zig)    QUERY="zig comptime allocator pattern" ;;
  lua)    QUERY="lua pcall error handling pattern" ;;
  python) QUERY="python contextmanager type hints" ;;
esac

if ! command -v githits-axi >/dev/null 2>&1; then
  echo "error: githits-axi not on PATH and cache file $CACHE_FILE is missing" >&2
  exit 2
fi

RAW="$(githits-axi example "$QUERY" 2>/dev/null)" || {
  rc=$?
  echo "error: githits-axi example failed for $LANG (rc=$rc)" >&2
  exit 1
}

# Parse the JSON envelope and trim the GitHits Web App footer.
# Use python for robust parsing — githits-axi returns {"result":"...","solution_id":"..."}.
CLEAN="$(printf '%s' "$RAW" | python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
text = data.get("result", "")
end = "\n\n---\n\n[Open in GitHits Web App]"
if end in text:
    text = text.split(end)[0]
sys.stdout.write(text.rstrip() + "\n")
')" || {
  echo "error: failed to parse githits-axi response for $LANG" >&2
  exit 1
}

printf '%s\n' "$CLEAN" > "$CACHE_FILE"
cat "$CACHE_FILE"