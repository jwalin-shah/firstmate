#!/usr/bin/env bash
# Development-contract proof ledger (ADR-004 / fundamentals §2).
#
# Owns ordered pre-implement and post-implement steps, durable evidence, and the
# implement_ready bit that write hooks consult before admitting code edits.
# Does not run githits or axioms itself; it records their evidence and refuses
# out-of-order completion. See docs/proof-enforcement.md for the full contract.
#
# Usage:
#   fm-proof.sh init <id> [--summary TEXT] [--enforce|--no-enforce] [--force]
#   fm-proof.sh record <step> --evidence TEXT [--path FILE] [--query TEXT]
#                        [--gap REASON] [--command TEXT] [--exit-code N]
#   fm-proof.sh status [--json]
#   fm-proof.sh check-write [--json]
#   fm-proof.sh gate [--command TEXT] [--exit-code N] [--evidence TEXT]
#   fm-proof.sh invariant --evidence TEXT [--path FILE] [--command TEXT]
#   fm-proof.sh ingest --evidence TEXT [--path FILE]
#   fm-proof.sh loop --counterexample TEXT
#   fm-proof.sh path
#   fm-proof.sh clear [--force]
#
# Exit codes:
#   0 success / ALLOW (check-write)
#   1 usage or validation error
#   2 DENY (check-write) or refused transition
set -euo pipefail

PRE_STEPS=(githits axioms tensor_equation pseudocode proof)
POST_STEPS=(p0_gate executable_invariant axiom_ingest)
ALL_STEPS=("${PRE_STEPS[@]}" "${POST_STEPS[@]}")

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

refuse() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

json_escape() {
  # Minimal JSON string escape for values we control.
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'
}

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

resolve_repo_root() {
  local start=${1:-$PWD} root
  if command -v git >/dev/null 2>&1; then
    root=$(git -C "$start" rev-parse --show-toplevel 2>/dev/null) || root=""
    if [ -n "$root" ]; then
      printf '%s\n' "$root"
      return 0
    fi
  fi
  printf '%s\n' "$start"
}

proof_dir_for() {
  printf '%s/.proof\n' "$1"
}

ledger_path_for() {
  printf '%s/ledger.json\n' "$(proof_dir_for "$1")"
}

enforce_marker_for() {
  printf '%s/enforce\n' "$(proof_dir_for "$1")"
}

load_ledger() {
  local path=$1
  [ -f "$path" ] || return 1
  cat "$path"
}

write_ledger_atomic() {
  local path=$1 content=$2 dir tmp
  dir=$(dirname -- "$path")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.ledger.XXXXXX")
  printf '%s\n' "$content" >"$tmp"
  mv -f "$tmp" "$path"
}

enforcement_active() {
  local root=$1 ledger
  case "${FM_PROOF_ENFORCE:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
  esac
  if [ -f "$(enforce_marker_for "$root")" ]; then
    return 0
  fi
  ledger=$(ledger_path_for "$root")
  if [ -f "$ledger" ]; then
    python3 - "$ledger" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(1)
sys.exit(0 if data.get("enforce") is True else 1)
PY
    return $?
  fi
  return 1
}

step_index() {
  local want=$1 i
  for i in "${!ALL_STEPS[@]}"; do
    if [ "${ALL_STEPS[$i]}" = "$want" ]; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  return 1
}

is_pre_step() {
  local s
  for s in "${PRE_STEPS[@]}"; do
    [ "$s" = "$1" ] && return 0
  done
  return 1
}

validate_step_name() {
  step_index "$1" >/dev/null || die "unknown step: $1 (expected one of: ${ALL_STEPS[*]})"
}

cmd_init() {
  require_cmd python3
  local id="" summary="" enforce=1 force=0 root ledger
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --summary)
        [ "$#" -gt 1 ] || die "--summary requires a value"
        summary=$2
        shift 2
        ;;
      --summary=*)
        summary=${1#--summary=}
        shift
        ;;
      --enforce)
        enforce=1
        shift
        ;;
      --no-enforce)
        enforce=0
        shift
        ;;
      --force)
        force=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --*)
        die "unknown init flag: $1"
        ;;
      *)
        if [ -z "$id" ]; then
          id=$1
          shift
        else
          die "unexpected argument: $1"
        fi
        ;;
    esac
  done
  [ -n "$id" ] || die "init requires <id>"
  case "$id" in
    *[!A-Za-z0-9._-]*) die "id must be alphanumeric plus ._- : $id" ;;
  esac

  root=$(resolve_repo_root "$PWD")
  ledger=$(ledger_path_for "$root")
  if [ -f "$ledger" ] && [ "$force" -ne 1 ]; then
    if python3 - "$ledger" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
