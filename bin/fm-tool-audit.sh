#!/usr/bin/env bash
# bin/fm-tool-audit.sh — tool-use audit for a single session or for a captain's last 24h.
#
# Usage:
#   bin/fm-tool-audit.sh <session-file>      # audit one session
#   bin/fm-tool-audit.sh --last 24h          # aggregate last 24h of sessions
#   bin/fm-tool-audit.sh --all claude         # all claude sessions, last 7 days

set -euo pipefail

CLAUDE_PROJECTS="$HOME/.claude/projects"

audit_session() {
  local file="$1"
  echo "=== $file ==="
  local total_lines=$(wc -l < "$file" 2>/dev/null)
  local total_bytes=$(stat -f "%z" "$file" 2>/dev/null)
  echo "  size: $total_bytes bytes, $total_lines lines"

  if ! command -v jq >/dev/null 2>&1; then
    echo "  (jq not found; install for full stats)"
    return
  fi

  echo "  --- tool calls by type ---"
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' "$file" 2>/dev/null \
    | sort | uniq -c | sort -rn | head -10 | awk '{printf "    %4d  %s\n", $1, $2}'

  echo "  --- bash subcommands (top 10) ---"
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | select(.name == "Bash") | .input.command // ""' "$file" 2>/dev/null \
    | awk '{print $1}' | sort | uniq -c | sort -rn | head -10 | awk '{printf "    %4d  %s\n", $1, $2}'

  echo "  --- files edited (top 10) ---"
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | select(.name == "Edit" or .name == "Write") | .input.file_path // ""' "$file" 2>/dev/null \
    | sort | uniq -c | sort -rn | head -10 | awk '{printf "    %4d  %s\n", $1, $2}'
}

case "${1:-}" in
  --last)
    window="${2:-24h}"
    echo "=== last $window of claude sessions ==="
    find "$CLAUDE_PROJECTS" -name "*.jsonl" -mmin -1440 2>/dev/null | head -5 | while read f; do
      audit_session "$f"
      echo ""
    done
    ;;

  --all)
    who="${2:-claude}"
    case "$who" in
      claude) find "$CLAUDE_PROJECTS" -name "*.jsonl" -mtime -7 2>/dev/null | head -5 | while read f; do
                audit_session "$f"
                echo ""
              done ;;
      *) echo "only claude supported for now"; exit 1 ;;
    esac
    ;;

  --help|"")
    echo "usage:"
    echo "  bin/fm-tool-audit.sh <session.jsonl>      # audit one session"
    echo "  bin/fm-tool-audit.sh --last 24h          # last 24h of claude sessions"
    echo "  bin/fm-tool-audit.sh --all claude        # last 7 days of claude sessions"
    exit 1
    ;;

  *)
    if [ -f "$1" ]; then
      audit_session "$1"
    else
      # treat as session id, find first matching file
      found=$(find "$CLAUDE_PROJECTS" -name "*${1}*" 2>/dev/null | head -1)
      if [ -n "$found" ]; then
        audit_session "$found"
      else
        echo "not found: $1" >&2
        exit 1
      fi
    fi
    ;;
esac
