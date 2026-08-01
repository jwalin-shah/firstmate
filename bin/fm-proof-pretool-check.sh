#!/usr/bin/env bash
# PreToolUse transport for development-contract write gating.
#
# Blocks write-shaped agent tools (and write-shaped bash) when proof enforcement
# is active and the pre-implement ledger is incomplete.
# bin/fm-proof.sh owns the ledger decision (check-write).
# This wrapper only classifies write shape, resolves cwd/repo, and renders the
# established harness-specific deny responses.
# See docs/proof-enforcement.md for the complete contract.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-proof-pretool-check.sh
#   bin/fm-proof-pretool-check.sh --command '<cmd>'
#   bin/fm-proof-pretool-check.sh --tool '<name>' [--path '<path>']
#   bin/fm-proof-pretool-check.sh --claude   # with either form
#
# Exit/output contract (same family as bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY  - exit 2, Claude-shaped deny on stderr, Grok-shaped deny on stdout
#           unless --claude was supplied.
#   FAIL OPEN - malformed/empty stdin, missing jq for stdin transport, or an
#               unavailable proof CLI.
set -u

CMD=""
CMD_SET=0
TOOL=""
TOOL_SET=0
PATH_ARG=""
CLAUDE_MODE=0
CWD=""

usage() {
  cat <<'EOF'
Usage: fm-proof-pretool-check.sh [--command <cmd>] [--tool <name>] [--path <path>] [--cwd <dir>] [--claude]

With no --command/--tool, reads a PreToolUse-style JSON payload on stdin.
Write-shaped tools and write-shaped bash are checked against fm-proof.sh check-write.
Exits 0 to allow and 2 to deny.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --tool)
      [ "$#" -gt 1 ] || { echo "error: --tool requires a value" >&2; exit 2; }
      TOOL=$2
      TOOL_SET=1
      shift 2
      ;;
    --tool=*)
      TOOL=${1#--tool=}
      TOOL_SET=1
      shift
      ;;
    --path)
      [ "$#" -gt 1 ] || { echo "error: --path requires a value" >&2; exit 2; }
      PATH_ARG=$2
      shift 2
      ;;
    --path=*)
      PATH_ARG=${1#--path=}
      shift
      ;;
    --cwd)
      [ "$#" -gt 1 ] || { echo "error: --cwd requires a value" >&2; exit 2; }
      CWD=$2
      shift 2
      ;;
    --cwd=*)
      CWD=${1#--cwd=}
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
PROOF_CLI="$FM_ROOT/bin/fm-proof.sh"
[ -x "$PROOF_CLI" ] || exit 0

# Stdin transport when neither --command nor --tool was supplied.
if [ "$CMD_SET" -eq 0 ] && [ "$TOOL_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // .toolName // empty)' 2>/dev/null) || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || true
  PATH_ARG=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.path // .tool_input.path // .toolInput.file_path // .tool_input.file_path // empty)' 2>/dev/null) || true
  CWD=$(printf '%s' "$PAYLOAD" | jq -r '(.cwd // .toolInput.cwd // .tool_input.cwd // empty)' 2>/dev/null) || true
  TOOL_SET=1
fi

tool_lc=$(printf '%s' "${TOOL:-}" | tr '[:upper:]' '[:lower:]')

is_write_tool() {
  case "$1" in
    write|edit|multiedit|create|apply_patch|applypatch|strreplace|search_replace|notebookedit|notebook_edit)
      return 0
      ;;
  esac
  # Substring shapes used by some adapters.
  case "$1" in
    *write*|*edit*|*patch*)
      return 0
      ;;
  esac
  return 1
}

is_write_bash() {
  local c=$1
  # Cheap agent-mistake classifier: common write redirections and editors.
  # Deliberate obfuscation is out of scope (same threat model as cd-guard).
  # Keep patterns free of unescaped parentheses; bash case treats ( specially.
  # A lone '>' also matches '>>', so only one redirection pattern is needed.
  case "$c" in
    *'>'*) return 0 ;;
  esac
  case "$c" in
    *tee\ *) return 0 ;;
  esac
  case "$c" in
    *install\ *|*cp\ *|*mv\ *|*rm\ *|*truncate\ *|*dd\ *|*patch\ *) return 0 ;;
  esac
  case "$c" in
    *sed\ -i*|*perl\ -i*|*ruby\ -i*) return 0 ;;
  esac
  case "$c" in
    *'<<'*) return 0 ;;
  esac
  return 1
}

# Exempt proof-ledger paths and the proof CLI itself so the agent can always
# advance the gate while enforcement is on.
path_is_exempt() {
  local p=$1
  case "$p" in
    */.proof/*|.proof/*|*/.proof|*/bin/fm-proof.sh|bin/fm-proof.sh|*/bin/fm-proof-pretool-check.sh|bin/fm-proof-pretool-check.sh)
      return 0
      ;;
    */docs/proof-enforcement.md|docs/proof-enforcement.md)
      return 0
      ;;
  esac
  return 1
}

bash_is_proof_cli() {
  case "$1" in
    *fm-proof.sh*|*fm-proof-pretool-check.sh*)
      return 0
      ;;
  esac
  return 1
}

need_check=0
if [ -n "$tool_lc" ] && is_write_tool "$tool_lc"; then
  if [ -n "$PATH_ARG" ] && path_is_exempt "$PATH_ARG"; then
    exit 0
  fi
  need_check=1
elif [ -n "$CMD" ]; then
  if bash_is_proof_cli "$CMD"; then
    exit 0
  fi
  if is_write_bash "$CMD"; then
    need_check=1
  fi
fi

[ "$need_check" -eq 1 ] || exit 0

# Resolve working directory for the ledger lookup.
CHECK_DIR=$PWD
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  CHECK_DIR=$CWD
elif [ -n "$PATH_ARG" ]; then
  if [ -d "$PATH_ARG" ]; then
    CHECK_DIR=$PATH_ARG
  else
    parent=$(dirname -- "$PATH_ARG" 2>/dev/null || true)
    if [ -n "$parent" ] && [ -d "$parent" ]; then
      CHECK_DIR=$parent
    fi
  fi
fi

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

# Run check-write in the target directory.
REASON=""
CODE=""
set +e
OUT=$(CDPATH='' cd -- "$CHECK_DIR" 2>/dev/null && "$PROOF_CLI" check-write --json 2>/dev/null)
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
  exit 0
fi

# Fail open if the CLI could not produce a structured deny.
if [ -z "$OUT" ]; then
  exit 0
fi

if command -v jq >/dev/null 2>&1; then
  CODE=$(printf '%s' "$OUT" | jq -r '.code // "pre-implement-incomplete"' 2>/dev/null) || CODE="pre-implement-incomplete"
  REASON=$(printf '%s' "$OUT" | jq -r '.reason // empty' 2>/dev/null) || REASON=""
else
  CODE="pre-implement-incomplete"
  REASON=$OUT
fi
[ -n "$REASON" ] || REASON="proof enforcement denied write"

DETAIL="[$CODE] $REASON — complete pre-implement steps with bin/fm-proof.sh"
ESCAPED=$(json_escape "$DETAIL")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