steps = data.get("steps") or {}
pre = ["githits", "axioms", "tensor_equation", "pseudocode", "proof"]
incomplete = [s for s in pre if not (steps.get(s) or {}).get("complete")]
sys.exit(0 if incomplete else 1)
PY
    then
      refuse "open ledger already exists at $ledger (pass --force to replace)"
    fi
  fi

  local created content
  created=$(now_iso)
  content=$(ID="$id" SUMMARY="$summary" ENFORCE="$enforce" CREATED="$created" PRE="${PRE_STEPS[*]}" POST="${POST_STEPS[*]}" python3 <<'PY'
import json, os
pre = os.environ["PRE"].split()
post = os.environ["POST"].split()
steps = {name: {"complete": False, "evidence": None} for name in pre + post}
doc = {
    "version": 1,
    "id": os.environ["ID"],
    "summary": os.environ.get("SUMMARY") or "",
    "enforce": os.environ["ENFORCE"] == "1",
    "created_at": os.environ["CREATED"],
    "updated_at": os.environ["CREATED"],
    "pre_steps": pre,
    "post_steps": post,
    "steps": steps,
    "counterexamples": [],
    "implement_ready": False,
}
print(json.dumps(doc, indent=2, sort_keys=False))
PY
)
  write_ledger_atomic "$ledger" "$content"
  if [ "$enforce" -eq 1 ]; then
    mkdir -p "$(proof_dir_for "$root")"
    : >"$(enforce_marker_for "$root")"
  fi
  printf 'initialized proof ledger %s at %s (enforce=%s)\n' "$id" "$ledger" "$enforce"
}

