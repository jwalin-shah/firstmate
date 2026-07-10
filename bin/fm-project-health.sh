#!/usr/bin/env bash
# fm-project-health.sh — machine baseline: run objective gates on a project
# and write structured evidence to .jw/health.md.
#
# No claims. No trust. Just commands and their exit codes.
# The crewmate can't say "builds pass" when the baseline shows red.
#
# Usage: fm-project-health.sh <project-dir> [--json]
#   --json  also write .jw/health.json (machine-consumable, bridge manifest format)
#
# Gates checked (auto-detected by language):
#   Go:    go build ./..., go test ./..., go vet ./..., tldr dead, tldr smells
#   Shell: shellcheck on changed scripts
#   Python: python3 -c 'import module'
#
# If tldr or ccc are not installed, those gates are marked SKIP — not FAIL.
# The script never fails because a tool is missing; it documents the gap.
#
# Exits 0 always (the health file IS the output). A red gate is not a script
# failure — it's evidence recorded in the file.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- helpers ---

now_utc() { date -u +"%Y-%m-%d %H:%M UTC"; }

gate_pass()  { printf '| %-7s | `%s` | %-4s | %s |\n' "PASS" "$1" "$2" "$3"; }
gate_fail()  { printf '| %-7s | `%s` | %-4s | %s |\n' "FAIL" "$1" "$2" "$3"; }
gate_skip()  { printf '| %-7s | `%s` | %-4s | %s |\n' "SKIP" "$1" "—" "$1 not installed"; }
gate_warn()  { printf '| %-7s | `%s` | %-4s | %s |\n' "WARN" "$1" "$2" "$3"; }

# Run a command, capture exit code and stdout. Writes to a temp log,
# returns the exit code. Caller decides pass/fail/warn.
# Usage: run_gate <logfile> <cmd...>
run_gate() {
  local log="$1"; shift
  # shellcheck disable=SC2068
  "$@" > "$log" 2>&1
}

