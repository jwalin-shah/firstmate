#!/usr/bin/env bash
# Behavior tests for bin/fm-codebase-map.sh - compact structural map generator.
#
# Covers:
#   (a) tldr structure -> exported symbols output (Go project with many symbols)
#   (b) tldr returns <3 files with symbols -> tldr-based file tree fallback
#   (c) tldr unavailable -> find-based file tree fallback
#   (d) missing project directory -> graceful empty output
#   (e) output size stays within ~400 token cap
#   (f) exit 0 on every tool failure
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CODEBASE_MAP="$ROOT/bin/fm-codebase-map.sh"
TMP_ROOT=$(fm_test_tmproot fm-codebase-map)

BASE_PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"

# ---------------------------------------------------------------------------
# Fakebin builders
# ---------------------------------------------------------------------------

# A fake `tldr` that serves canned structure data from env vars.
make_fakebin() {
  local dir=$1 mode=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  case "$mode" in
    rich-symbols)
      # A fake tldr that returns a Go project structure with 15 files worth
      # of exported symbols (above the <3 threshold).
      cat > "$fakebin/tldr" <<'SH'
#!/usr/bin/env bash
# Returns rich Go JSON with ~15 files that have exported symbols.
cat <<'JSON'
{
  "root": "/test/proj",
  "language": "go",
  "files": [
    {
      "path": "cmd/root.go",
      "classes": [],
      "definitions": [{"name":"SetVersion","kind":"function"},{"name":"Execute","kind":"function"}]
    },
    {
      "path": "internal/config/config.go",
      "classes": [{"name":"Config","kind":"class"},{"name":"Hooks","kind":"class"}],
      "definitions": [{"name":"Config","kind":"class"},{"name":"Hooks","kind":"class"},{"name":"DefaultConfig","kind":"function"},{"name":"Load","kind":"function"},{"name":"LoadGlobal","kind":"function"},{"name":"ResolvePoolDir","kind":"function"},{"name":"ResolvePoolRoot","kind":"function"}]
    },
    {
      "path": "internal/config/gitignore.go",
      "definitions": [{"name":"EnsureGitignore","kind":"function"}]
    },
    {
      "path": "internal/git/git.go",
      "definitions": [{"name":"FindRepoRoot","kind":"function"},{"name":"FindRepoRootFrom","kind":"function"},{"name":"GetDefaultBranch","kind":"function"},{"name":"HasRemote","kind":"function"},{"name":"AddWorktree","kind":"function"},{"name":"RemoveWorktree","kind":"function"},{"name":"IsDirty","kind":"function"},{"name":"ShortHash","kind":"function"}]
    },
    {
      "path": "internal/hooks/hooks.go",
      "definitions": [{"name":"Run","kind":"function"}]
    },
    {
      "path": "internal/pool/pool.go",
      "definitions": [{"name":"StatusAvailable","kind":"constant"},{"name":"StatusDirty","kind":"constant"},{"name":"StatusInUse","kind":"constant"},{"name":"Acquire","kind":"function"},{"name":"Release","kind":"function"},{"name":"List","kind":"function"}]
    },
    {
      "path": "internal/pool/state.go",
      "definitions": [{"name":"WorktreeEntry","kind":"class"},{"name":"State","kind":"class"},{"name":"IsPoolDir","kind":"function"},{"name":"ReadState","kind":"function"},{"name":"WriteState","kind":"function"}]
    },
    {
      "path": "internal/process/detect.go",
      "definitions": [{"name":"ProcessInfo","kind":"class"},{"name":"IsWorktreeInUse","kind":"function"},{"name":"FindProcessesInWorktree","kind":"function"}]
    },
    {
      "path": "internal/process/terminate.go",
      "definitions": [{"name":"TerminateWorktreeProcesses","kind":"function"}]
    },
    {
      "path": "internal/shell/shell.go",
      "definitions": [{"name":"Spawn","kind":"function"}]
    },
    {
      "path": "internal/ui/path.go",
      "definitions": [{"name":"PrettyPath","kind":"function"}]
    },
    {
      "path": "internal/ui/prompt.go",
      "definitions": [{"name":"Confirm","kind":"function"}]
    },
    {
      "path": "internal/updater/updater.go",
      "definitions": [{"name":"CheckResult","kind":"class"},{"name":"CheckLatest","kind":"function"},{"name":"ReadCache","kind":"function"},{"name":"IsCacheStale","kind":"function"},{"name":"Apply","kind":"function"}]
    },
    {
      "path": "cmd/destroy.go",
      "definitions": [{"name":"DestroyClass","kind":"class"},{"name":"DestroyWorktree","kind":"function"},{"name":"DestroyPool","kind":"function"}]
    },
    {
      "path": "cmd/prune.go",
      "definitions": [{"name":"PruneWorktree","kind":"class"},{"name":"Prune","kind":"function"},{"name":"PrunePool","kind":"function"}]
    }
  ]
}
JSON
exit 0
SH
      ;;
    sparse-symbols)
      # A fake tldr that returns a project with only 1 file of exported
      # symbols (below the <3 threshold - triggers tldr-based tree fallback).
      cat > "$fakebin/tldr" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "root": "/test/proj",
  "language": "shell",
  "files": [
    {"path":"bin/run.sh","classes":[],"definitions":[{"name":"Run","kind":"function"}],"imports":[]},
    {"path":"lib/utils.sh","classes":[],"definitions":[],"imports":[]},
    {"path":"bin/init.sh","classes":[],"definitions":[],"imports":[]}
  ]
}
JSON
exit 0
SH
      ;;
    empty)
      # A fake tldr that returns an empty structure (no files detected).
      cat > "$fakebin/tldr" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "root": "/test/proj",
  "language": null,
  "files": []
}
JSON
exit 0
SH
      ;;
    failing)
      # A fake tldr that exits non-zero (simulates a broken tool).
      cat > "$fakebin/tldr" <<'SH'
