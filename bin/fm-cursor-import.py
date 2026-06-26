#!/usr/bin/env python3
"""Import Cursor agent transcripts into sources/.

Cursor stores agent-transcript JSONL files at:
  ~/.cursor/projects/<project>/agent-transcripts/<uuid>/<uuid>.jsonl

Each file is one session with JSONL records containing:
  {role, message: {content: [{text, input, type, ...}]}}

Usage:
    python3 fm-cursor-import.py
"""

from __future__ import annotations

import json
import os
import sys
import time

SOURCE_DIR = os.path.expanduser("~/.cursor/projects")
TARGET_ROOT = os.path.expanduser(
    "~/.agent-rules/runtime/agent-memory-corpus/sources/cursor"
)

_total = 0
_session_ids: set[str] = set()
_start = time.time()
_errors = 0


def _write_record(session_id: str, record: dict) -> None:
    global _total
    if not session_id:
        return
    os.makedirs(TARGET_ROOT, exist_ok=True)
    file_path = os.path.join(TARGET_ROOT, f"{session_id}.jsonl")
    with open(file_path, "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")
    _total += 1
    _session_ids.add(session_id)


def _extract_text(content: list | str | None) -> str:
    if content is None:
        return ""
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
                    inp = item["input"]
                    if isinstance(inp, dict):
                        parts.append(json.dumps(inp, ensure_ascii=False))
                    else:
                        parts.append(str(inp))
                elif t == "tool_result" and item.get("content"):
                    parts.append(_extract_text(item["content"]))
        return "\n".join(parts)
    return str(content)


def _process_file(filepath: str, project: str) -> None:
    """Parse a cursor agent-transcript JSONL file."""
    global _errors
    session_id = os.path.basename(os.path.dirname(filepath))

    if not session_id or len(session_id) < 10:
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

                role = rec.get("role", "unknown")
                msg = rec.get("message", {})
                content_parts = msg.get("content", [])

                # Cursor agent-transcript format has nested tool_use/tool_result
                # inside message.content[].{type, text, input}
                text = _extract_text(content_parts)
                if not text:
                    continue

                if role == "tool":
                    # Check for tool_use vs tool_result
                    if content_parts and isinstance(content_parts, list):
                        for item in content_parts:
                            if isinstance(item, dict):
                                if item.get("type") == "tool_use":
                                    role = "assistant"
                                elif item.get("type") == "tool_result":
                                    role = "tool"

                record = {
                    "session_id": session_id,
                    "type": "message",
                    "role": role,
                    "account": "cursor",
                    "agent": "cursor",
                    "project": project,
                    "timestamp": rec.get("timestamp", ""),
                    "content": text,
                    "content_length": len(text),
                    "file": filepath,
                }
                _write_record(session_id, record)
    except (OSError, json.JSONDecodeError) as e:
        _errors += 1
        if _errors <= 5:
            sys.stderr.write(f"  [warn] {filepath}: {e}\n")


def main() -> None:
    if not os.path.isdir(SOURCE_DIR):
        sys.stderr.write(f"[skip] {SOURCE_DIR} not found\n")
        return

    sys.stderr.write(f"[import] Cursor agent transcripts from {SOURCE_DIR}\n")

    total_files = 0
    for project_dir in sorted(os.listdir(SOURCE_DIR)):
        project_path = os.path.join(SOURCE_DIR, project_dir)
        if not os.path.isdir(project_path):
            continue

        agt_dir = os.path.join(project_path, "agent-transcripts")
        if not os.path.isdir(agt_dir):
            continue

        for session_dir in sorted(os.listdir(agt_dir)):
            session_path = os.path.join(agt_dir, session_dir)
            if not os.path.isdir(session_path):
                continue

            jsonl_name = f"{session_dir}.jsonl"
            jsonl_path = os.path.join(session_path, jsonl_name)
            if not os.path.isfile(jsonl_path):
                continue

            _process_file(jsonl_path, project_dir)
            total_files += 1

            if total_files % 200 == 0:
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
