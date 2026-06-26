#!/usr/bin/env bash
# Bulk-import all existing transcript data into the cocoindex sources/ directory,
# then set up ongoing piping from the fm-live-stream daemon.
#
# Phase 1: Run fm-live-stream --once for all accounts, pipe through
#          fm-transcripts-ingest.py to create per-session JSONL files under
#          ~/.agent-rules/runtime/agent-memory-corpus/sources/<agent-dir>/<session_id>.jsonl
#
# Phase 2 (optional): restart the fm-live-stream daemon so its stdout pipes
#          through the splitter for ongoing data flow. Pass --daemon-pipe to
#          also do Phase 2.
#
# The sources/ directory is what the cocoindex app watches for transcript files.
# After this runs, the cocoindex daemon will pick up transcripts on its next sweep.
#
# Usage:
#   fm-transcripts-ingest.sh              # bulk import only
#   fm-transcripts-ingest.sh --daemon-pipe  # bulk import + set up daemon pipe
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$FM_ROOT/bin/fm-init.sh"
SOURCES_DIR="$HOME/.agent-rules/runtime/agent-memory-corpus/sources"
LIVE_STREAM_BIN="$HOME/bin/fm-live-stream"
INGEST_PY="$FM_ROOT/bin/fm-transcripts-ingest.py"
PLIST_PATH="$HOME/Library/LaunchAgents/com.jwalin.fm-live-stream.plist"

DO_DAEMON_PIPE=0
for a in "$@"; do
  case "$a" in
    --daemon-pipe) DO_DAEMON_PIPE=1 ;;
  esac
done

# ---- Phase 1: Bulk import ----
echo "--- Phase 1: Bulk import ---"
echo "Sources dir: $SOURCES_DIR"
echo ""

mkdir -p "$SOURCES_DIR"

# Run fm-live-stream --once for each account individually (not all at once)
# so we get clean per-account output that maps precisely to the sources/ dirs.
for account in account-a account-b tokenrouter pioneer codex pi opencode gemini; do
  case "$account" in
    account-a) dir="$HOME/.claude-a/projects" ;;
    account-b) dir="$HOME/.claude-b/projects" ;;
    tokenrouter) dir="$HOME/.claude-token/projects" ;;
    pioneer) dir="$HOME/.claude-pioneer/projects" ;;
    codex) dir="$HOME/.codex/sessions" ;;
    pi) dir="$HOME/.pi/agent/sessions" ;;
    opencode) dir="$HOME/.local/state/opencode/prompt-history.jsonl" ;;
    gemini) dir="$HOME/.gemini/antigravity-cli/history.jsonl" ;;
  esac

  if [ ! -e "$dir" ]; then
    echo "[skip] $account — $dir not found"
    continue
  fi

  echo "[ingest] $account ($dir)"
  "$LIVE_STREAM_BIN" --once "$dir" 2>/dev/null | python3 "$INGEST_PY"
  echo "[done]  $account"
  echo ""
done

echo "--- Bulk import complete ---"
echo ""
eza --tree --level=1 "$SOURCES_DIR" 2>/dev/null || echo "(no files yet)"

# ---- Phase 2: Set up daemon pipe ----
if [ "$DO_DAEMON_PIPE" != 1 ]; then
  echo ""
  echo "Phase 1 done. Pass --daemon-pipe to also pipe the live daemon through the splitter."
  exit 0
fi

echo ""
echo "--- Phase 2: Setting up daemon pipe ---"

# Unload current daemon if running
if launchctl list com.jwalin.fm-live-stream >/dev/null 2>&1; then
  echo "[plist] unloading existing fm-live-stream daemon..."
  launchctl bootout "gui/$(id -u)/com.jwalin.fm-live-stream" 2>/dev/null || \
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
  sleep 1
fi

 # The plist uses bash -c with an inline pipe (launchd cannot run pipelines).
 # Old wrapper script was removed; pipe is in ProgramArguments below.

 # Update the plist
cat > "$PLIST_PATH" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.jwalin.fm-live-stream</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>exec $LIVE_STREAM_BIN 2>/dev/null | python3 $INGEST_PY</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>            <string>$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key>            <string>$HOME</string>
  </dict>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <true/>
  <key>StandardOutPath</key>  <string>$HOME/tools/fm-sessiond/fm-live-stream.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/tools/fm-sessiond/fm-live-stream.err.log</string>
</dict>
</plist>
PLISTEOF

# Load the updated daemon
echo "[plist] loading updated fm-live-stream daemon..."
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || \
  launchctl load -w "$PLIST_PATH" 2>/dev/null || true

sleep 1
if launchctl list com.jwalin.fm-live-stream >/dev/null 2>&1; then
  echo "[ok] fm-live-stream daemon running with pipe to splitter"
else
  echo "[warn] daemon didn't start — check logs:"
  echo "  $HOME/tools/fm-sessiond/fm-live-stream.err.log"
fi

echo ""
echo "--- Phase 2 complete ---"
echo "New transcripts will now flow into $SOURCES_DIR"
echo "The cocoindex daemon will pick them up on its next sweep (~10-60s)."
