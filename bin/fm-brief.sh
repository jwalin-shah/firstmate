#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
#
# For ship and scout tasks the brief now auto-fills project context from the
# target repo's .no-mistakes.yaml (build/test commands) and AGENTS.md
# (language, conventions, sharp edges).  Placeholders are {what} (compact
# task spec – max 3 sentences), {acceptance}, and {constraints}; firstmate
# fills those before spawning.
#
# Usage: fm-brief.sh <task-id> <repo-name> [--scout] [--phases] [--harness <name>]
#        fm-brief.sh <task-id> --secondmate <project>...
#   --harness <name> names the harness this task will actually run on (ca, ct,
#   claude, codex, cursor, agy, opencode, pi, grok - normalized via
#   fm-harness.sh's normalize_harness, so ca/ct fold into claude). Ship briefs
#   use it to fill the "Skill invocation" section with a concrete, per-harness
#   invocation form for each of the 7 pipeline skills. Pass the same value
#   fm-spawn.sh will get via --harness so the brief matches the actual launch;
#   when omitted, it falls back to the same crew-harness resolution fm-spawn.sh
#   uses by default (config/crew-harness, else firstmate's own harness).
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --phases writes a phased ship brief with four ordered phases (analyze →
#   design → implement → review). Each phase has a typed output schema, a done
#   condition, and a gate that requires firstmate approval before the next phase.
#   The crewmate sees all phases upfront but must not proceed past a gate without
#   approval. Phase 1 always produces structured output before any code is edited.
#   --phases and --scout are mutually exclusive.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
# For ship tasks, the definition of done is shaped by the project's delivery mode
# (data/projects.md via fm-project-mode.sh; see AGENTS.md project management
# and task lifecycle):
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> captain merge (default)
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> captain merge
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                firstmate reviews, captain approves, firstmate merges to local main
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# Scout tasks ignore mode - their deliverable is a report, not a merge.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# Source normalize_harness (ca/ct -> claude) and resolve_crew. Passing "noop"
# hits fm-harness.sh's default case arm (detect_own()); stdout/stderr are
# discarded so only the function definitions we need survive the source.
# shellcheck source=bin/fm-harness.sh
. "$SCRIPT_DIR/fm-harness.sh" noop >/dev/null 2>&1
KIND=ship
PHASES=0
HARNESS_ARG=""
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    HARNESS_ARG=$a
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --phases) PHASES=1 ;;
    --secondmate) KIND=secondmate ;;
    --harness) want_value=harness ;;
    --harness=*) HARNESS_ARG=${a#--harness=} ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
ID=${POS[0]}

# Resolve the harness the crewmate this brief targets will actually run on:
# an explicit --harness wins; otherwise fall back to the same crew-harness
# resolution fm-spawn.sh uses by default (config/crew-harness, else own
# harness), so an unspecified --harness still yields a concrete adapter in
# the common case where firstmate hasn't overridden it per-dispatch.
if [ -n "$HARNESS_ARG" ]; then
  HARNESS=$(normalize_harness "$HARNESS_ARG")
else
  HARNESS=$(resolve_crew)
fi

# --phases is ship-only and mutually exclusive with --scout.
if [ "$PHASES" = 1 ] && [ "$KIND" != ship ]; then
  echo "error: --phases and --$KIND are mutually exclusive" >&2; exit 1
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")

# ---------------------------------------------------------------------------
# Skill invocation – harness-specific "how" for the 7-stage skills pipeline
# below (section "Skill invocation" in AGENTS.md section 4 no-mistakes
# invocation table extended to the full pipeline). Facts sourced from the
# harness-adapters skill.
# ---------------------------------------------------------------------------

# Print the "## Skill invocation" body for the resolved harness $1 (already
# normalized, e.g. ca/ct -> claude). Each of the 7 pipeline stages gets a
# concrete invocation form for that harness; unverified/unknown harnesses get
# an explicit natural-language fallback instead of a guessed command syntax.
build_skill_invocation() {
  local h=$1
  case "$h" in
    claude|grok)
      cat <<'BLOCK'
Invoke each stage as a slash command: `/<skill>`. This opens a slash-autocomplete
popup — do not send Enter too fast or it selects the popup entry instead of
submitting; if the composer still shows the command unsent, send Enter again.

| Stage | Invocation |
|---|---|
| wayfinder | `/wayfinder` |
| codebase-design | `/codebase-design` |
| to-spec | `/to-spec` |
| implement | `/implement` |
| code-review | `/code-review` |
| simplify | `/simplify` |
| grill-me | `/grill-me` |
BLOCK
      ;;
    codex)
      cat <<'BLOCK'
