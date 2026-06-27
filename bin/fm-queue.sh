#!/usr/bin/env bash
# Firstmate queue display formatter.
# data/tasks.db (SQLite via fm-tasks) is the canonical task store.
# This script is a read-only display layer — it derives data/backlog.md from
# tasks.db and provides --mark-done self-healing. Do not add mutation subcommands;
# all writes go through `fm-tasks` to preserve WAL invariants.
#
# Usage:
#   fm-queue.sh to-markdown | --once  # derive data/backlog.md from data/tasks.db
#   fm-queue.sh --mark-done <id>      # self-heal: drive fm-tasks done/fail from meta+status
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$FM_ROOT/bin/fm-init.sh"
DATA="${FM_DATA_OVERRIDE:-$FM_ROOT/data}"
BACKLOG="$DATA/backlog.md"
TASKS_DB="${FM_TASKS_DB_OVERRIDE:-$DATA/tasks.db}"
mkdir -p "$DATA"

cmd=${1:-}
shift || true

case "$cmd" in
  add|set-status|set-pr|set-merged|set-report)
    echo "fm-queue.sh: '$cmd' is deprecated — use fm-tasks instead (SQLite is canonical)" >&2
    exit 1
    ;;

  get|list)
    echo "fm-queue.sh: '$cmd' is deprecated — use 'fm-tasks ls' instead (SQLite is canonical)" >&2
    exit 1
    ;;

  to-markdown|--once)
    # Derive data/backlog.md from data/tasks.db (SQLite — canonical store).
    # Output goes through a temp file + atomic rename so a reader of
    # backlog.md never sees a half-written file.
    #
    # When neither source has data, we still emit the three section headers
    # so the file shape stays consistent (a downstream parser should not
    # have to handle the "no sections" case).
    #
    # Parsing strategy: we hand the SQL rows to python3, which handles the
    # tab/pipe ambiguity in titles and never collapses empty fields. The
    # bash+sqlite3+read path loses empty fields because bash's `read` with
    # N explicit names silently coalesces consecutive IFS characters;
    # titles in tasks.db can contain `|`, `-`, and newlines, so a pure-bash
    # parser is fragile. Python is universal on macOS/Linux dev hosts and
    # adds no new dependency for firstmate.
    if ! command -v sqlite3 >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
      echo "fm-queue.sh to-markdown: requires sqlite3 and python3 on PATH" >&2
      exit 1
    fi
    [ -f "$TASKS_DB" ] || { echo "fm-queue.sh to-markdown: $TASKS_DB not found" >&2; exit 1; }

    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-queue-markdown.XXXXXX" 2>/dev/null || echo "$BACKLOG.tmp.$$")
    sqlite3 -separator $'\t' "$TASKS_DB" \
      "SELECT id, title, repo, kind, status, IFNULL(blocked_by,''), IFNULL(blocked_reason,''), IFNULL(pr_url,''), IFNULL(report_path,''), IFNULL(added_at,''), IFNULL(started_at,''), IFNULL(done_at,'') FROM tasks ORDER BY added_at ASC;" 2>/dev/null \
      | python3 -c '
import sys, datetime

def parse_dt(s):
    s = (s or "").strip()
    if not s: return ""
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.datetime.strptime(s, fmt).strftime("%Y-%m-%d")
        except ValueError:
            pass
    return s[:10]  # best-effort: first 10 chars

def line_split(row):
    # sqlite3 -separator with a real tab character (via ANSI-C quoting)
    # emits exactly N tabs. Titles in the DB
    # can contain newlines (brief excerpts), so we split on tab and let
    # the caller choose how to flatten title.
    return row.rstrip("\n").split("\t")

in_flight, queued, done = [], [], []
for raw in sys.stdin:
    parts = line_split(raw)
    # Pad short rows (defensive — should not happen with IFNULL everywhere).
    while len(parts) < 12:
        parts.append("")
    (tid, title, repo, kind, status, blocked_by, blocked_reason,
     pr_url, report_path, added_at, started_at, done_at) = parts[:12]
    if not tid: continue
    added_date = parse_dt(added_at)
    if status == "inflight":
        in_flight.append((tid, title, repo, added_date, blocked_by))
    elif status == "queued":
        queued.append((tid, title, repo, added_date, blocked_by, blocked_reason))
    elif status == "done":
        done_date = parse_dt(done_at)
        if kind == "scout":
            if report_path:
                done.append(("scout", tid, title, report_path, done_date))
        else:
            if pr_url:
                done.append(("pr", tid, title, pr_url, done_date))
            else:
                done.append(("local", tid, title, "", done_date))

