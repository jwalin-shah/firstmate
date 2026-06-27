#!/usr/bin/env bash
# bin/fm-reflect.sh — quality reflection for crewmate output (Reflection pattern, Ch 4).
# Called from fm-teardown.sh after a crewmate finishes. Checks output quality using
# simple heuristic probes (no LLM calls). Outputs structured JSON; appends verdict to
# learn-log.md. All exits are 0 — failures are non-fatal.
# Usage: fm-reflect.sh <task-id> <artifact-path> [--scout|--ship]
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$FM_ROOT/bin/fm-init.sh"
ID="${1:-}"; ARTIFACT="${2:-}"; KIND="ship"
[ -n "$ID" ] || { echo '{"error":"no task-id","verdict":"needs-review"}'; exit 0; }
[ -n "$ARTIFACT" ] || { echo '{"error":"no artifact-path","verdict":"needs-review"}'; exit 0; }
[ "${3:-}" = "--scout" ] && KIND="scout"

python3 - "$ID" "$ARTIFACT" "$KIND" <<'PYEOF' || true
import json, os, re, subprocess, sys

tid, artifact, kind = sys.argv[1], sys.argv[2], sys.argv[3]
passed, failed = [], []

size = os.path.getsize(artifact) if os.path.isfile(artifact) else 0
ok = size > 100
c = {"check":"artifact-exists","label":"Artifact exists with content","detail":f"size={size}b","pass":ok}
passed.append(c)
if not ok: failed.append(c)

if kind == "scout" or artifact.endswith(".md"):
    with open(artifact) as f: text = f.read()
    has_goal = bool(re.search(r'(?i)^##?\s*goal', text, re.MULTILINE))
    has_findings = bool(re.search(r'(?i)^##?\s*findings', text, re.MULTILINE))
    has_recs = bool(re.search(r'(?i)^##?\s*recommendations?', text, re.MULTILINE))
    ok = has_goal and has_findings and has_recs
    detail = f"Goal={'Y' if has_goal else 'N'} Findings={'Y' if has_findings else 'N'} Recommendations={'Y' if has_recs else 'N'}"
    c = {"check":"report-sections","label":"Report has required sections","detail":detail,"pass":ok}
    passed.append(c)
    if not ok: failed.append(c)

    if kind == "scout":
        ok = bool(re.search(r'\b[\w./-]+\.[a-z]+:\d+\b', text))
        c = {"check":"file-references","label":"Report contains file:line references","detail":"found" if ok else "none found","pass":ok}
        passed.append(c)
        if not ok: failed.append(c)

if kind == "ship" and os.path.isdir(artifact):
    try:
        r = subprocess.run(["git","-C",artifact,"diff","--stat"], capture_output=True,text=True,timeout=5)
        ok = bool(r.stdout.strip())
        detail = r.stdout.strip().split('\n')[0] if ok else "no diff (already merged or clean)"
    except Exception as e:
        ok = False; detail = str(e)
    c = {"check":"diff-changes","label":"Diff changes files","detail":detail,"pass":ok}
    passed.append(c)
    if not ok: failed.append(c)

verdict = "pass" if not failed else "needs-review"
result = {"task_id":tid,"kind":kind,"artifact":artifact,"checks_passed":passed,"checks_failed":failed,"verdict":verdict}
print(json.dumps(result, indent=2))

log = os.path.join(os.environ.get("FM_ROOT",""), "data", "learn-log.md")
if os.path.isfile(log):
    with open(log) as f: content = f.read()
    tag = f" — {tid} "
    idx = content.rfind(tag)
    if idx >= 0:
        hdr = content.rfind("\n##", 0, idx)
        if hdr < 0: hdr = 0
        sep = content.find("\n---\n", hdr)
        if sep >= 0:
            before = content[:sep]
            rline = f"\nreflection: {json.dumps({'verdict':verdict,'checks':len(passed),'failed':len(failed)})}"
            after = content[sep:]
            with open(log, 'w') as f: f.write(before + rline + after)
PYEOF