ledger_python() {
  # Shared python helper: argv[1]=ledger path, remaining args command-specific.
  require_cmd python3
  local root ledger
  root=$(resolve_repo_root "$PWD")
  ledger=$(ledger_path_for "$root")
  [ -f "$ledger" ] || die "no proof ledger at $ledger (run: fm-proof.sh init <id>)"
  PROOF_LEDGER="$ledger" PROOF_ROOT="$root" python3 - "$@" <<'PY'
import json, os, sys, tempfile
from pathlib import Path

ledger_path = Path(os.environ["PROOF_LEDGER"])
root = Path(os.environ["PROOF_ROOT"])

def load():
    return json.loads(ledger_path.read_text(encoding="utf-8"))

def save(doc):
    doc["updated_at"] = os.environ.get("PROOF_NOW") or __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    pre = doc.get("pre_steps") or []
    steps = doc.get("steps") or {}
    doc["implement_ready"] = all((steps.get(s) or {}).get("complete") for s in pre)
    text = json.dumps(doc, indent=2, sort_keys=False) + "\n"
    fd, tmp = tempfile.mkstemp(prefix=".ledger.", dir=str(ledger_path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, ledger_path)
    finally:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass

def ordered():
    doc = load()
    return list(doc.get("pre_steps") or []) + list(doc.get("post_steps") or [])

def ensure_predecessors(step):
    order = ordered()
    if step not in order:
        print(f"error: unknown step: {step}", file=sys.stderr)
        sys.exit(1)
    doc = load()
    steps = doc.get("steps") or {}
    idx = order.index(step)
    missing = [s for s in order[:idx] if not (steps.get(s) or {}).get("complete")]
    if missing:
        print("error: predecessors incomplete: " + ", ".join(missing), file=sys.stderr)
        sys.exit(2)
    return doc, steps

def mark(step, evidence):
    doc, steps = ensure_predecessors(step)
    entry = dict(steps.get(step) or {})
    entry["complete"] = True
    entry["evidence"] = evidence
    entry["completed_at"] = os.environ.get("PROOF_NOW") or __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    steps[step] = entry
    doc["steps"] = steps
    save(doc)
    print(f"recorded {step}")

cmd = sys.argv[1]

if cmd == "record":
    # record step --evidence ... flags already parsed into env
    step = os.environ["PROOF_STEP"]
    evidence = json.loads(os.environ["PROOF_EVIDENCE_JSON"])
    # step-specific validation
    if step == "githits":
        if not evidence.get("query") and not evidence.get("text"):
            print("error: githits requires --query or --evidence", file=sys.stderr)
            sys.exit(1)
    elif step == "axioms":
        if not evidence.get("text") and not evidence.get("ids"):
            print("error: axioms requires --evidence or --ids", file=sys.stderr)
            sys.exit(1)
    elif step == "tensor_equation":
        text = (evidence.get("text") or "")
        if "∀" not in text and "forall" not in text.lower() and "\\forall" not in text:
            print("error: tensor_equation evidence must contain a ∀/forall formula", file=sys.stderr)
            sys.exit(1)
    elif step == "pseudocode":
        if not evidence.get("text") and not evidence.get("path"):
            print("error: pseudocode requires --evidence or --path", file=sys.stderr)
            sys.exit(1)
    elif step == "proof":
        if evidence.get("gap"):
            if not evidence.get("text") and not evidence.get("gap_reason"):
                print("error: proof gap requires --gap reason", file=sys.stderr)
                sys.exit(1)
        elif not evidence.get("path") and not evidence.get("text"):
            print("error: proof requires --path/--evidence or --gap", file=sys.stderr)
            sys.exit(1)
    elif step in ("p0_gate", "executable_invariant", "axiom_ingest"):
        if not evidence.get("text") and not evidence.get("command") and not evidence.get("path"):
            print(f"error: {step} requires --evidence, --command, or --path", file=sys.stderr)
            sys.exit(1)
    mark(step, evidence)

elif cmd == "status":
    doc = load()
    as_json = os.environ.get("PROOF_JSON") == "1"
    if as_json:
        print(json.dumps(doc, indent=2))
        sys.exit(0)
    steps = doc.get("steps") or {}
    print(f"ledger: {ledger_path}")
    print(f"id: {doc.get('id')}")
    print(f"summary: {doc.get('summary') or '-'}")
    print(f"enforce: {doc.get('enforce')}")
    print(f"implement_ready: {doc.get('implement_ready')}")
    print("steps:")
    for name in ordered():
        st = steps.get(name) or {}
        flag = "done" if st.get("complete") else "todo"
        ev = st.get("evidence") or {}
        summary = ev.get("text") or ev.get("query") or ev.get("path") or ev.get("gap_reason") or ""
        if len(summary) > 80:
            summary = summary[:77] + "..."
        print(f"  [{flag}] {name}" + (f" — {summary}" if summary else ""))
    cxs = doc.get("counterexamples") or []
    if cxs:
        print("counterexamples:")
        for cx in cxs[-5:]:
            print(f"  - {cx.get('at')}: {cx.get('text')}")

elif cmd == "check-write":
    # enforcement decision uses env + marker + ledger.enforce; shell sets PROOF_ACTIVE
    active = os.environ.get("PROOF_ACTIVE") == "1"
    as_json = os.environ.get("PROOF_JSON") == "1"
    if not active:
        if as_json:
            print(json.dumps({"decision": "allow", "reason": "enforcement inactive"}))
        sys.exit(0)
    if not ledger_path.is_file():
        msg = "no proof ledger; run fm-proof.sh init <id> before writing code"
        if as_json:
            print(json.dumps({"decision": "deny", "code": "no-ledger", "reason": msg}))
        else:
            print(f"[no-ledger] {msg}", file=sys.stderr)
        sys.exit(2)
    doc = load()
    steps = doc.get("steps") or {}
    pre = doc.get("pre_steps") or []
    missing = [s for s in pre if not (steps.get(s) or {}).get("complete")]
    if missing:
        msg = "pre-implement incomplete: " + ", ".join(missing)
        if as_json:
            print(json.dumps({"decision": "deny", "code": "pre-implement-incomplete", "missing": missing, "reason": msg}))
        else:
            print(f"[pre-implement-incomplete] {msg}", file=sys.stderr)
            print("record evidence with: fm-proof.sh record <step> --evidence '...'", file=sys.stderr)
        sys.exit(2)
    if as_json:
        print(json.dumps({"decision": "allow", "reason": "implement_ready"}))
    sys.exit(0)

elif cmd == "loop":
    text = os.environ.get("PROOF_COUNTEREXAMPLE") or ""
    if not text:
        print("error: loop requires --counterexample TEXT", file=sys.stderr)
        sys.exit(1)
    doc = load()
    steps = doc.get("steps") or {}
    # Clear from tensor_equation through end; keep githits+axioms.
    clear_from = ["tensor_equation", "pseudocode", "proof", "p0_gate", "executable_invariant", "axiom_ingest"]
    for name in clear_from:
        if name in steps:
            steps[name] = {"complete": False, "evidence": None}
    doc["steps"] = steps
    cxs = list(doc.get("counterexamples") or [])
    cxs.append({
        "at": os.environ.get("PROOF_NOW") or __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "text": text,
    })
    doc["counterexamples"] = cxs
    save(doc)
    print("looped to tensor_equation with counterexample recorded")

elif cmd == "clear":
    if os.environ.get("PROOF_FORCE") != "1":
        print("error: clear requires --force", file=sys.stderr)
        sys.exit(1)
    ledger_path.unlink(missing_ok=True)
    marker = root / ".proof" / "enforce"
    if marker.is_file():
        marker.unlink()
    print(f"cleared proof ledger at {ledger_path}")

else:
    print(f"error: internal unknown cmd {cmd}", file=sys.stderr)
    sys.exit(1)
PY
}

cmd_record() {
  local step="" evidence="" path="" query="" gap="" command="" exit_code="" ids=""
  [ "$#" -gt 0 ] || die "record requires <step>"
  step=$1
  shift
  validate_step_name "$step"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --evidence)
        [ "$#" -gt 1 ] || die "--evidence requires a value"
        evidence=$2
        shift 2
        ;;
      --evidence=*)
        evidence=${1#--evidence=}
        shift
        ;;
      --path)
        [ "$#" -gt 1 ] || die "--path requires a value"
        path=$2
        shift 2
        ;;
      --path=*)
        path=${1#--path=}
        shift
        ;;
      --query)
        [ "$#" -gt 1 ] || die "--query requires a value"
        query=$2
        shift 2
        ;;
      --query=*)
        query=${1#--query=}
        shift
        ;;
      --gap)
        [ "$#" -gt 1 ] || die "--gap requires a value"
        gap=$2
        shift 2
        ;;
      --gap=*)
        gap=${1#--gap=}
        shift
        ;;
      --command)
        [ "$#" -gt 1 ] || die "--command requires a value"
        command=$2
        shift 2
        ;;
      --command=*)
        command=${1#--command=}
        shift
        ;;
      --exit-code)
        [ "$#" -gt 1 ] || die "--exit-code requires a value"
        exit_code=$2
        shift 2
        ;;
      --exit-code=*)
        exit_code=${1#--exit-code=}
        shift
        ;;
      --ids)
        [ "$#" -gt 1 ] || die "--ids requires a value"
        ids=$2
        shift 2
        ;;
      --ids=*)
        ids=${1#--ids=}
        shift
        ;;
      *)
        die "unknown record flag: $1"
        ;;
    esac
  done

  local evidence_json
  evidence_json=$(
    EVIDENCE="$evidence" PATH_E="$path" QUERY="$query" GAP="$gap" COMMAND_E="$command" EXIT_CODE="$exit_code" IDS="$ids" python3 <<'PY'
import json, os
ev = {}
if os.environ.get("EVIDENCE"):
    ev["text"] = os.environ["EVIDENCE"]
if os.environ.get("PATH_E"):
    ev["path"] = os.environ["PATH_E"]
if os.environ.get("QUERY"):
    ev["query"] = os.environ["QUERY"]
if os.environ.get("GAP"):
    ev["gap"] = True
    ev["gap_reason"] = os.environ["GAP"]
if os.environ.get("COMMAND_E"):
    ev["command"] = os.environ["COMMAND_E"]
if os.environ.get("EXIT_CODE") != "":
    try:
        ev["exit_code"] = int(os.environ["EXIT_CODE"])
    except ValueError:
        ev["exit_code"] = os.environ["EXIT_CODE"]
if os.environ.get("IDS"):
    ev["ids"] = [x.strip() for x in os.environ["IDS"].split(",") if x.strip()]
print(json.dumps(ev))
PY
  )
  PROOF_STEP="$step" PROOF_EVIDENCE_JSON="$evidence_json" PROOF_NOW="$(now_iso)" \
    ledger_python record
}