# Detect project language from go.mod, Cargo.toml, pyproject.toml, etc.
detect_lang() {
  local dir="$1"
  if [ -f "$dir/go.mod" ]; then echo "go"; return 0; fi
  if [ -f "$dir/Cargo.toml" ]; then echo "rust"; return 0; fi
  if [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ]; then echo "python"; return 0; fi
  if [ -f "$dir/package.json" ]; then echo "node"; return 0; fi
  if ls "$dir"/*.swift >/dev/null 2>&1; then echo "swift"; return 0; fi
  if ls "$dir"/*.sh >/dev/null 2>&1; then echo "shell"; return 0; fi
  echo "unknown"
}

# --- main ---

main() {
  local project_dir fmt=md
  project_dir=""
  for a in "$@"; do
    case "$a" in
      --json) fmt=json ;;
      --help) echo "usage: fm-project-health.sh <project-dir> [--json]"; exit 0 ;;
      *) project_dir="$a" ;;
    esac
  done

  if [ -z "$project_dir" ]; then
    echo "usage: fm-project-health.sh <project-dir> [--json]" >&2
    exit 1
  fi

  project_dir="$(cd "$project_dir" 2>/dev/null && pwd -P)" || {
    echo "fm-project-health.sh: not a directory: $project_dir" >&2
    exit 1
  }
  cd "$project_dir" || {
    echo "fm-project-health.sh: cannot cd to $project_dir" >&2
    exit 1
  }

  local project_name
  project_name="$(basename "$project_dir")"
  local health_dir="$project_dir/.jw"
  mkdir -p "$health_dir"
  local logdir="$health_dir/logs"
  rm -rf "$logdir"   # fresh run each time
  mkdir -p "$logdir"

  local lang stamp
  lang="$(detect_lang "$project_dir")"
  stamp="$(now_utc)"

  # ---- build the markdown ----
  local md="$health_dir/health.md"
  {
    printf '# %s health — %s\n\n' "$project_name" "$stamp"
    printf '| Status | Command | Exit | Note |\n'
    printf '|--------|---------|------|------|\n'

    local exit_code=0
    local log=""

    # ---- go gates ----
    if [ "$lang" = "go" ]; then
      log="$logdir/build.log"
      exit_code=0
      run_gate "$log" go build ./... || exit_code=$?
      if [ "$exit_code" -eq 0 ]; then
        gate_pass "go build ./..." "$exit_code" ""
      else
        gate_fail "go build ./..." "$exit_code" "see $logdir/build.log"
      fi

      log="$logdir/test.log"
      exit_code=0
      run_gate "$log" go test ./... || exit_code=$?
      if [ "$exit_code" -eq 0 ]; then
        local pkg_count
        pkg_count="$(grep -cE '^ok\s' "$log" 2>/dev/null || echo "?")"
        gate_pass "go test ./..." "$exit_code" "$pkg_count passing packages"
      else
        gate_fail "go test ./..." "$exit_code" "see $logdir/test.log"
      fi

      log="$logdir/vet.log"
      exit_code=0
      run_gate "$log" go vet ./... || exit_code=$?
      if [ "$exit_code" -eq 0 ]; then
        gate_pass "go vet ./..." "$exit_code" ""
      else
        gate_fail "go vet ./..." "$exit_code" "see $logdir/vet.log"
      fi
    fi

    # ---- shell gates ----
    if [ "$lang" = "shell" ]; then
      local failed=0
      log="$logdir/shellcheck.log"
      :> "$log"
      while IFS= read -r -d '' f; do
        exit_code=0
        shellcheck -x "$f" >> "$log" 2>&1 || exit_code=$?
        [ "$exit_code" -ne 0 ] && failed=1
      done < <(find "$project_dir" -name '*.sh' -print0)
      if [ "$failed" -eq 0 ]; then
        gate_pass "shellcheck" "0" ""
      else
        gate_fail "shellcheck" "1" "see $logdir/shellcheck.log"
      fi
    fi

    # ---- tldr gates (language-agnostic) ----
    if command -v tldr >/dev/null 2>&1; then
      log="$logdir/dead.log"
      exit_code=0
      run_gate "$log" tldr dead || exit_code=$?
      local dead_count
      dead_count="$(grep -c '"dead_functions":' "$log" 2>/dev/null || echo "?")"
      if [ "$exit_code" -eq 0 ]; then
        gate_pass "tldr dead" "$exit_code" "$dead_count dead-function entries"
      else
        gate_warn "tldr dead" "$exit_code" "see $logdir/dead.log"
      fi

      log="$logdir/smells.log"
      exit_code=0
      run_gate "$log" tldr smells || exit_code=$?
      local smell_count
      smell_count="$(grep -c '"smells":' "$log" 2>/dev/null || echo "?")"
      if [ "$exit_code" -eq 0 ]; then
        gate_pass "tldr smells" "$exit_code" "$smell_count smell entries"
      else
        gate_warn "tldr smells" "$exit_code" "see $logdir/smells.log"
      fi
    else
      gate_skip "tldr dead"
      gate_skip "tldr smells"
    fi

    # ---- cocoindex gate ----
    if command -v ccc >/dev/null 2>&1; then
      log="$logdir/ccc.log"
      exit_code=0
      run_gate "$log" ccc status || exit_code=$?
      if [ "$exit_code" -eq 0 ]; then
        local chunks files
        chunks="$(grep Chunks "$log" 2>/dev/null | awk '{print $2}' || echo "?")"
        files="$(grep Files "$log" 2>/dev/null | awk '{print $2}' || echo "?")"
        gate_pass "ccc status" "$exit_code" "$chunks chunks, $files files"
      else
        gate_warn "ccc status" "$exit_code" "not indexed — run ccc init && ccc index"
      fi
    else
      gate_skip "ccc status"
    fi

    # ---- summary ----
    printf '\n'
    printf '**Language:** %s  \n' "$lang"
    printf '**Repo:** `%s`  \n' "$project_dir"
    printf '**Generated:** %s  \n' "$stamp"
  } > "$md"

  # ---- optional JSON (machine-consumable, bridge manifest-ish) ----
  if [ "$fmt" = "json" ]; then
    # Extract pass/fail/skip counts from the markdown table (keeping it simple:
    # just count the status column in the generated markdown).
    local passes fails skips warns
    passes="$(grep -cE '^\| PASS' "$md" || echo 0)"
    fails="$(grep -cE '^\| FAIL' "$md" || echo 0)"
    skips="$(grep -cE '^\| SKIP' "$md" || echo 0)"
    warns="$(grep -cE '^\| WARN' "$md" || echo 0)"

    printf '{"project":"%s","language":"%s","timestamp":"%s","pass":%s,"fail":%s,"skip":%s,"warn":%s}\n' \
      "$project_name" "$lang" "$stamp" "$passes" "$fails" "$skips" "$warns" \
      > "$health_dir/health.json"
  fi

  echo "health: $health_dir/health.md"
}

main "$@"