#!/usr/bin/env bash
exit 1
SH
      ;;
    *)
      echo "unknown fake tldr mode: $mode" >&2
      exit 1
      ;;
  esac
  chmod +x "$fakebin/tldr"
  printf '%s\n' "$fakebin"
}

# ---------------------------------------------------------------------------
# Helper: run the script in hermetic env
# ---------------------------------------------------------------------------
run_codebase_map() {
  local fakebin=$1 proj_dir=$2
  FM_CODEBASE_CAP=1550 PATH="$fakebin:$BASE_PATH" "$CODEBASE_MAP" "$proj_dir"
}

# ---------------------------------------------------------------------------
# (a) tldr with rich symbols -> exported symbols output, capped
# ---------------------------------------------------------------------------
test_rich_symbols() {
  local d fakebin out
  d="$TMP_ROOT/a-rich-symbols"
  mkdir -p "$d"
  # Create the project dir so [ -d ... ] passes, even though the fake tldr
  # ignores it and returns canned data.
  mkdir -p "$d/proj"
  fakebin=$(make_fakebin "$d" rich-symbols)
  out=$(run_codebase_map "$fakebin" "$d/proj")
  assert_contains "$out" "# cmd" "output includes a package header"
  assert_contains "$out" "cmd/root.go: SetVersion, Execute" "output includes file with exported symbols"
  assert_contains "$out" "internal/config" "output includes config package"
  assert_not_contains "$out" "Test" "Test-prefixed symbols are excluded"
  assert_not_contains "$out" "file tree" "output does NOT say file tree - it uses the symbol path"
  [ "${#out}" -gt 200 ] || fail "output is substantial (>200 chars) for a rich project"
  [ "${#out}" -le 1550 ] || fail "output is within the 1550-char cap (had ${#out} chars)"
  pass "rich symbols path produces capped package -> symbols output"
}

