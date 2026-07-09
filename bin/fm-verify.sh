#!/usr/bin/env bash
# fm-verify.sh - prove firstmate's config invariants hold. Read-only, deterministic.
# Usage: fm-verify.sh
#   Prints "PASS: <check>" or "VIOLATED: <check> - <reason>" for each of the
#   invariants in SPEC_INVARIANTS below, then one summary line. Exits 0 when
#   every check passes, non-zero when any check has at least one violation.
# Run at session start (after fm-bootstrap.sh) and before any crewmate spawn.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SKILLS="${FM_SKILLS_OVERRIDE:-$HOME/.agents/skills}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# normalize_harness() only - this script takes no args, so $1 is already
# empty and fm-harness.sh's trailing dispatch harmlessly runs detect_own();
# its stdout is discarded.
. "$SCRIPT_DIR/fm-harness.sh" >/dev/null 2>&1 || true

# Ordered "<check-name>|<invariant>" pairs (the githits SPEC_INVARIANTS
# pattern, kept as a plain indexed array - not `declare -A` - so this script
# runs under macOS's bundled bash 3.2 as well as bash 4+).
SPEC_INVARIANTS=(
  "harness-adapter-consistency|every bootstrap-verified harness has a fm-spawn.sh launch template, and vice versa"
  "dispatch-profile-validity|every config/crew-dispatch.json harness normalizes to one with a launch template"
  "crew-harness-validity|explicit config/crew-harness and config/secondmate-harness overrides resolve to a harness with a launch template"
  "skill-registration|every ~/.agents/skills/*/SKILL.md has non-empty name: and description: frontmatter"
  "secondmate-branch-check|every kind=secondmate state/*.meta home= is checked out on the default branch"
  "tool-availability|required tools (tldr, ccc, githits, no-mistakes, jq, gh-axi, python3) are on PATH"
  "in-flight-consistency|every backlog In-flight id has a state/<id>.meta and vice versa (window= when not a secondmate)"
)

report_pass() { printf 'PASS: %s - %s\n' "$1" "$2"; }
report_violated() { printf 'VIOLATED: %s - %s\n' "$1" "$2"; }

# Static analysis targets the firstmate repo bin/ scripts this script itself
# ships alongside (SCRIPT_DIR), never the overridable FM_ROOT/FM_HOME: those
# name the operational HOME being verified (config/, state/, data/), which in
# tests is a bare fixture dir with no bin/ of its own.
bootstrap_verified_harnesses() {
  grep -o 'def verified(\$h): \[[^]]*\]' "$SCRIPT_DIR/fm-bootstrap.sh" | grep -o '"[a-zA-Z_-]*"' | tr -d '"'
}

spawn_template_harnesses() {
  awk '/^launch_template\(\) \{/{f=1} f{print} /^\}/{if(f){exit}}' "$SCRIPT_DIR/fm-spawn.sh" \
    | grep -E '^[[:space:]]*[A-Za-z_|]+\)' \
    | sed -E 's/^[[:space:]]*([A-Za-z_|]+)\).*/\1/' \
    | tr '|' '\n' | grep -v '^\*$' | sort -u
}

normalize_targets() {
  sed -n '/^normalize_harness/,/^}/p' "$SCRIPT_DIR/fm-harness.sh" \
    | grep -E '^[[:space:]]*[A-Za-z_|]+\) echo [A-Za-z_]+ ;;' \
    | sed -E 's/^[[:space:]]*[A-Za-z_|]+\) echo ([A-Za-z_]+) ;;.*/\1/' | sort -u
}

check_harness_adapter_consistency() {
  local name=$1 bset sset only_bset only_sset bad_targets reason=""
  bset=$(bootstrap_verified_harnesses)
  sset=$(spawn_template_harnesses)
  only_bset=$(comm -23 <(printf '%s\n' "$bset" | sort -u) <(printf '%s\n' "$sset" | sort -u))
  only_sset=$(comm -13 <(printf '%s\n' "$bset" | sort -u) <(printf '%s\n' "$sset" | sort -u))
  bad_targets=$(comm -23 <(normalize_targets) <(printf '%s\n' "$bset" | sort -u))
  [ -n "$only_bset" ] && reason+="bootstrap-verified but no spawn template: $(echo "$only_bset" | tr '\n' ' '); "
  [ -n "$only_sset" ] && reason+="spawn template but not bootstrap-verified: $(echo "$only_sset" | tr '\n' ' '); "
  [ -n "$bad_targets" ] && reason+="normalize_harness maps to an unverified adapter: $(echo "$bad_targets" | tr '\n' ' '); "
  if [ -n "$reason" ]; then report_violated "$name" "$reason"; return 1; fi
  report_pass "$name" "$(echo "$bset" | tr '\n' ' ' | sed 's/ $//')"
}

check_dispatch_profile_validity() {
  local name=$1 file="$CONFIG/crew-dispatch.json" sset harnesses h norm bad=""
  if [ ! -f "$file" ]; then report_pass "$name" "no config/crew-dispatch.json"; return 0; fi
  if ! command -v jq >/dev/null 2>&1; then report_violated "$name" "jq not on PATH, cannot validate"; return 1; fi
  harnesses=$(jq -r '[(.rules // [])[]?.use?.harness, .default?.harness?] | map(select(. != null)) | unique | .[]' "$file" 2>/dev/null)
  sset=$(spawn_template_harnesses)
  for h in $harnesses; do
    norm=$(normalize_harness "$h")
    if ! printf '%s\n' "$sset" | grep -qx "$norm"; then
      bad+="$h (normalizes to $norm, no launch template); "
    fi
  done
  if [ -n "$bad" ]; then report_violated "$name" "$bad"; return 1; fi
  report_pass "$name" "profiles: $(echo "$harnesses" | tr '\n' ' ' | sed 's/ $//')"
}

