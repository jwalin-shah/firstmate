#!/usr/bin/env bash
# Firstmate queue: a small JSON-backed task registry at state/queue.json that
# replaces data/backlog.md as the durable source of truth for FleetViewer.
# Firstmate is the only writer; FleetViewer and the watcher are read-only.
# All mutations go through this script so the on-disk file stays valid JSON
# even under concurrent writes (the rename is atomic on POSIX, and the inner
# jq invocation reads the whole file + writes a fresh object per call, so
# racing writers each produce a complete document; the later one wins, which
# is the same guarantee every other state file in firstmate already has).
#
# Schema (state/queue.json):
#   { "tasks": { "<id>": { id, title, repo, kind, mode, status, added, updated,
#                          blocked_by?, pr_url?, merged_at?, report_path? } } }
# Status values: queued, in-flight, done, failed. Blockers live in blocked_by[]
# (an array of ids from the same registry). The fm-tasks SQLite DB at
# data/tasks.db is the parallel authoritative store for runtime metadata
# (started_at, done_at, fail_reason, report_path, meta blob); this script
# treats the SQLite as read-only for derivation purposes and writes back
# only via fm-tasks when --mark-done is called.
#
# Usage:
#   fm-queue.sh add <id> <repo> <title> [--kind scout] [--mode direct-PR] [--blocked-by id,id]
#   fm-queue.sh set-status <id> <queued|in-flight|done|failed>
#   fm-queue.sh set-pr <id> <url>
#   fm-queue.sh set-merged <id> <ISO8601>
#   fm-queue.sh set-report <id> <path>          # scout/local-only done indicator
#   fm-queue.sh get <id>                        # prints JSON for one task, or {} if unknown
#   fm-queue.sh list                            # prints the full queue.json
#   fm-queue.sh to-markdown | --once            # derive data/backlog.md from SQLite+queue.json
#   fm-queue.sh --mark-done <id>                # self-heal: mark fm-tasks done when meta says
#                                              # the pane is gone and last status is done:/failed:
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$FM_ROOT/bin/fm-init.sh"
DATA="${FM_DATA_OVERRIDE:-$FM_ROOT/data}"
QUEUE="$STATE/queue.json"
BACKLOG="$DATA/backlog.md"
mkdir -p "$DATA"

# Where fm-tasks stores its DB. The binary is the same canonical queue
# (data/tasks.db per the orbit/cmd/fm-tasks schema); we read from it but never
# write directly — writes go through `fm-tasks done/fail` to keep its WAL
# invariants intact.
TASKS_DB="${FM_TASKS_DB_OVERRIDE:-$DATA/tasks.db}"

now_iso() {
  # ISO 8601 in UTC with seconds; matches the format gh emits for mergedAt.
  date -u +%Y-%m-%dT%H:%M:%SZ
}

ensure_queue() {
  if [ ! -f "$QUEUE" ]; then
    printf '{"tasks":{}}\n' > "$QUEUE"
  fi
}

cmd=${1:-}
shift || true