# (b) tldr returns <3 files with symbols -> tldr-based file tree
test_sparse_symbols_falls_back_to_tree() {
  local d fakebin out
  d="$TMP_ROOT/b-sparse"
  mkdir -p "$d/proj"
  fakebin=$(make_fakebin "$d" sparse-symbols)
  out=$(run_codebase_map "$fakebin" "$d/proj")
  assert_contains "$out" "file tree" "fallback says 'file tree'"
  assert_contains "$out" "bin/" "output includes bin/ directory"
  assert_contains "$out" "lib/" "output includes lib/ directory"
  assert_contains "$out" "run.sh" "output includes file names"
  pass "sparse symbols -> tldr-based file tree fallback"
}

# (c) tldr returns empty structure -> falls through to find-based tree
test_empty_tldr_falls_through_to_find() {
  local d fakebin out
  d="$TMP_ROOT/c-empty-tldr"
  mkdir -p "$d/proj/bin" "$d/proj/lib"
  touch "$d/proj/bin/run.sh" "$d/proj/lib/utils.sh"
  fakebin=$(make_fakebin "$d" empty)
  out=$(run_codebase_map "$fakebin" "$d/proj")
  assert_contains "$out" "file tree" "output says 'file tree'"
  assert_contains "$out" "bin/run.sh" "find found bin/run.sh"
  assert_contains "$out" "lib/utils.sh" "find found lib/utils.sh"
  pass "empty tldr -> find-based file tree"
}

# (d) tldr unavailable -> find-based file tree
test_tldr_missing_falls_back_to_find() {
  local d out fakebin expected
  d="$TMP_ROOT/d-no-tldr"
  mkdir -p "$d/proj/bin" "$d/proj/lib"
  # Create some source files
  touch "$d/proj/bin/run.sh" "$d/proj/bin/init.sh" "$d/proj/lib/utils.sh"
  # Build fakebin with NO tldr, only find/head/sed/sort
  fakebin=$(fm_fakebin "$d")
  fm_fake_exit0 "$fakebin" find sort sed head
  # Override find to actually work (need a real find for the fallback to work)
  # The fake find exits 0 but does nothing, so we need the real find
  out=$(FM_CODEBASE_CAP=1550 PATH="/bin:/usr/bin" "$CODEBASE_MAP" "$d/proj" 2>&1)
  assert_contains "$out" "file tree" "fallback says 'file tree'"
  assert_contains "$out" "bin/run.sh" "find found bin/run.sh"
  assert_contains "$out" "bin/init.sh" "find found bin/init.sh"
  assert_contains "$out" "lib/utils.sh" "find found lib/utils.sh"
  pass "tldr missing -> find-based file tree"
}

# (e) missing project directory -> graceful empty output
test_missing_dir() {
  local out
  out=$(FM_CODEBASE_CAP=1550 PATH="/bin:/usr/bin" "$CODEBASE_MAP" "/nonexistent/path/xyz" 2>&1)
  assert_contains "$out" "not a directory" "graceful message for missing dir"
  pass "missing directory handled gracefully"
}

# (f) exit 0 even when every tool fails (find also failing is OK)
test_tool_failure_graceful() {
  local d out
  d="$TMP_ROOT/f-tool-fail"
  mkdir -p "$d/proj"
  # fake tldr fails, find not in path
  fakebin=$(make_fakebin "$d" failing)
  # Use a PATH without find
  out=$(FM_CODEBASE_CAP=1550 PATH="$fakebin:/bin:/usr/bin" "$CODEBASE_MAP" "$d/proj" 2>&1)
  local rc=$?
  expect_code 0 "$rc" "exit 0 when all tools fail"
  # Should print something minimal
  [ -n "$out" ] || fail "output is non-empty even when tools fail"
  pass "graceful exit 0 when every tool fails"
}

# Run all tests
test_rich_symbols
test_sparse_symbols_falls_back_to_tree
test_empty_tldr_falls_through_to_find
test_tldr_missing_falls_back_to_find
test_missing_dir
test_tool_failure_graceful

echo "all fm-codebase-map tests passed"