cmd_status() {
  local json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      *) die "unknown status flag: $1" ;;
    esac
  done
  PROOF_JSON="$json" PROOF_NOW="$(now_iso)" ledger_python status
}

cmd_check_write() {
  local json=0 root active=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      *) die "unknown check-write flag: $1" ;;
    esac
  done
  root=$(resolve_repo_root "$PWD")
  if enforcement_active "$root"; then
    active=1
  fi
  # check-write must not die on missing ledger when inactive
  if [ "$active" -eq 0 ]; then
    if [ "$json" -eq 1 ]; then
      printf '%s\n' '{"decision":"allow","reason":"enforcement inactive"}'
    fi
    exit 0
  fi
  if [ ! -f "$(ledger_path_for "$root")" ]; then
    if [ "$json" -eq 1 ]; then
      printf '%s\n' '{"decision":"deny","code":"no-ledger","reason":"no proof ledger; run fm-proof.sh init <id> before writing code"}'
    else
      printf '%s\n' "[no-ledger] no proof ledger; run fm-proof.sh init <id> before writing code" >&2
    fi
    exit 2
  fi
  PROOF_ACTIVE=1 PROOF_JSON="$json" PROOF_NOW="$(now_iso)" ledger_python check-write
}

cmd_gate() {
  local command="" exit_code="" evidence=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --command)
        [ "$#" -gt 1 ] || die "--command requires a value"
        command=$2
        shift 2
        ;;
      --command=*)
        command=${1#--command=}
        shift
        ;;
      --exit-code)
        [ "$#" -gt 1 ] || die "--exit-code requires a value"
        exit_code=$2
        shift 2
        ;;
      --exit-code=*)
        exit_code=${1#--exit-code=}
        shift
        ;;
      --evidence)
        [ "$#" -gt 1 ] || die "--evidence requires a value"
        evidence=$2
        shift 2
        ;;
      --evidence=*)
        evidence=${1#--evidence=}
        shift
        ;;
      *)
        die "unknown gate flag: $1"
        ;;
    esac
  done
  if [ -n "$command" ] && [ -z "$exit_code" ]; then
    set +e
    bash -lc "$command"
    exit_code=$?
    set -e
  fi
  if [ -n "$exit_code" ] && [ "$exit_code" != "0" ]; then
    refuse "p0 gate failed with exit code $exit_code"
  fi
  [ -n "$evidence" ] || evidence="p0 gate passed${command:+: $command}"
  cmd_record p0_gate --evidence "$evidence" ${command:+--command "$command"} ${exit_code:+--exit-code "$exit_code"}
}

