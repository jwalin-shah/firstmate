#!/usr/bin/env bash
# Comprehensive agent transcript discovery and import.
#
# Finds ALL session/transcript data across every agent on this machine,
# imports what isn't already in the cocoindex sources/ directory.
#
# Run: fm-transcripts-discover.sh
# After: check sources/ breakdown, cocoindex will pick up new files
set -euo pipefail

SOURCES_DIR="$HOME/.agent-rules/runtime/agent-memory-corpus/sources"
INGEST_PY="$HOME/projects/firstmate/bin/fm-transcripts-ingest.py"
LIVE_STREAM="$HOME/bin/fm-live-stream"

mkdir -p "$SOURCES_DIR"

echo "=== Comprehensive Transcript Discovery ==="
echo ""

# ── 1. Gemini tmp/ chats (not just history.jsonl) ─────────────────────────
echo "--- 1. Gemini tmp/chat sessions ---"
# gemini stores chat sessions under ~/.gemini/tmp/<user>/chats/
for userdir in "$HOME"/.gemini/tmp/*/; do
  [ -d "$userdir" ] || continue
  username=$(basename "$userdir")
  chatsdir="$userdir/chats"
  if [ -d "$chatsdir" ]; then
    count=$(fd -e jsonl . "$chatsdir" 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
      echo "  Found $count chat files for user '$username'"
      "$LIVE_STREAM" --once "$chatsdir" 2>/dev/null | python3 "$INGEST_PY" || true
    fi
  fi
done

# ── 2. Codex history.jsonl ────────────────────────────────────────────────
echo ""
echo "--- 2. Codex history.jsonl ---"
if [ -f "$HOME/.codex/history.jsonl" ]; then
  lines=$(wc -l < "$HOME/.codex/history.jsonl" 2>/dev/null || echo 0)
  echo "  Codex history: $lines lines"
  # history.jsonl has a different format from sessions
  python3 -c "
import json, os
src = os.path.expanduser('~/.codex/history.jsonl')
out = os.path.expanduser('$SOURCES_DIR/codex/history.jsonl')
os.makedirs(os.path.dirname(out), exist_ok=True)
count = 0
with open(src) as f, open(out, 'a') as o:
    for line in f:
        if not line.strip(): continue
        record = {'session_id': 'codex-history', 'type': 'message', 'role': 'unknown',
                  'account': 'codex', 'agent': 'codex', 'content': line.strip()}
        o.write(json.dumps(record, ensure_ascii=False) + '\n')
        count += 1
        if count % 100 == 0:
            break  # cap at 100 to avoid bloat
print(f'  Imported {count} history records')
" 2>/dev/null || true
fi

# ── 3. AGY antigravity-cli brain (markdown knowledge docs) ────────────────
echo ""
echo "--- 3. AGY brain (markdown knowledge docs) ---"
# Add AGY brain as a code source by symlinking into a project structure,
# OR create a symlink under sources/ that cocoindex will pick up.
# The brain contains .md files with .metadata.json — not transcripts.
# Best handled as CODE docs. Create a project-like structure.
AGY_PROJ="$HOME/projects/agy-brain"
if [ ! -L "$AGY_PROJ" ] && [ ! -d "$AGY_PROJ" ]; then
  ln -sf "$HOME/.gemini/antigravity-cli/brain" "$AGY_PROJ"
  echo "  Symlinked AGY brain → $AGY_PROJ"
  echo "  (cocoindex will pick up .md files on next sweep via LIVE/ACTIVE walk)"
fi
brain_files=$(fd -t f . "$HOME/.gemini/antigravity-cli/brain/" 2>/dev/null | wc -l)
brain_size=$(du -sh "$HOME/.gemini/antigravity-cli/brain/" 2>/dev/null | cut -f1)
echo "  AGY brain: $brain_files files ($brain_size)"

# ── 4. orchestrator-transcripts-export ────────────────────────────────────
echo ""
echo "--- 4. Orchestrator transcripts export ---"
if [ -d "$HOME/orchestrator-transcripts-export" ]; then
  fd -e jsonl . "$HOME/orchestrator-transcripts-export/" 2>/dev/null | while read f; do
    cat "$f" | "$LIVE_STREAM" --once 2>/dev/null | python3 "$INGEST_PY" || true
  done
  echo "  Imported orchestrator transcripts"
fi

# ── 5. Documents/Codex/ ──────────────────────────────────────────────────
echo ""
echo "--- 5. Documents/Codex/ sessions ---"
if [ -d "$HOME/Documents/Codex" ]; then
  fd -e jsonl . "$HOME/Documents/Codex/" 2>/dev/null | while read f; do
    cat "$f" | "$LIVE_STREAM" --once 2>/dev/null | python3 "$INGEST_PY" || true
  done
  echo "  Imported Documents/Codex/"
fi

# ── 6. sia-runs/ and grind-runs/ (agent event logs) ─────────────────────
echo ""
echo "--- 6. Grind runs / SIA runs ---"
for dir in "$HOME/sia-runs" "$HOME/grind-runs" "$HOME/router/supervisors"; do
  if [ -d "$dir" ]; then
    size=$(du -sh "$dir" 2>/dev/null | cut -f1)
    count=$(fd -e jsonl . "$dir" 2>/dev/null | wc -l)
    echo "  $dir: $count JSONL files ($size)"
    fd -e jsonl . "$dir" 2>/dev/null | while read f; do
      # Skip large training data files
      size=$(stat -f%z "$f" 2>/dev/null || echo 0)
      if [ "$size" -gt 10000000 ]; then
        echo "    (skip $f — >10MB)"
        continue
      fi
      "$LIVE_STREAM" --once "$(dirname "$f")" 2>/dev/null | python3 "$INGEST_PY" || true
    done
  fi
done

# ── 7. Summary ────────────────────────────────────────────────────────────
echo ""
echo "=== Post-import summary ==="
total_files=0
total_records=0
for d in "$SOURCES_DIR"/*/; do
  name=$(basename "$d")
  files=$(fd -e jsonl . "$d" 2>/dev/null | wc -l | tr -d ' ')
  records=$(fd -e jsonl . "$d" 2>/dev/null --exec wc -l 2>/dev/null | awk '{s+=$1} END {print s}' | tr -d ' ')
  echo "  $name: $files files, $records records"
  total_files=$((total_files + files))
  total_records=$((total_records + records))
done
echo "  ---"
echo "  TOTAL: $total_files files, $total_records records"
echo ""
echo "Sources dir: $SOURCES_DIR"
echo "Cocoindex will pick up new files on next daemon sweep."