out = []
out.append("# Fleet backlog")
out.append("")
out.append("Auto-derived from data/tasks.db (SQLite) by bin/fm-queue.sh to-markdown.")
out.append("Do not hand-edit; edits are overwritten on the next spawn/teardown/session.")
out.append("")
out.append("## In flight")
if in_flight:
    for tid, title, repo, added_date, _ in in_flight:
        out.append(f"- [ ] {tid} - {title} (repo: {repo}, since {added_date})".rstrip())
else:
    out.append("_none_")
out.append("")
out.append("## Queued")
if queued:
    for tid, title, repo, added_date, blocked_by, blocked_reason in queued:
        line = f"- [ ] {tid} - {title} (repo: {repo})"
        if blocked_by:
            line += f" blocked-by: {blocked_by}"
            if blocked_reason:
                line += f" - {blocked_reason}"
        out.append(line)
else:
    out.append("_none_")
out.append("")
out.append("## Done")
if done:
    # Keep the 10 most recent — match the policy in AGENTS.md section 10.
    done_sorted = sorted(done, key=lambda r: r[4], reverse=True)[:10]
    for kind, tid, title, url, date in done_sorted:
        if kind == "pr":
            out.append(f"- [x] {tid} - {title} - {url} (merged {date})")
        elif kind == "scout":
            out.append(f"- [x] {tid} - {title} - {url} (reported {date})")
        else:  # local
            out.append(f"- [x] {tid} - {title} - local main (merged {date})")
else:
    out.append("_none_")
out.append("")
sys.stdout.write("\n".join(out))
' > "$tmp"
    mv "$tmp" "$BACKLOG"
    printf 'fm-queue.sh: wrote %s\n' "$BACKLOG"
    ;;

  --mark-done)
    # Self-heal: finishes fm-tasks bookkeeping when teardown succeeded but
    # the fm-tasks done/fail call at the end of fm-teardown.sh was cut short.
    # fm-tasks is the single write authority for task status — we never
    # write to tasks.db directly. The only signal we need: the status file
    # ends with done: or failed:. Worktree and pane checks were removed
    # (Candidate 3) because teardown already verifies both before it runs;
    # re-checking them here just causes spurious refusals when the daemon
    # is temporarily down or the meta file was already cleaned up.
    ID=${1:?fm-queue.sh --mark-done: <id> required}
    if ! command -v fm-tasks >/dev/null 2>&1; then
      echo "fm-queue.sh --mark-done: fm-tasks binary not on PATH" >&2
      exit 1
    fi
    STATUS_FILE="$STATE/$ID.status"

    status_done=0
    status_failed=0
    if [ -f "$STATUS_FILE" ]; then
      last=$(tail -1 "$STATUS_FILE" 2>/dev/null || true)
      case "$last" in
        'done:'*)   status_done=1 ;;
        'failed:'*) status_failed=1 ;;
      esac
    fi

    if [ "$status_done" -ne 1 ] && [ "$status_failed" -ne 1 ]; then
      printf 'fm-queue.sh --mark-done %s: refusing (no done:/failed: in %s)\n' "$ID" "$STATUS_FILE" >&2
      exit 1
    fi

    if [ "$status_failed" -eq 1 ]; then
      if fm-tasks fail "$ID" 2>/dev/null; then
        printf 'fm-queue.sh --mark-done: failed %s\n' "$ID"
        exit 0
      fi
      echo "fm-queue.sh --mark-done: fm-tasks fail $ID failed" >&2
      exit 1
    fi
    # `done` is a bash reserved word and shellcheck SC1010 fires wherever
    # it appears followed by `;` or a newline (looks like a `for` loop
    # terminator). The disable is scoped to the next line so the linter
    # still flags anything else in this block.
    # shellcheck disable=SC1010
    if fm-tasks done "$ID" 2>/dev/null; then
      printf 'fm-queue.sh --mark-done: done %s\n' "$ID"
      exit 0
    fi
    # Some done paths need a PR URL (PR-based ship) or --local (local-only).
    # We can't tell from here which it is, but the binary will accept `done`
    # without flags for non-PR tasks. If it fails, surface the error to stderr.
    echo "fm-queue.sh --mark-done: fm-tasks done $ID failed (may need --pr or --local)" >&2
    exit 1
    ;;

  *)
    sed -n '2,30p' "$0"
    exit 2
    ;;
esac
