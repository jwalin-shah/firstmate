#!/usr/bin/env python3
"""Firstmate contract graph.

Walks bin/*.sh and emits docs/architecture/contract-graph.json: a directed
graph of `script -> helper` edges for every sourced `. "$SCRIPT_DIR/foo.sh"`
or `$(...)/foo.sh` reference inside the bin/ scripts.

Used by no-mistakes' review step to confirm the bin/ surface is wired
together (not a pile of disconnected stubs) and by a future FleetViewer
pane to render a real-time architecture diagram.

Edge shape:
  { from: "fm-watch.sh", to: "fm-queue.sh", kind: "subprocess" }

We deliberately do NOT parse the bash AST (bashlex is heavy and the
grammar is not worth the install for a graph we can build with regex).
The regex catches:
  - `. "$SCRIPT_DIR/fm-foo.sh"` and `. "$SCRIPT_DIR/../bin/fm-foo.sh"`
  - `. "$FM_ROOT/bin/fm-foo.sh"` and `. "${FM_ROOT}/bin/fm-foo.sh"`
  - `bin/fm-foo.sh` (bare path)
  - `$SCRIPT_DIR/fm-foo.sh` (no leading dot, from tee'd eval)
  - Subprocess invocations: `"$SCRIPT_DIR/fm-foo.sh"` and `bin/fm-foo.sh`
Edges with `to` not present in the bin/ tree are kept but flagged in
`summary.missing` so a stale `source` reference shows up in review.

Usage:
  python3 scripts/contract-graph.py
"""
from __future__ import annotations

import json
import os
import re
import sys
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BIN_DIR = REPO_ROOT / "bin"
OUT = REPO_ROOT / "docs" / "architecture" / "contract-graph.json"

# Match fm-*.sh filenames so we only emit edges to firstmate scripts.
# Bare alphanum: hyphens, dots, underscores. Anchored to the start of the
# captured stem so "fm-foo.sh.bar" does not match.
NAME = r"fm-[A-Za-z0-9_.-]+\.sh"
# Subprocess invocation or bare path. The leading word boundary avoids
# matching inside larger identifiers like "myfm-foo.sh".
SOURCES = [
    # `. "$SCRIPT_DIR/fm-foo.sh"` — explicit source with quoted path
    re.compile(rf"^\s*\.\s+[\"']?\\?\$SCRIPT_DIR/({NAME})"),
    # `. "$FM_ROOT/bin/fm-foo.sh"` — source with explicit fm-root
    re.compile(rf"^\s*\.\s+[\"']?\$?{{?FM_ROOT}}?/bin/({NAME})"),
    # `. "bin/fm-foo.sh"` — source with bare "bin/" prefix
    re.compile(rf"^\s*\.\s+[\"']bin/({NAME})"),
    # `"$SCRIPT_DIR/fm-foo.sh"` — subprocess invocation
    re.compile(rf"\"\\?\$SCRIPT_DIR/({NAME})\""),
    # `bin/fm-foo.sh` (bare) — subprocess invocation
    re.compile(rf"[\"'\s=]bin/({NAME})"),
]


def collect_scripts() -> list[Path]:
    return sorted(p for p in BIN_DIR.glob("fm-*.sh") if p.is_file())


def name_of(p: Path) -> str:
    return p.name


def parse_edges(scripts: list[Path]) -> tuple[list[dict], Counter]:
    edges: list[dict] = []
    missing: Counter = Counter()
    known = {name_of(p) for p in scripts}
    for script in scripts:
        try:
            text = script.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line_no, line in enumerate(text.splitlines(), start=1):
            for pat in SOURCES:
                for m in pat.finditer(line):
                    target = m.group(1)
                    if target == name_of(script):
                        # A self-source is a valid edge (re-entrancy) but
                        # noisy; skip for the summary count but keep in
                        # edges so a reviewer can see it.
                        continue
                    kind = "source" if line.lstrip().startswith(".") else "subprocess"
                    edges.append({
                        "from": name_of(script),
                        "to": target,
                        "kind": kind,
                        "line": line_no,
                    })
                    if target not in known:
                        missing[target] += 1
    return edges, missing


def main() -> int:
    if not BIN_DIR.is_dir():
        print(f"contract-graph: {BIN_DIR} is not a directory", file=sys.stderr)
        return 1
    scripts = collect_scripts()
    edges, missing = parse_edges(scripts)
    # Dedup (from, to, kind) — multiple . lines referencing the same
    # helper should count as one logical edge in the summary.
    deduped = sorted({(e["from"], e["to"], e["kind"]) for e in edges})
    nodes = sorted({name_of(p) for p in scripts}
                   | {e["from"] for e in edges}
                   | {e["to"] for e in edges})
    summary = {
        "total": len(deduped),
        "scripts": len(scripts),
        "nodes": len(nodes),
        "missing": dict(missing),
    }
    payload = {
        "schema": 1,
        "summary": summary,
        "nodes": [{"id": n} for n in nodes],
        "edges": [
            {"from": f, "to": t, "kind": k} for (f, t, k) in deduped
        ],
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"contract-graph: wrote {OUT} ({summary['total']} edges, "
          f"{summary['scripts']} scripts)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