Invoke each stage with a `$`-prefixed skill command: `$<skill>`. Do NOT use
`/<skill>` — that form is claude-only and codex rejects it as "Unrecognized
command". `$<skill>` opens a `$`-autocomplete popup — do not send Enter too
fast or it selects the popup entry instead of submitting; if the composer
still shows the command unsent, send Enter again.

| Stage | Invocation |
|---|---|
| wayfinder | `$wayfinder` |
| codebase-design | `$codebase-design` |
| to-spec | `$to-spec` |
| implement | `$implement` |
| code-review | `$code-review` |
| simplify | `$simplify` |
| grill-me | `$grill-me` |
BLOCK
      ;;
    opencode|pi)
      cat <<'BLOCK'
This harness has no verified slash/skill-command syntax. Invoke each stage in
plain natural language, naming the skill explicitly by name so it can be
matched and loaded.

| Stage | Invocation |
|---|---|
| wayfinder | say "load the wayfinder skill" |
| codebase-design | say "load the codebase-design skill" |
| to-spec | say "load the to-spec skill" |
| implement | say "load the implement skill" |
| code-review | say "load the code-review skill" |
| simplify | say "load the simplify skill" |
| grill-me | say "load the grill-me skill" |
BLOCK
      ;;
    agy|cursor)
      cat <<'BLOCK'
This harness has no verified skill-invocation form in firstmate's harness
knowledge yet. Invoke each stage in plain natural language, naming the skill
explicitly by name so it can be matched and loaded; if the harness turns out
to have its own native skill/command mechanism, prefer that once discovered.

| Stage | Invocation |
|---|---|
| wayfinder | say "load the wayfinder skill" |
| codebase-design | say "load the codebase-design skill" |
| to-spec | say "load the to-spec skill" |
| implement | say "load the implement skill" |
| code-review | say "load the code-review skill" |
| simplify | say "load the simplify skill" |
| grill-me | say "load the grill-me skill" |
BLOCK
      ;;
    *)
      cat <<'BLOCK'
This task's harness could not be determined at brief-scaffolding time. Do not
guess a slash-command syntax: ask firstmate which harness this task is
running on (append `needs-decision: which harness am I running on?` to the
status file) before invoking the first pipeline skill. Until you get an
answer, invoke each stage in plain natural language, naming the skill
explicitly by name.

| Stage | Invocation |
|---|---|
| wayfinder | say "load the wayfinder skill" |
| codebase-design | say "load the codebase-design skill" |
| to-spec | say "load the to-spec skill" |
| implement | say "load the implement skill" |
| code-review | say "load the code-review skill" |
| simplify | say "load the simplify skill" |
| grill-me | say "load the grill-me skill" |
BLOCK
      ;;
  esac
}

SKILL_INVOCATION=$(build_skill_invocation "$HARNESS")

# ---------------------------------------------------------------------------
# Project-file readers – derive build/test/language/conventions/sharp-edges
# from the target repo without new dependencies.
# ---------------------------------------------------------------------------

# Resolve a repo name to its on-disk project directory.  Tries FM_HOME then
# FM_ROOT (legacy layouts).  Prints the absolute path; exits 0 iff found.
resolve_project_dir() {
  local repo=$1 d
  for prefix in "$FM_HOME" "$FM_ROOT"; do
    d="$prefix/projects/$repo"
    [ -d "$d" ] && { echo "$d"; return 0; }
  done
  # The repo may be the firstmate checkout itself: FM_ROOT's basename
  # matches the repo name AND that checkout looks like a real project dir.
  if [ "$(basename "$FM_ROOT")" = "$repo" ] && [ -f "$FM_ROOT/.no-mistakes.yaml" ]; then
    echo "$FM_ROOT"
    return 0
  fi
  return 1
}

