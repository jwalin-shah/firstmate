#!/usr/bin/env bash
# bin/fm-transcripts.sh — read-only inspector for harness session transcripts.
# Surfaces what's on disk: total sessions, file sizes, recent activity,
# keyword search across all .jsonl files.
#
# Usage:
#   bin/fm-transcripts.sh                  # summary
#   bin/fm-transcripts.sh list            # list all session files with mtime
#   bin/fm-transcripts.sh search <term>   # search all transcripts for a term
#   bin/fm-transcripts.sh show <id>       # show first 50 lines of a session
#   bin/fm-transcripts.sh stats           # per-tool counts for a recent session

set -u

# Per-account claude dirs: claude (main), claude-a, claude-b, claude-nvidia, claude-pioneer, claude-token
# All write their project transcripts to ~/.claude-<account>/projects/
CLAUDE_PROJECTS="$HOME/.claude/projects"
CLAUDE_A_PROJECTS="$HOME/.claude-a/projects"
CLAUDE_B_PROJECTS="$HOME/.claude-b/projects"
CLAUDE_NVIDIA_PROJECTS="$HOME/.claude-nvidia/projects"
CLAUDE_PIONEER_PROJECTS="$HOME/.claude-pioneer/projects"
CLAUDE_TOKEN_PROJECTS="$HOME/.claude-token/projects"
CODEX_SESSIONS="$HOME/.codex/sessions"
GEMINI_LOGS="$HOME/.gemini"

ALL_TRANSCRIPT_DIRS=(
  "$CLAUDE_PROJECTS"
  "$CLAUDE_A_PROJECTS"
  "$CLAUDE_B_PROJECTS"
  "$CLAUDE_NVIDIA_PROJECTS"
  "$CLAUDE_PIONEER_PROJECTS"
  "$CLAUDE_TOKEN_PROJECTS"
  "$CODEX_SESSIONS"
  "$GEMINI_LOGS"
)

cmd="${1:-summary}"

case "$cmd" in
  summary|"")
    echo "=== transcript store summary @ $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo ""
    total_files=0
    for d in "${ALL_TRANSCRIPT_DIRS[@]}"; do
      if [ -d "$d" ]; then
        count=$(find "$d" -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
        size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        recent=$(find "$d" -name "*.jsonl" -mmin -60 2>/dev/null | wc -l | tr -d ' ')
        echo "  $d: $count files, $size total, $recent in last hour"
        total_files=$((total_files + count))
      fi
    done
    echo ""
    echo "  TOTAL: $total_files transcript files"
    echo ""
    echo "--- 5 most recent sessions (across all dirs) ---"
    find "${ALL_TRANSCRIPT_DIRS[@]}" -name "*.jsonl" -type f 2>/dev/null \
      | xargs -I{} stat -f "%m %N" {} 2>/dev/null | sort -rn | head -5 \
      | while read mtime path; do
          ts=$(date -r "$mtime" "+%Y-%m-%d %H:%M" 2>/dev/null)
          printf "  %s  %s\n" "$ts" "$path"
        done
    ;;

  list)
    echo "=== all session files (mtime descending) ==="
    find "${ALL_TRANSCRIPT_DIRS[@]}" -name "*.jsonl" -type f 2>/dev/null \
      | xargs -I{} stat -f "%m %z %N" {} 2>/dev/null | sort -rn | head -50 \
      | while read mtime size path; do
          ts=$(date -r "$mtime" "+%Y-%m-%d %H:%M" 2>/dev/null)
          printf "  %s  %10s  %s\n" "$ts" "$size" "$path"
        done
    ;;

  search)
    term="${2:?usage: bin/fm-transcripts.sh search <term>}"
    echo "=== searching transcripts for: $term ==="
    rg -l "$term" "${ALL_TRANSCRIPT_DIRS[@]}" 2>/dev/null \
      | head -10 | while read f; do
        matches=$(rg -c "$term" "$f" 2>/dev/null)
        printf "  %s matches: %s\n" "$f" "$matches"
      done
    ;;

  show)
    file="${2:?usage: bin/fm-transcripts.sh show <path-or-id>}"
    if [ ! -f "$file" ]; then
      file=$(find "${ALL_TRANSCRIPT_DIRS[@]}" -name "*${file}*" 2>/dev/null | head -1)
    fi
    if [ -z "$file" ] || [ ! -f "$file" ]; then
      echo "not found: $file" >&2
      exit 1
    fi
    echo "=== first 60 lines of $file ==="
    head -60 "$file"
    ;;

  stats)
    file="${2:?usage: bin/fm-transcripts.sh stats <path-or-id>}"
    if [ ! -f "$file" ]; then
      file=$(find "${ALL_TRANSCRIPT_DIRS[@]}" -name "*${file}*" 2>/dev/null | head -1)
    fi
    if [ -z "$file" ] || [ ! -f "$file" ]; then
      echo "not found" >&2
      exit 1
    fi
    echo "=== tool-use stats for $file ==="
    jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' "$file" 2>/dev/null \
      | sort | uniq -c | sort -rn | head -10
    echo ""
    echo "--- message counts ---"
    jq -r '.type' "$file" 2>/dev/null | sort | uniq -c | sort -rn
    ;;

  *)
    echo "usage: bin/fm-transcripts.sh [summary|list|search|show|stats] [args]" >&2
    exit 1
    ;;
esac
