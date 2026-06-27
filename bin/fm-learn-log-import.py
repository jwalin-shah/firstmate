#!/usr/bin/env python3
"""Parse data/learn-log.md and export entries to data/learn-log-parsed.jsonl.

Each ## section becomes one JSONL record. Structured task entries (written by
fm-teardown.sh) are parsed into typed fields; narrative entries are stored as
free-form content. Idempotent: rewrites the whole JSONL on every run.

Usage:
    python3 fm-learn-log-import.py [--learn-log PATH] [--out PATH]
"""
from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import asdict, dataclass, field
from typing import Optional

FM_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_LOG = os.path.join(FM_ROOT, "data", "learn-log.md")
DEFAULT_OUT = os.path.join(FM_ROOT, "data", "learn-log-parsed.jsonl")

# Matches: ## 2026-06-25 — task-id (kind, mode)
# or:      ## 2026-06-25 late — some narrative title
_HEADER_RE = re.compile(
    r"^## (\d{4}-\d{2}-\d{2}(?:\s+\w+)?) — (.+?)(?:\s+\((\w+),\s*(\S+)\))?$"
)
_FIELD_RE = re.compile(r"^(project|outcome|report-summary):\s*(.*)$")


@dataclass
class LearnEntry:
    date: str
    title: str
    task_id: Optional[str] = None
    kind: Optional[str] = None
    mode: Optional[str] = None
    project: Optional[str] = None
    outcome: Optional[str] = None
    report_summary: Optional[str] = None
    content: str = ""
    entry_type: str = "narrative"  # "task" or "narrative"
    tags: list = field(default_factory=list)


def parse_log(path: str) -> list[LearnEntry]:
    try:
        text = open(path).read()
    except FileNotFoundError:
        return []

    sections: list[tuple[str, str]] = []  # (header_line, body)
    current_header: Optional[str] = None
    current_lines: list[str] = []

    for line in text.splitlines():
        if line.startswith("## "):
            if current_header is not None:
                sections.append((current_header, "\n".join(current_lines).strip()))
            current_header = line
            current_lines = []
        elif current_header is not None:
            current_lines.append(line)

    if current_header is not None:
        sections.append((current_header, "\n".join(current_lines).strip()))

    entries: list[LearnEntry] = []
    for header, body in sections:
        m = _HEADER_RE.match(header)
        if not m:
            continue
        date_raw, title_raw, kind_raw, mode_raw = m.groups()
        date = date_raw.split()[0]  # strip " late" etc.

        entry = LearnEntry(date=date, title=title_raw)

        if kind_raw and mode_raw:
            entry.kind = kind_raw
            entry.mode = mode_raw
            entry.task_id = title_raw  # title IS the task-id for structured entries
            entry.entry_type = "task"
            # Parse structured fields from body
            body_lines = body.splitlines()
            content_lines: list[str] = []
            for line in body_lines:
                fm = _FIELD_RE.match(line)
                if fm:
                    key, val = fm.groups()
                    if key == "project":
                        entry.project = val
                    elif key == "outcome":
                        entry.outcome = val
                    elif key == "report-summary":
                        entry.report_summary = val
                elif line.strip() != "---":
                    content_lines.append(line)
            entry.content = "\n".join(content_lines).strip()
        else:
            entry.content = body

        entries.append(entry)

    return entries


def export_jsonl(entries: list[LearnEntry], out_path: str) -> int:
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        for e in entries:
            f.write(json.dumps(asdict(e), ensure_ascii=False) + "\n")
    return len(entries)


def main() -> None:
    log_path = DEFAULT_LOG
    out_path = DEFAULT_OUT
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--learn-log" and i + 1 < len(args):
            log_path = args[i + 1]; i += 2
        elif args[i] == "--out" and i + 1 < len(args):
            out_path = args[i + 1]; i += 2
        else:
            i += 1

    entries = parse_log(log_path)
    n = export_jsonl(entries, out_path)
    task_count = sum(1 for e in entries if e.entry_type == "task")
    print(f"[learn-log] {n} entries ({task_count} task, {n - task_count} narrative) → {out_path}")


if __name__ == "__main__":
    main()