# Extract a top-level YAML scalar two levels deep.  Only handles the
# commands.build / commands.test shape (a mapping whose values are scalars).
# Prints the value stripped of quotes; exits 0 iff a non-empty value was
# found (including an explicit empty-string value like `build: ""`).
extract_yaml_scalar() {
  local parent=$1 child=$2 file=$3
  [ -f "$file" ] || return 1
  awk -v parent="$parent" -v child="$child" '
    $0 ~ "^[[:space:]]*" parent ":[[:space:]]*$" { in_parent=1; next }
    in_parent && $0 ~ "^[[:space:]]+" child ":" {
      sub(/^[[:space:]]+[^:]+:[[:space:]]*/, "")
      # Strip surrounding quotes (single or double).
      gsub(/^'\''|'\''$|^"|"$/, "")
      # Preserve the rest literally (it may contain internal quotes).
      print
      found=1; exit
    }
    in_parent && /^[^[:space:]]/ { exit }
    END { exit found ? 0 : 1 }
  ' "$file"
}

# Extract a markdown section by heading text from AGENTS.md / CLAUDE.md.
# Matches any heading level (## / ### / etc) whose text equals $section
# (case-insensitive).  Returns the body until the next heading of any level
# or EOF.  Leading/trailing blank lines are trimmed.  Exits 0 iff the
# section exists (even if its body is empty).
extract_md_section() {
  local section=$1 file=$2
  [ -f "$file" ] || return 1
  awk -v section="$section" '
    BEGIN { found=0 }
    /^#/ {
      if (found) exit
      h = $0; sub(/^#+[[:space:]]*/, "", h)
      if (tolower(h) == tolower(section)) { found=1; next }
    }
    found && /^#/ { exit }
    found {
      if (buf == "" && $0 ~ /^[[:space:]]*$/) next
      buf = buf (buf == "" ? "" : "\n") $0
    }
    END {
      if (found) {
        # Trim trailing blank lines.
        sub(/\n[[:space:]]*$/, "", buf)
        print buf
      } else exit 1
    }
  ' "$file"
}

