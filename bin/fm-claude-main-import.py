#!/usr/bin/env python3
"""Import Claude Code main account (~/.claude/) transcripts into sources/.

The ~/.claude/ format uses a different schema from ~/.claude-a/ / ~/.claude-b/:
- JSONL files per session under ~/.claude/projects/<project>/
- Records have: type, sessionId, message{role, content}, timestamp, uuid, cwd
- Types: user, assistant, tool, system, mode, permission-mode, file-history-snapshot, etc.

This script reads the raw files directly and writes to the sources/ dir
in the format cocoindex expects. No fm-live-stream needed for this source.

Usage:
    python3 fm-claude-main-import.py
"""

from __future__ import annotations

import json
import os
import sys
import time

SOURCE_DIR = os.path.expanduser("~/.claude/projects")
TARGET_ROOT = os.path.expanduser(
    "~/.agent-rules/runtime/agent-memory-corpus/sources/claude-.claude-main"
)

# Map source dir names to canonical project names
PROJECT_MAP: dict[str, str] = {}

# Stats
_total = 0
_session_ids: set[str] = set()
_start = time.time()
_errors = 0


def _write_record(session_id: str, record: dict) -> None:
    """Append one record to the session file."""
    global _total
    if not session_id:
        return
    os.makedirs(TARGET_ROOT, exist_ok=True)
    file_path = os.path.join(TARGET_ROOT, f"{session_id}.jsonl")
    with open(file_path, "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")
    _total += 1
    _session_ids.add(session_id)


def _extract_text(msg: dict | str | None) -> str:
    """Extract text content from a message."""
    if msg is None:
        return ""
    if isinstance(msg, str):
        return msg
    if isinstance(msg, dict):
        # Direct content
        content = msg.get("content", "")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = []
            for item in content:
                if isinstance(item, str):
                    parts.append(item)
                elif isinstance(item, dict):
                    t = item.get("type", "")
                    if t == "text" and item.get("text"):
                        parts.append(str(item["text"]))
                    elif t == "tool_use" and item.get("input"):
                        parts.append(str(item["input"]))
                    elif t == "tool_result" and item.get("content"):
                        parts.append(_extract_text(item["content"]))
            return "\n".join(parts)
        return str(content) if content else ""
    return str(msg)


def _process_file(filepath: str, project: str) -> None:
    """Parse one session JSONL file and write records."""
    global _errors
    dir_name = os.path.basename(os.path.dirname(filepath))
    # Session ID is the filename without extension
    session_id = os.path.basename(filepath).replace(".jsonl", "")

    if not session_id or session_id.startswith("."):
        return

    # Check if this is a session file or a subagent file
    # Subagent files are in subdirectories named after the session
    if "/subagents/" in filepath or session_id.count("-") < 4:
        return

    try:
        with open(filepath) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue

                record_type = rec.get("type", "unknown")
                sid = rec.get("sessionId") or session_id

                role = "unknown"
                content = ""

                if record_type == "user":
                    msg = rec.get("message", {})
                    role = "user"
                    content = _extract_text(msg)
                elif record_type == "assistant":
                    msg = rec.get("message", {})
                    role = "assistant"
                    content = _extract_text(msg)
                elif record_type in ("tool", "tool_use"):
                    role = "tool"
                    content = _extract_text(rec.get("message", {}))
                elif record_type == "system":
                    role = "system"
                    content = rec.get("content", "")
                    if not content:
                        content = _extract_text(rec.get("message", {}))
                else:
                    # Skip metadata records (mode, permission-mode, etc.)
                    continue

                if not content:
                    continue

                record = {
                    "session_id": sid,
                    "type": "message",
                    "role": role,
                    "account": "claude-main",
                    "agent": "claude",
                    "project": project,
                    "timestamp": rec.get("timestamp", ""),
                    "content": content,
                    "content_length": len(content),
                    "file": filepath,
                }
                _write_record(sid, record)
    except (OSError, json.JSONDecodeError) as e:
        _errors += 1
        if _errors <= 5:
            sys.stderr.write(f"  [warn] {filepath}: {e}\n")


def main() -> None:
    if not os.path.isdir(SOURCE_DIR):
        sys.stderr.write(f"[skip] {SOURCE_DIR} not found\n")
        return

    sys.stderr.write(f"[import] Claude main from {SOURCE_DIR}\n")

    # Walk the full dir structure to find all project sessions
    total_files = 0
    for project_dir in sorted(os.listdir(SOURCE_DIR)):
        project_path = os.path.join(SOURCE_DIR, project_dir)
        if not os.path.isdir(project_path):
            continue
        project_name = project_dir

        # Walk this project directory
        for root, dirs, files in os.walk(project_path):
            # Skip subagent and private-tmp dirs
            dirs[:] = [d for d in dirs if d not in ("subagents", "private-tmp", "scratch", "backups")]
            for fname in sorted(files):
                if not fname.endswith(".jsonl"):
                    continue
                fpath = os.path.join(root, fname)
                _process_file(fpath, project_name)
                total_files += 1

                if total_files % 50 == 0:
                    elapsed = time.time() - _start
                    sys.stderr.write(
                        f"  {_total} records, {len(_session_ids)} sessions, "
                        f"{total_files} files in {elapsed:.1f}s\n"
                    )

    elapsed = time.time() - _start
    sys.stderr.write(
        f"[done] {_total} records, {len(_session_ids)} sessions, "
        f"{total_files} files in {elapsed:.1f}s"
        f"{' (' + str(_errors) + ' errors)' if _errors else ''}\n"
    )


if __name__ == "__main__":
    main()
