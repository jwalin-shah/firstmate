#!/usr/bin/env python3
"""Read fm-live-stream NDJSON from stdin, write per-session JSONL files to
~/.agent-rules/runtime/agent-memory-corpus/sources/<agent-dir>/<session_id>.jsonl

The directory structure matches what cocoindex_app.py's _transcript_source() checks,
so that daemon picks up transcripts on its next sweep.

Usage (bulk import of all existing data):
    fm-live-stream --once | fm-transcripts-ingest.py

Usage (daemon pipe — ongoing):
    fm-live-stream | fm-transcripts-ingest.py

Idempotent: appends to existing files. Run `fm-live-stream --once` once for the
full backfill, then pipe the daemon for live data. No duplicates because
cocoindex uses content-derived row IDs with ON CONFLICT upsert.

The ctrl+c within to avoid interruption is intentional — the Python buffers
output and writes efficiently.
"""

from __future__ import annotations

import json
import os
import sys
import time
from typing import IO

SOURCE_ROOT = os.path.expanduser(
    "~/.agent-rules/runtime/agent-memory-corpus/sources"
)

# Maps fm-live-stream account names → sources subdirectory names
# matching _transcript_source() in cocoindex_app.py
ACCOUNT_TO_SUBDIR: dict[str, str] = {
    "account-a": "claude-.claude-a",
    "account-b": "claude-.claude-b",
    "tokenrouter": "claude-.claude-token",
    "pioneer": "claude-.claude-pioneer",
    "codex": "codex",
    "pi": "pi",
    "opencode": "opencode",
    "gemini": "gemini",
}


def _source_dir(account: str) -> str:
    """Return the sources subdirectory for an account name."""
    return ACCOUNT_TO_SUBDIR.get(account, account)


# Keep only the N most-recently-used file handles open to avoid EMFILE.
# Transcripts arrive in session order from fm-live-stream so the working set
# is small; capping at 64 handles is plenty for the live daemon case.
_MAX_OPEN = 64
_open_files: dict[tuple[str, str], IO] = {}   # LRU order via insertion order
_open_order: list[tuple[str, str]] = []        # tracks insertion order for eviction
_line_count = 0
_session_count: set[str] = set()
_start_time = time.time()


def _write_record(record: dict) -> None:
    """Append one NDJSON record to its session file under sources/."""
    global _line_count
    account = record.get("account", "unknown")
    session_id = record.get("session_id", "")
    if not session_id:
        return

    subdir = _source_dir(account)
    key = (subdir, session_id)

    fh = _open_files.get(key)
    if fh is None:
        # Evict oldest handle if at cap
        while len(_open_files) >= _MAX_OPEN and _open_order:
            old_key = _open_order.pop(0)
            old_fh = _open_files.pop(old_key, None)
            if old_fh:
                try:
                    old_fh.close()
                except OSError:
                    pass
        dir_path = os.path.join(SOURCE_ROOT, subdir)
        os.makedirs(dir_path, exist_ok=True)
        file_path = os.path.join(dir_path, f"{session_id}.jsonl")
        fh = open(file_path, "a")
        _open_files[key] = fh
        _open_order.append(key)

    _line_count += 1
    _session_count.add(session_id)
    fh.write(json.dumps(record, ensure_ascii=False) + "\n")


def _flush_and_report() -> None:
    """Flush all open files and print a progress line."""
    for fh in _open_files.values():
        fh.flush()
    elapsed = time.time() - _start_time
    stats = {
        "records": _line_count,
        "sessions": len(_session_count),
        "files": len(_open_files),
        "elapsed_s": round(elapsed, 1),
        "rate": round(_line_count / elapsed, 1) if elapsed > 0 else 0,
    }
    sys.stderr.write(
        f"[ingest] {stats['records']} records, {stats['sessions']} sessions, "
        f"{stats['files']} files in {stats['elapsed_s']}s "
        f"({stats['rate']}/s)\n"
    )


def main() -> None:
    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            _write_record(record)

            # Periodic progress every 50K records
            if _line_count > 0 and _line_count % 50_000 == 0:
                _flush_and_report()
    except KeyboardInterrupt:
        pass
    finally:
        _flush_and_report()
        for fh in _open_files.values():
            fh.close()


if __name__ == "__main__":
    main()