# Find the agent-instruction file (AGENTS.md or CLAUDE.md) in a project dir.
find_agents_md() {
  local dir=$1
  for f in "$dir/AGENTS.md" "$dir/CLAUDE.md"; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

# Detect the project language from well-known build/config files.
detect_language() {
  local dir=$1
  [ -f "$dir/go.mod" ]          && { echo "Go"; return 0; }
  [ -f "$dir/Package.swift" ]   && { echo "Swift"; return 0; }
  [ -f "$dir/Cargo.toml" ]      && { echo "Rust"; return 0; }
  [ -f "$dir/package.json" ]    && { echo "TypeScript/JavaScript"; return 0; }
  [ -f "$dir/pyproject.toml" ]  && { echo "Python"; return 0; }
  [ -f "$dir/setup.py" ]        && { echo "Python"; return 0; }
  [ -f "$dir/setup.cfg" ]       && { echo "Python"; return 0; }
  [ -f "$dir/CMakeLists.txt" ]  && { echo "C/C++"; return 0; }
  # Shell: bin/ with .sh files and no stronger signal above.
  [ -d "$dir/bin" ] && find "$dir/bin" -maxdepth 1 -name '*.sh' 2>/dev/null | grep -q . && { echo "Shell"; return 0; }
  # Makefile as last resort: could be anything, so note it is a guess.
  [ -f "$dir/Makefile" ]        && { echo "(Makefile-based project — language not determined from build files)"; return 0; }
  return 1
}

# Detect build command: .no-mistakes.yaml first, then well-known build files.
detect_build_cmd() {
  local dir=$1 val
  val=$(extract_yaml_scalar commands build "$dir/.no-mistakes.yaml" 2>/dev/null || true)
  [ -n "${val-}" ] && { echo "$val"; return 0; }
  # Language-specific build files first (more precise), Makefile last.
  [ -f "$dir/go.mod" ]         && { echo "go build ./..."; return 0; }
  [ -f "$dir/Package.swift" ]  && { echo "swift build"; return 0; }
  [ -f "$dir/Cargo.toml" ]     && { echo "cargo build"; return 0; }
  [ -f "$dir/package.json" ]   && { echo "npm run build"; return 0; }
  [ -f "$dir/Makefile" ]       && { echo "make"; return 0; }
  return 1
}

# Detect test command: .no-mistakes.yaml first, then well-known build files.
detect_test_cmd() {
  local dir=$1 val
  val=$(extract_yaml_scalar commands test "$dir/.no-mistakes.yaml" 2>/dev/null || true)
  [ -n "${val-}" ] && { echo "$val"; return 0; }
  # Language-specific build files first (more precise), Makefile last.
  [ -f "$dir/go.mod" ]         && { echo "go test ./..."; return 0; }
  [ -f "$dir/Package.swift" ]  && { echo "swift test"; return 0; }
  [ -f "$dir/Cargo.toml" ]     && { echo "cargo test"; return 0; }
  [ -f "$dir/package.json" ]   && { echo "npm test"; return 0; }
  [ -f "$dir/Makefile" ]       && { echo "make test"; return 0; }
  return 1
}

# Build the "## Project context" block for ship & scout briefs.
# Prints nothing when the project directory cannot be resolved (the caller
# will fall back to a minimal placeholder).
build_project_context() {
  local dir=$1 agents_file lang build_cmd test_cmd conventions sharp_edges
  local lang_fallback build_fallback test_fallback conventions_fallback sharp_fallback

  # Per-field fallback strings when detection yields nothing.
  lang_fallback="(not detected — add a \"## Stack\" section to AGENTS.md, or a go.mod/Package.swift/Cargo.toml/package.json file)"
  build_fallback="(not detected — add a commands.build entry to .no-mistakes.yaml, or a Makefile/go.mod/Package.swift/Cargo.toml/package.json)"
  test_fallback="(not detected — add a commands.test entry to .no-mistakes.yaml, or a Makefile/go.mod/Package.swift/Cargo.toml/package.json)"
  conventions_fallback="(none documented — add a \"## Conventions\" section to AGENTS.md)"
  sharp_fallback="(none documented — add a \"## Sharp edges\" section to AGENTS.md)"

  if [ -z "${dir-}" ] || [ ! -d "$dir" ]; then
    cat <<EOF
- Language: (project directory not found — clone the repo under projects/ first)
- Build: $build_fallback
- Test: $test_fallback
- Conventions: $conventions_fallback
- Sharp edges: $sharp_fallback
EOF
    return
  fi

  # --- Language: AGENTS.md §Stack, then file-based heuristic ---
  agents_file=$(find_agents_md "$dir" 2>/dev/null || true)
  if [ -n "${agents_file-}" ] && [ -f "${agents_file-}" ]; then
    lang=$(extract_md_section "Stack" "$agents_file" 2>/dev/null || true)
    [ -z "${lang-}" ] && lang=$(extract_md_section "Language" "$agents_file" 2>/dev/null || true)
  fi
  if [ -z "${lang-}" ]; then
    lang=$(detect_language "$dir" 2>/dev/null || true)
  fi
  if [ -z "${lang-}" ]; then
    lang="$lang_fallback"
  fi

  # --- Build command: .no-mistakes.yaml commands.build, then heuristic ---
  build_cmd=$(detect_build_cmd "$dir" 2>/dev/null || true)
  [ -z "${build_cmd-}" ] && build_cmd="$build_fallback"

  # --- Test command: .no-mistakes.yaml commands.test, then heuristic ---
  test_cmd=$(detect_test_cmd "$dir" 2>/dev/null || true)
  [ -z "${test_cmd-}" ] && test_cmd="$test_fallback"

  # --- Conventions: AGENTS.md §Conventions ---
  if [ -n "${agents_file-}" ] && [ -f "${agents_file-}" ]; then
    conventions=$(extract_md_section "Conventions" "$agents_file" 2>/dev/null || true)
  fi
  [ -z "${conventions-}" ] && conventions="$conventions_fallback"

  # --- Sharp edges: AGENTS.md §Sharp edges (or §Sharp Edges) ---
  if [ -n "${agents_file-}" ] && [ -f "${agents_file-}" ]; then
    sharp_edges=$(extract_md_section "Sharp edges" "$agents_file" 2>/dev/null || true)
    [ -z "${sharp_edges-}" ] && sharp_edges=$(extract_md_section "Sharp Edges" "$agents_file" 2>/dev/null || true)
  fi
  [ -z "${sharp_edges-}" ] && sharp_edges="$sharp_fallback"

  cat <<EOF
- Language: $lang
- Build: \`$build_cmd\`
- Test: \`$test_cmd\`
- Conventions: $conventions
- Sharp edges: $sharp_edges
EOF
}

# ---------------------------------------------------------------------------
# Secondmate charter
# ---------------------------------------------------------------------------
if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
[ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project" >&2; exit 1; }
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{what}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{what}"}}
PROJECT_LIST=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
cat > "$BRIEF" <<'INNEREOF'
You are a secondmate: a persistent domain supervisor managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
INNEREOF
# Write the charter (may contain newlines) outside the heredoc so shell
# quoting does not mangle it.
printf '%s\n' "$SECONDMATE_CHARTER" >> "$BRIEF"
cat >> "$BRIEF" <<EOF

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_LIST

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
The projects above are local clones for work you supervise; they are not an exclusive ownership claim.
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate (your supervisor) is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Escalate only true captain-relevant outcomes by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, done, failed.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{what}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {what})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

# Resolve project directory and build the project-context block.
PROJ_DIR=$(resolve_project_dir "$REPO" 2>/dev/null || true)
PROJECT_CONTEXT=$(build_project_context "${PROJ_DIR-}" 2>/dev/null || true)
CODEBASE_MAP=""
if [ -n "${PROJ_DIR-}" ] && [ -d "$PROJ_DIR" ]; then
  CODEBASE_MAP=$(FM_CODEBASE_CAP=1550 "$FM_ROOT/bin/fm-codebase-map.sh" "$PROJ_DIR" 2>/dev/null || true)
  [ -n "$CODEBASE_MAP" ] && CODEBASE_MAP=$'\n'"## Codebase map"$'\n'"$CODEBASE_MAP"
fi

# ---------------------------------------------------------------------------
# Scout brief
# ---------------------------------------------------------------------------
if [ "$KIND" = scout ]; then
# Build available-tools section for scout briefs.
TOOLS_SECTION=""
if command -v cocoindex >/dev/null 2>&1; then
  TOOLS_SECTION="${TOOLS_SECTION}- Query cocoindex for related code.
"
fi
TOOLS_SECTION="${TOOLS_SECTION}- Query cognee for past fixes (http://localhost:8000).
"
TOOLS_SECTION="${TOOLS_SECTION}- Use the \`/diagnosing-bugs\` skill for systematic debugging.
"
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
## What
{what}

## Acceptance
{acceptance}

## Constraints
{constraints}

## Project context
$PROJECT_CONTEXT
$CODEBASE_MAP

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.

# Tools
$TOOLS_SECTION
# Evidence rules
The report lives or dies by its evidence. Every factual claim must cite the exact
command that proves it — not "the build passes" but "\`go build ./...\` exit 0,
output follows." If you cannot run the verifying command, say so and explain why.

**For claims about tools, ownership, or external systems** (\`git remote -v\`,
\`head -5 README.md\`, \`which <tool>\`): run the command and paste the output.
"Do not know" is always better than a wrong claim. The captain would rather have
an honest gap than a confident falsehood.

Before reporting \`done\`, review your report and ask: is every factual statement
backed by machine output in the report? If not, add it.

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {what}, {acceptance}, {constraints})"
exit 0
fi

# ---------------------------------------------------------------------------
# Ship brief
# ---------------------------------------------------------------------------

# Ship task: shape Setup / Rule 1 / Definition of done by the project's delivery mode.
# yolo does not affect the brief (it governs firstmate's approval behaviour), so discard it.
read -r MODE _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF

case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
    DOD=$(cat <<'INNEREOF'
# Definition of done
This project ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and stop.
Do NOT run /no-mistakes. The captain reviews and merges the PR; firstmate relays it.
INNEREOF
)
    ;;
  local-only)
    SETUP2=""
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
    DOD=$(cat <<EOF
# Definition of done
This project ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$ID\` to the status file and stop.
Firstmate then reviews your branch diff, the captain approves, and firstmate merges it into local \`main\`.
EOF
)
    ;;
  *)  # no-mistakes (default)
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch. Never merge a PR.'
    DOD=$(cat <<'INNEREOF'
# Definition of done
The task is complete only when committed on your branch.
When you believe it is complete, append `done: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are not yours to answer: escalate to firstmate (rule 6) and stop.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid `--yes`: the captain, not you, owns the ask-user decisions it would silently auto-resolve.

After /no-mistakes reports CI green, append `done: PR {url} checks green` and stop. You are finished.
INNEREOF
)
    ;;
esac

# Build available-tools section for ship briefs.
TOOLS_SECTION=""
if command -v cocoindex >/dev/null 2>&1; then
  TOOLS_SECTION="${TOOLS_SECTION}- Query cocoindex for related code.
"
fi
if command -v tldr >/dev/null 2>&1; then
  TOOLS_SECTION="${TOOLS_SECTION}- Query \`tldr calls\` on changed functions to see callers and impact.
"
fi

if [ "$PHASES" = 1 ]; then
  # -------------------------------------------------------------------------
  # Phased ship brief
  # -------------------------------------------------------------------------
  cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
## What
{what}

## Acceptance
{acceptance}

## Constraints
{constraints}

## Project context
$PROJECT_CONTEXT
$CODEBASE_MAP

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. First action: create your branch: \`git checkout -b fm/$ID\`$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (phase gates, setup done, validation passed) and the
   needs-decision/blocked/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions, ask-user findings),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
If this task produced durable project-intrinsic knowledge, record it in \`AGENTS.md\` as part of your change.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

# Skills pipeline
Do NOT skip any stage. Each stage produces output that gates the next. If you
do not know how to invoke a skill, ask firstmate before proceeding. The pipeline
runs in order, no shortcuts:

1. **wayfinder** — understand the codebase. Map the relevant code paths, call
   chains, data flow. If the project has \`AGENTS.md\`, read it first. Use
   \`tldr structure\` and \`tldr calls\` on the functions you will touch.
   Output: a short map of what lives where and how control flows.

2. **codebase-design** — understand the architecture. Is the change consistent
   with how the project is structured? Does it belong in an existing package or
   a new one? Does the data model fit? Output: design assessment (fit/refactor/new).

3. **to-spec** — produce a concrete spec from the task description and your
   codebase understanding. What exactly changes, in which files, with what
   acceptance criteria? Output: spec.md (file paths, function signatures, test
   cases, acceptance criteria).

4. **implement** — build it. Follow the spec. Commit on your branch. Output:
   working code, committed.

5. **code-review** — find bugs. Run full adversarial review. Check correctness,
   edge cases, error handling, concurrency. Output: findings list. Fix every
   confirmed bug before proceeding.

6. **simplify** — clean up. Remove dead code, collapse redundancy, flatten
   nesting. The diff should be the minimum that satisfies the spec. Output:
   cleaned commits.

7. **grill-me** — adversarial self-review. Pretend you are a hostile reviewer
   trying to reject this change. What would they flag? Output: rebuttal or
   fixes for every flag raised.

Each stage appends a one-line status: \`working: {stage} complete\`. The next
stage does not start until the current one is done. If a stage reveals that an
earlier stage was wrong, loop back — the pipeline is a spiral, not a waterfall.

**Write every stage's output to a file.** This directory is in the firstmate
home, NOT the worktree, so it survives teardown. Without these files, there is
no record of what you found or why you made each decision.

| Stage | Output file |
|---|---|
| wayfinder | \`$DATA/$ID/phase-1-wayfinder.md\` |
| codebase-design | \`$DATA/$ID/phase-2-design.md\` |
| to-spec | \`$DATA/$ID/phase-3-spec.md\` |
| implement | the code itself (committed on your branch) |
| code-review | \`$DATA/$ID/phase-5-review.md\` |
| simplify | \`$DATA/$ID/phase-6-simplify.md\` |
| grill-me | \`$DATA/$ID/phase-7-grill.md\` |

Create \`$DATA/$ID/\` if it does not exist. These files are the audit trail.
Scout reports go to \`$DATA/$ID/report.md\` as stated in the Definition of done.

# Skill invocation
Your harness for this task is \`$HARNESS\`. Use the invocation form below for
every stage of the skills pipeline above — do not guess a different syntax.

$SKILL_INVOCATION

# Tools
$TOOLS_SECTION
# Phased execution
This is a PHASED ship task. All four phases are described below. You must complete them in order. After each phase, append a gate status and STOP — do not proceed to the next phase until firstmate explicitly approves it. Firstmate will reply with a short approval (e.g. "approved, proceed to Phase N") via the same channel you received this brief.

**Phase 1 (analyze) must produce structured output before any code is edited.** You are analyzing, not building. Do not create your branch until Phase 3.

## Phase 1: Analyze
**Gate: firstmate must approve before you proceed to Phase 2.**

### What to produce
A structured analysis of the task. Read the relevant code paths, understand the current behavior, and identify what needs to change and why. Write it to \`$DATA/$ID/phase-1-analysis.md\` inside the worktree.

### Output schema
Your analysis must cover these dimensions:
- **Scope:** what code paths, files, modules, or systems are in play — be specific (file paths, function names)
- **Current state:** how the relevant code works today — key call chains, data flow, control flow
- **Impact:** what will change, what depends on it, and what else might break (use \`tldr calls\` or \`tldr importers\` on affected functions if available)
- **Risks & edge cases:** what could go wrong — concurrency, error handling, boundary conditions, backwards compatibility
- **Unknowns:** what you need to discover or clarify before designing a solution

### Done condition
Write the completed analysis to \`$DATA/$ID/phase-1-analysis.md\`. Then append \`needs-decision: Phase 1 (analyze) complete — approve to proceed to design?\` to the status file and STOP. Do NOT create a branch, edit code, or make any commits during this phase.

## Phase 2: Design
**Gate: firstmate must approve before you proceed to Phase 3.**

### What to produce
A design document that specifies exactly what you will build. Write it to \`$DATA/$ID/phase-2-design.md\` inside the worktree.

### Output schema
Your design must cover these dimensions:
- **Approach:** the chosen strategy and a brief rationale (why this way over alternatives)
- **File plan:** which files will be created, modified, or deleted, and in what order
- **Data/API changes:** new types, structs, function signatures, schema migrations, config keys
- **Algorithm:** step-by-step logic for the core change — pseudocode or prose, whichever is clearer
- **Test plan:** what tests to add or modify, covering happy path, edge cases, and regression risks

### Done condition
Write the completed design to \`$DATA/$ID/phase-2-design.md\`. Then append \`needs-decision: Phase 2 (design) complete — approve to proceed to implementation?\` to the status file and STOP. Do NOT create a branch, edit code, or make any commits during this phase.

## Phase 3: Implement
**Gate: firstmate must approve before you proceed to Phase 4.**

### What to produce
The code change, committed on your branch \`fm/$ID\`, following the approved design from Phase 2. Before starting this phase, create your branch with \`git checkout -b fm/$ID\`.

### Output schema
- **Commits:** one or more focused, well-described commits on the branch
- **Build:** the project builds cleanly
- **Tests:** tests pass (or new tests pass if you added any)

### Done condition
Implement the change, commit it, and verify the build and tests pass. Then append \`needs-decision: Phase 3 (implement) complete — approve to proceed to self-review?\` to the status file and STOP.

## Phase 4: Review
**Gate: none (this is the final phase — report \`done\` when complete).**

### What to produce
A self-review of your implementation. Write it to \`$DATA/$ID/phase-4-review.md\` inside the worktree. Check your own work against the acceptance criteria, the Phase 2 design, and the Phase 1 analysis. Catch issues before firstmate or the pipeline does.

### Output schema
Your self-review must cover:
- **Against acceptance:** does the change satisfy every criterion from the Acceptance section above?
- **Against design:** did you follow the Phase 2 design? Note any intentional deviations and why.
- **Edge cases:** did you handle the risks and edge cases identified in Phase 1?
- **Cleanup:** anything left to do, any compromises noted, any follow-up work worth filing

### Done condition
Write the completed self-review to \`$DATA/$ID/phase-4-review.md\`. Then append \`done: {summary}\` to the status file and STOP.

$DOD
EOF
  echo "scaffolded: $BRIEF (ship, mode=$MODE, phased; replace {what}, {acceptance}, {constraints})"
else
  # -------------------------------------------------------------------------
  # Standard ship brief
  # -------------------------------------------------------------------------
  cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
## What
{what}

## Acceptance
{acceptance}

## Constraints
{constraints}

## Project context
$PROJECT_CONTEXT
$CODEBASE_MAP

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. First action: create your branch: \`git checkout -b fm/$ID\`$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions, ask-user findings),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
If this task produced durable project-intrinsic knowledge, record it in \`AGENTS.md\` as part of your change.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

# Skills pipeline
Do NOT skip any stage. Each stage produces output that gates the next. If you
do not know how to invoke a skill, ask firstmate before proceeding. The pipeline
runs in order, no shortcuts:

1. **wayfinder** — understand the codebase. Map the relevant code paths, call
   chains, data flow. If the project has \`AGENTS.md\`, read it first. Use
   \`tldr structure\` and \`tldr calls\` on the functions you will touch.
   Output: a short map of what lives where and how control flows.

2. **codebase-design** — understand the architecture. Is the change consistent
   with how the project is structured? Does it belong in an existing package or
   a new one? Does the data model fit? Output: design assessment (fit/refactor/new).

3. **to-spec** — produce a concrete spec from the task description and your
   codebase understanding. What exactly changes, in which files, with what
   acceptance criteria? Output: spec.md (file paths, function signatures, test
   cases, acceptance criteria).

4. **implement** — build it. Follow the spec. Commit on your branch. Output:
   working code, committed.

5. **code-review** — find bugs. Run full adversarial review. Check correctness,
   edge cases, error handling, concurrency. Output: findings list. Fix every
   confirmed bug before proceeding.

6. **simplify** — clean up. Remove dead code, collapse redundancy, flatten
   nesting. The diff should be the minimum that satisfies the spec. Output:
   cleaned commits.

7. **grill-me** — adversarial self-review. Pretend you are a hostile reviewer
   trying to reject this change. What would they flag? Output: rebuttal or
   fixes for every flag raised.

Each stage appends a one-line status: \`working: {stage} complete\`. The next
stage does not start until the current one is done. If a stage reveals that an
earlier stage was wrong, loop back — the pipeline is a spiral, not a waterfall.

**Write every stage's output to a file.** This directory is in the firstmate
home, NOT the worktree, so it survives teardown. Without these files, there is
no record of what you found or why you made each decision.

| Stage | Output file |
|---|---|
| wayfinder | \`$DATA/$ID/phase-1-wayfinder.md\` |
| codebase-design | \`$DATA/$ID/phase-2-design.md\` |
| to-spec | \`$DATA/$ID/phase-3-spec.md\` |
| implement | the code itself (committed on your branch) |
| code-review | \`$DATA/$ID/phase-5-review.md\` |
| simplify | \`$DATA/$ID/phase-6-simplify.md\` |
| grill-me | \`$DATA/$ID/phase-7-grill.md\` |

Create \`$DATA/$ID/\` if it does not exist. These files are the audit trail.
Scout reports go to \`$DATA/$ID/report.md\` as stated in the Definition of done.

# Skill invocation
Your harness for this task is \`$HARNESS\`. Use the invocation form below for
every stage of the skills pipeline above — do not guess a different syntax.

$SKILL_INVOCATION

# Tools
$TOOLS_SECTION
# Proof of action
Before reporting \`done\`, run each applicable gate in the worktree. Copy the exact
output — no summarizing, no "it passes." Machine evidence only. An unchecked gate
blocks teardown the same as a failed gate.

**Required gates (run every one that applies to this project):**
- [ ] Build: the project builds cleanly (paste the exact command and its output)
- [ ] Tests: tests pass (paste the output showing pass count)
- [ ] Lint/vet: no new warnings (paste the output)
- [ ] \`tldr dead\`: no unexpected dead functions. Explain each finding.
- [ ] \`tldr smells\`: no new severity-2+ smells. Explain each finding.
- [ ] \`ccc status\`: project indexed, chunk count is current
- [ ] \`githits search\`: prior art checked for the approach used. Paste the query and what you found.

**For every factual claim about a tool, ownership, or external system:** cite the
exact command that proves it. "Treehouse is from Kun Chen" is not a fact until
\`git remote -v\` shows \`upstream = kunchenguid/treehouse\`.

**Gate fill checklist:** before reporting \`done\`, replace each \`- [ ]\` with
\`- [x]\` after running the command AND pasting its exact output below. An
unchecked box is a blocker. When all gates pass, append \`proof: all gates passed\`
to the status file. Teardown refuses without this marker.

$DOD
EOF
  echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {what}, {acceptance}, {constraints})"
fi