case "$cmd" in
  add)
    ID=${1:?fm-queue.sh add: <id> <repo> <title> required}
    REPO=${2:?fm-queue.sh add: <id> <repo> <title> required}
    TITLE=${3:?fm-queue.sh add: <id> <repo> <title> required}
    shift 3
    KIND=ship
    MODE=no-mistakes
    BLOCKED_BY=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --kind) KIND=${2:?--kind requires a value}; shift 2 ;;
        --mode) MODE=${2:?--mode requires a value}; shift 2 ;;
        --blocked-by) BLOCKED_BY=${2:?--blocked-by requires a value}; shift 2 ;;
        *) echo "fm-queue.sh add: unknown arg '$1'" >&2; exit 2 ;;
      esac
    done
    case "$KIND" in ship|scout) ;; *) echo "fm-queue.sh add: --kind must be ship or scout, got '$KIND'" >&2; exit 2 ;; esac
    case "$MODE" in no-mistakes|direct-PR|local-only) ;; *) echo "fm-queue.sh add: --mode must be no-mistakes, direct-PR, or local-only, got '$MODE'" >&2; exit 2 ;; esac
    # Build blocked_by JSON array from a comma-separated list. Empty -> omit key.
    BLOCKED_LIT='[]'
    if [ -n "$BLOCKED_BY" ]; then
      BLOCKED_LIT=$(printf '%s' "$BLOCKED_BY" | jq -R 'split(",") | map(select(length>0))')
    fi
    # shellcheck disable=SC2016  # $id/$title/$repo/$kind/$mode/$blocked/$now are jq variables, not shell.
    FILTER=$(cat <<JQF
.tasks[\$id] = (
  { id: \$id, title: \$title, repo: \$repo, kind: \$kind, mode: \$mode
  , status: "queued", added: \$now, updated: \$now }
  + (if (\$blocked | length) > 0 then { blocked_by: \$blocked } else {} end)
)
JQF
)
    ensure_queue
    jq --arg id "$ID" --arg now "$(now_iso)" \
       --arg title "$TITLE" --arg repo "$REPO" --arg kind "$KIND" --arg mode "$MODE" \
       --argjson blocked "$BLOCKED_LIT" \
       "$FILTER" "$QUEUE" > "$QUEUE.tmp.$$"
    mv "$QUEUE.tmp.$$" "$QUEUE"
    ;;

  set-status)
    ID=${1:?fm-queue.sh set-status: <id> <status> required}
    STATUS=${2:?fm-queue.sh set-status: <id> <status> required}
    case "$STATUS" in queued|in-flight|done|failed) ;; *) echo "fm-queue.sh set-status: status must be queued|in-flight|done|failed, got '$STATUS'" >&2; exit 2 ;; esac
    # shellcheck disable=SC2016  # $id/$status/$now are jq variables, not shell.
    FILTER='if .tasks[$id] == null then . else .tasks[$id].status = $status | .tasks[$id].updated = $now end'
    ensure_queue
    jq --arg id "$ID" --arg now "$(now_iso)" --arg status "$STATUS" "$FILTER" "$QUEUE" > "$QUEUE.tmp.$$"
    mv "$QUEUE.tmp.$$" "$QUEUE"
    ;;

  set-pr)
    ID=${1:?fm-queue.sh set-pr: <id> <url> required}
    URL=${2:?fm-queue.sh set-pr: <id> <url> required}
    # shellcheck disable=SC2016  # $id/$url/$now are jq variables, not shell.
    FILTER='if .tasks[$id] == null then . else .tasks[$id].pr_url = $url | .tasks[$id].updated = $now end'
    ensure_queue
    jq --arg id "$ID" --arg now "$(now_iso)" --arg url "$URL" "$FILTER" "$QUEUE" > "$QUEUE.tmp.$$"
    mv "$QUEUE.tmp.$$" "$QUEUE"
    ;;

  set-merged)
    ID=${1:?fm-queue.sh set-merged: <id> <ISO8601> required}
    MERGED_AT=${2:?fm-queue.sh set-merged: <id> <ISO8601> required}
    # shellcheck disable=SC2016  # $id/$merged/$now are jq variables, not shell.
    FILTER='if .tasks[$id] == null then . else .tasks[$id].merged_at = $merged | .tasks[$id].status = "done" | .tasks[$id].updated = $now end'
    ensure_queue
    jq --arg id "$ID" --arg now "$(now_iso)" --arg merged "$MERGED_AT" "$FILTER" "$QUEUE" > "$QUEUE.tmp.$$"
    mv "$QUEUE.tmp.$$" "$QUEUE"
    ;;

  set-report)
    ID=${1:?fm-queue.sh set-report: <id> <path> required}
    PATH_=${2:?fm-queue.sh set-report: <id> <path> required}
    # shellcheck disable=SC2016  # $id/$path/$now are jq variables, not shell.
    FILTER='if .tasks[$id] == null then . else .tasks[$id].report_path = $path | .tasks[$id].status = "done" | .tasks[$id].updated = $now end'
    ensure_queue
    jq --arg id "$ID" --arg now "$(now_iso)" --arg path "$PATH_" "$FILTER" "$QUEUE" > "$QUEUE.tmp.$$"
    mv "$QUEUE.tmp.$$" "$QUEUE"
    ;;

  get)
    ID=${1:?fm-queue.sh get: <id> required}
    ensure_queue
    jq --arg id "$ID" '.tasks[$id] // {}' "$QUEUE"
    ;;

  list)
    ensure_queue
    cat "$QUEUE"
    ;;

  to-markdown|--once)
    # Derive data/backlog.md from the union of state/queue.json and
    # data/tasks.db (SQLite). The DB wins for any field both stores, because
    # the binary is the runtime source of truth; queue.json is the planning
    # layer. Output goes through a temp file + atomic rename so a reader of
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
    ensure_queue
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
out.append("Auto-derived from data/tasks.db (SQLite) + state/queue.json by bin/fm-queue.sh.")
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