cmd_invariant() {
  cmd_record executable_invariant "$@"
}

cmd_ingest() {
  cmd_record axiom_ingest "$@"
}

cmd_loop() {
  local cx=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --counterexample)
        [ "$#" -gt 1 ] || die "--counterexample requires a value"
        cx=$2
        shift 2
        ;;
      --counterexample=*)
        cx=${1#--counterexample=}
        shift
        ;;
      *)
        die "unknown loop flag: $1"
        ;;
    esac
  done
  [ -n "$cx" ] || die "loop requires --counterexample TEXT"
  PROOF_COUNTEREXAMPLE="$cx" PROOF_NOW="$(now_iso)" ledger_python loop
}

cmd_path() {
  local root
  root=$(resolve_repo_root "$PWD")
  printf '%s\n' "$(ledger_path_for "$root")"
}

cmd_clear() {
  local force=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      *) die "unknown clear flag: $1" ;;
    esac
  done
  PROOF_FORCE="$force" PROOF_NOW="$(now_iso)" ledger_python clear
}

main() {
  local cmd=${1:-}
  [ -n "$cmd" ] || { usage >&2; exit 1; }
  shift || true
  case "$cmd" in
    -h|--help) usage; exit 0 ;;
    init) cmd_init "$@" ;;
    record) cmd_record "$@" ;;
    status) cmd_status "$@" ;;
    check-write) cmd_check_write "$@" ;;
    gate) cmd_gate "$@" ;;
    invariant) cmd_invariant "$@" ;;
    ingest) cmd_ingest "$@" ;;
    loop) cmd_loop "$@" ;;
    path) cmd_path "$@" ;;
    clear) cmd_clear "$@" ;;
    *)
      die "unknown command: $cmd"
      ;;
  esac
}

main "$@"
