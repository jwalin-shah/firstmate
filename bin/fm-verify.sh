#!/usr/bin/env bash
# fm-verify.sh - cross-file config invariant checker.
# Deterministic bash: PASS per check, VIOLATED per check, exits non-zero on any.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# Source harness helpers for normalize_harness. Shell-inherit a dummy arg so the
# case-default detect_own() at EOF doesn't fire.
# shellcheck source=bin/fm-harness.sh
. "$SCRIPT_DIR/fm-harness.sh" noop >/dev/null 2>&1

PASS=0; VIOLATED=0

pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
violated() { VIOLATED=$((VIOLATED+1)); echo "VIOLATED: $1  -  $2"; }

# Set of verified adapter names from fm-bootstrap.sh verified() list.
VERIFIED="claude ca ct agy cursor codex opencode pi grok"

# Helper: does the launch_template() function have a case arm for harness $1?
has_template() {
  local h=$1
  grep -qE "^\s+${h}(\||\))" "$SCRIPT_DIR/fm-spawn.sh"
}

# Check 1: Every verified harness has a launch template, directly or via alias.
check_harness_adapter_consistency() {
  local issues="" h resolved
  for h in $VERIFIED; do
    resolved=$(normalize_harness "$h")
    has_template "$resolved" && continue
    issues="$issues $h->${resolved}(missing-template)"
  done
  [ -z "$issues" ] && pass "harness-adapter-consistency" \
    || violated "harness-adapter-consistency" "no launch template:$issues"
}

# Check 2: Dispatch profile harnesses resolve to templates.
check_dispatch_profile_validity() {
  local file="$CONFIG/crew-dispatch.json"
  [ -f "$file" ] || { pass "dispatch-profile-validity (no file)"; return; }
  command -v jq >/dev/null 2>&1 || { violated "dispatch-profile-validity" "jq not found"; return; }
  local issues="" h resolved
  for h in $(jq -r '[.rules[].use.harness, .default.harness] | map(select(. != null)) | .[]' "$file" 2>/dev/null); do
    [ -n "$h" ] || continue
    resolved=$(normalize_harness "$h")
    has_template "$resolved" && continue
    issues="$issues $h->${resolved}(no-template)"
  done
  [ -z "$issues" ] && pass "dispatch-profile-validity" || violated "dispatch-profile-validity" "$issues"
}

# Check 3: crew-harness and secondmate-harness resolve to verified adapters.
check_crew_harness_validity() {
  local issues="" h resolved
  if [ -f "$CONFIG/crew-harness" ]; then
    h=$(tr -d '[:space:]' < "$CONFIG/crew-harness")
    [ -n "$h" ] && [ "$h" != "default" ] || h=""
    if [ -n "$h" ]; then
      resolved=$(normalize_harness "$h")
      has_template "$resolved" || issues="$issues crew-harness=${h}->${resolved}(no-template)"
    fi
  fi
  if [ -f "$CONFIG/secondmate-harness" ]; then
    h=$(sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; p' "$CONFIG/secondmate-harness" | head -1 | awk '{print $1}')
    [ -n "$h" ] && [ "$h" != "default" ] || h=""
    if [ -n "$h" ]; then
      resolved=$(normalize_harness "$h")
      has_template "$resolved" || issues="$issues secondmate-harness=${h}->${resolved}(no-template)"
    fi
  fi
  [ -z "$issues" ] && pass "crew-harness-validity" || violated "crew-harness-validity" "$issues"
}

# Check 4: Skills with valid SKILL.md  -  count valid, list broken.
check_skill_registration() {
  local sd="$HOME/.agents/skills"
  local valid=0 broken=0 info="" d nm ne de
  [ -d "$sd" ] || { pass "skill-registration (no skills dir)"; return; }
  for d in "$sd"/*/; do
    [ -d "$d" ] || continue
    nm=$(basename "$d")
    if [ -f "$d/SKILL.md" ] && [ -r "$d/SKILL.md" ]; then
      ne=$(grep -m1 '^name:' "$d/SKILL.md" 2>/dev/null | sed 's/^name:[[:space:]]*//')
      de=$(grep -m1 '^description:' "$d/SKILL.md" 2>/dev/null | sed 's/^description:[[:space:]]*//')
      if [ -n "$ne" ] && [ -n "$de" ]; then
        valid=$((valid+1))
      else
        broken=$((broken+1)); info="$info ${nm}(missing-field)"
      fi
    else
      broken=$((broken+1)); info="$info ${nm}(no-skill-md)"
    fi
  done
  [ "$broken" -eq 0 ] && pass "skill-registration (${valid} valid, ${broken} broken$info)" \
    || violated "skill-registration (${valid} valid, ${broken} broken$info)" "$info"
}

# Check 5: kind=secondmate homes are on the default branch.
check_secondmate_branch() {
  local issues="" home branch
  for m in "$FM_HOME"/state/*.meta; do
    [ -f "$m" ] || continue
    grep -q '^kind=secondmate$' "$m" || continue
    home=$(grep '^home=' "$m" | sed 's/^home=//')
    [ -n "$home" ] && { [ -d "$home/.git" ] || [ -f "$home/.git" ]; } || continue
    branch=$(git -C "$home" symbolic-ref --short HEAD 2>/dev/null || true)
    [ -n "$branch" ] && [ "$branch" != "main" ] || continue
    issues="$issues $(basename "$m" .meta)=${branch}"
  done
  [ -z "$issues" ] && pass "secondmate-branch-check" || violated "secondmate-branch-check" "on feature branches:$issues"
}

# Check 6: Required tools on PATH.
check_tool_availability() {
  local missing="" t
  for t in tldr ccc githits no-mistakes jq gh-axi python3; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  [ -z "$missing" ] && pass "tool-availability" || violated "tool-availability" "missing:$missing"
}

# Check 7: Backlog In flight ↔ state meta consistency.
check_in_flight_consistency() {
  local bl="$FM_HOME/data/backlog.md"
  [ -f "$bl" ] || { pass "in-flight-consistency (no backlog)"; return; }
  local issues="" id orphans="" mw="" ids
  ids=$(sed -n '/^## In flight/,/^## /p' "$bl" | grep '^- \[' | sed -E 's/^- \[.\] ([^ ]+) .*/\1/')
  for id in $ids; do
    [ -f "$FM_HOME/state/$id.meta" ] || orphans="$orphans $id"
  done
  for m in "$FM_HOME"/state/*.meta; do
    [ -f "$m" ] || continue
    grep -q '^kind=secondmate$' "$m" && continue
    grep -q '^window=' "$m" || mw="$mw $(basename "$m" .meta)"
  done
  [ -n "$orphans" ] && issues="$issues backlog-orphans:$orphans"
  [ -n "$mw" ] && issues="$issues no-window:$mw"
  [ -z "$issues" ] && pass "in-flight-consistency" || violated "in-flight-consistency" "$issues"
}

# --- main ---
check_harness_adapter_consistency
check_dispatch_profile_validity
check_crew_harness_validity
check_skill_registration
check_secondmate_branch
check_tool_availability
check_in_flight_consistency

echo "fm-verify: $PASS pass, $VIOLATED violated"
exit $(( VIOLATED > 0 ? 1 : 0 ))
