#!/usr/bin/env bash
# fm-init.sh — shared bootstrap for firstmate shell scripts.
#
# Source this after resolving FM_ROOT. Provides:
#   STATE  (with FM_STATE_OVERRIDE support)
#   die()  — echo args to stderr, exit 1
#   usage() — print usage line, exit 2
#   Imports fm-mm-lib.sh and fm-wake-lib.sh
#
# If FM_ROOT is not set when sourced, this script auto-discovers it from
# BASH_SOURCE (the path to this file). Callers that need FM_ROOT_OVERRIDE
# should resolve FM_ROOT themselves before sourcing this script.
#
# Must be sourced, not executed.

[ -n "${FM_ROOT:-}" ] || FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd 2>/dev/null || true)"

if [ -z "${FM_ROOT:-}" ] || [ ! -d "$FM_ROOT/bin" ]; then
  echo "fm-init.sh: FATAL — cannot resolve FM_ROOT" >&2
  return 1
fi

STATE="${FM_STATE_OVERRIDE:-$FM_ROOT/state}"
mkdir -p "$STATE" 2>/dev/null || true

die() { echo "$*" >&2; exit 1; }
usage() { echo "usage: $(basename "$0") $*" >&2; exit 2; }

# shellcheck source=bin/fm-mm-lib.sh
. "$FM_ROOT/bin/fm-mm-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_ROOT/bin/fm-wake-lib.sh"