# Only explicit config overrides are checked - an absent or "default" value
# defers to runtime harness auto-detection, which is environment state, not a
# config invariant this script can prove.
check_crew_harness_validity() {
  local name=$1 sset crew sm crew_norm sm_norm bad="" msg=""
  sset=$(spawn_template_harnesses)
  crew=""
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness")
  if [ -n "$crew" ] && [ "$crew" != "default" ]; then
    crew_norm=$(normalize_harness "$crew")
    if printf '%s\n' "$sset" | grep -qx "$crew_norm"; then
      msg+="crew-harness=$crew(->$crew_norm); "
    else
      bad+="crew-harness=$crew (normalizes to $crew_norm), no launch template; "
    fi
  fi
  sm=""
  [ -f "$CONFIG/secondmate-harness" ] && sm=$(awk 'NF && $1 !~ /^#/ {print $1; exit}' "$CONFIG/secondmate-harness")
  if [ -n "$sm" ] && [ "$sm" != "default" ]; then
    sm_norm=$(normalize_harness "$sm")
    if printf '%s\n' "$sset" | grep -qx "$sm_norm"; then
      msg+="secondmate-harness=$sm(->$sm_norm); "
    else
      bad+="secondmate-harness=$sm (normalizes to $sm_norm), no launch template; "
    fi
  fi
  if [ -n "$bad" ]; then report_violated "$name" "$bad"; return 1; fi
  [ -n "$msg" ] || msg="no explicit crew-harness/secondmate-harness override configured"
  report_pass "$name" "$msg"
}

check_skill_registration() {
  local name=$1 dir count=0 broken="" f
  [ -d "$SKILLS" ] || { report_violated "$name" "no skills dir at $SKILLS"; return 1; }
  for dir in "$SKILLS"/*/; do
    [ -d "$dir" ] || continue
    f="${dir}SKILL.md"
    if [ ! -r "$f" ]; then
      broken+="$(basename "$dir") (missing/unreadable SKILL.md); "
      continue
    fi
    if awk '/^---$/{n++; next} n==1' "$f" | grep -qE '^name:[[:space:]]*\S' \
      && awk '/^---$/{n++; next} n==1' "$f" | grep -qE '^description:[[:space:]]*\S'; then
      count=$((count + 1))
    else
      broken+="$(basename "$dir") (missing name:/description: frontmatter); "
    fi
  done
  if [ -n "$broken" ]; then report_violated "$name" "$broken"; return 1; fi
  report_pass "$name" "$count skills registered"
}

check_secondmate_branch_check() {
  local name=$1 meta kind home branch default bad="" n=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = secondmate ] || continue
    n=$((n + 1))
    home=$(fm_meta_get "$meta" home)
    if [ -z "$home" ] || [ ! -d "$home" ]; then
      bad+="$(basename "$meta" .meta) (home=$home missing); "
      continue
    fi
    branch=$(git -C "$home" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    default=$(fm_default_branch "$home" 2>/dev/null || echo main)
    if [ -z "$branch" ]; then
      bad+="$(basename "$meta" .meta) (home detached, expected $default); "
    elif [ "$branch" != "$default" ]; then
      bad+="$(basename "$meta" .meta) (home on feature branch '$branch', expected '$default'); "
    fi
  done
  if [ -n "$bad" ]; then report_violated "$name" "$bad"; return 1; fi
  report_pass "$name" "$n secondmate home(s) checked"
}

check_tool_availability() {
  local name=$1 t missing=""
  for t in tldr ccc githits no-mistakes jq gh-axi python3; do
    command -v "$t" >/dev/null 2>&1 || missing+="$t "
  done
  if [ -n "$missing" ]; then report_violated "$name" "missing: $missing"; return 1; fi
  report_pass "$name" "all required tools on PATH"
}

check_in_flight_consistency() {
  local name=$1 backlog="$DATA/backlog.md" ids id bad="" meta kind window
  [ -f "$backlog" ] || { report_pass "$name" "no data/backlog.md"; return 0; }
  ids=$(awk '
    /^## / { insec = ($0 == "## In flight"); next }
    insec && /^- \[[ x]\] / {
      line = $0; sub(/^- \[[ x]\] +/, "", line); id = line; sub(/[ \t].*/, "", id); print id
    }' "$backlog")
  for id in $ids; do
    [ -f "$STATE/$id.meta" ] || bad+="in-flight '$id' has no state/$id.meta; "
  done
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = secondmate ] && continue
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] || bad+="$(basename "$meta" .meta) has no window= recorded; "
  done
  if [ -n "$bad" ]; then report_violated "$name" "$bad"; return 1; fi
  report_pass "$name" "$(printf '%s' "$ids" | grep -c .) in-flight id(s) consistent"
}

overall=0
total=${#SPEC_INVARIANTS[@]}
for entry in "${SPEC_INVARIANTS[@]}"; do
  name=${entry%%|*}
  fn="check_${name//-/_}"
  "$fn" "$name" || overall=1
done

if [ "$overall" -eq 0 ]; then
  echo "fm-verify: OK ($total/$total checks passed)"
else
  echo "fm-verify: VIOLATIONS FOUND"
fi
exit "$overall"
