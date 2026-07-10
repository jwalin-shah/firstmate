#!/usr/bin/env bash
# fm-bridge-verify.sh - machine gate run before human review of a crewmate's
# done: report. Runs `bridge verify` against the task's project clone (not the
# worktree) as a second pair of eyes ahead of bin/fm-review-diff.sh. A missing
# `bridge` binary is a skip, not a block, so firstmate always proceeds to
# fm-review-diff.sh whether or not bridge is installed.
# Usage: fm-bridge-verify.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-bridge-verify.sh <task-id>" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ID=${1:-}
[ -n "$ID" ] || { usage; exit 1; }
[ $# -le 1 ] || { usage; exit 1; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | tail -1 | cut -d= -f2-)
[ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }

if ! command -v bridge >/dev/null 2>&1; then
  echo "bridge not installed - skipping verify gate"
  exit 0
fi

if bridge verify "$PROJ" >/dev/null 2>&1; then
  echo "bridge verify: gates green"
  exit 0
fi

echo "BLOCKED: bridge verify failed - gates are red"
exit 1
