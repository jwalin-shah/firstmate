#!/usr/bin/env bash
# Scaffold a crewmate brief at data/<task-id>/brief.md with the standard
# Setup/Rules/Definition-of-done contract filled in. Firstmate then replaces the
# {TASK} placeholder using the Contractor pattern (data/patterns/contractor.md):
#   Goal / Context / Inputs / Output artifact / Acceptance check / Constraints / Escalation
# and may adjust other sections when the task genuinely deviates (e.g. working an
# existing external PR instead of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> [--scout]
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
# For ship tasks, the definition of done is shaped by the project's delivery mode
# (data/projects.md via fm-project-mode.sh; see AGENTS.md sections 6-7):
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> captain merge (default)
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> captain merge
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                firstmate reviews, captain approves, firstmate merges to local main
# Scout tasks ignore mode - their deliverable is a report, not a merge.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path.
# Refuses to overwrite an existing brief.
#
# Relevance-gated brief injection (--inject):
#   Reads the task description (from --task-file or stdin), extracts keywords
#   (file extensions, common verb/subsystem terms), and injects only matching
#   tagged sections from the project's AGENTS.md plus the matching language
#   cache entries. See AGENTS.md "Project AGENTS.md Schema" for the schema.
#   Injection must stay under ~2s — no live network calls; lang-cache only.
set -euo pipefail
[ -n "${FM_ROOT:-}" ] || FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$FM_ROOT/bin/fm-init.sh"

# Inject last 3 learn-log entries for this repo into the brief's Context section.
# Non-fatal: missing file or no matches = no-op.
inject_learn_log() {
  local log="$FM_ROOT/data/learn-log.md"
  [ -f "$log" ] || return 0
  local matches
  matches=$(awk -v repo="$REPO" '
    BEGIN { RS="\n---\n"; FS="\n"; n=0 }
    {
      found = 0
      for (i = 1; i <= NF; i++)
        if ($i ~ "^project: .*/projects/" repo "$") { found = 1; break }
      if (!found) next
      n++; e = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^## /) e = $i
        if ($i ~ /^report-summary: #?/) e = e "\n" $i
      }
      entries[n] = e
    }
    END {
      if (!n) exit 1
      s = (n > 3) ? n - 2 : 1
      for (i = s; i <= n; i++) {
        print entries[i]
        if (i < n) print "---"
      }
    }
  ' "$log") || true
  [ -z "$matches" ] && return 0
  matches="$matches" perl -i -pe '
    if (/^Context:/ && !$inj) {
      $e = $ENV{"matches"};
      $e =~ s/^## /### /gm;
      $e =~ s/^report-summary: #?/> report: /gm;
      $_ .= "\n> **Past learnings from similar tasks:**\n$e\n";
      $inj = 1
    }
  ' "$BRIEF"
}
KIND=ship
INJECT=0
TASK_FILE=""
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
    --inject) INJECT=1 ;;
    --task-file) shift; TASK_FILE="${1:-}" ;;
    *) POS+=("$a") ;;
  esac
done
ID=${POS[0]}
REPO=${POS[1]}

# Resolve project root for AGENTS.md lookup. First try projects/<repo>
# (symlink to the local clone), then the repos themselves via data/projects.md
# registry patterns. Fall back to a bare name lookup so injection still works
# for repos that aren't symlinked yet.
PROJECT_DIR="$FM_ROOT/projects/$REPO"
if [ ! -d "$PROJECT_DIR" ]; then
  PROJECT_DIR=""
fi

BRIEF="$FM_ROOT/data/$ID/brief.md"
[ -e "$BRIEF" ] && die "$ID: brief already exists at $BRIEF"
mkdir -p "$FM_ROOT/data/$ID"

# Read the task description if we're injecting. The captain will pass either
# --task-file (when they have it on disk) or pipe via stdin (the common case).
TASK_DESC=""
if [ "$INJECT" = 1 ]; then
  if [ -n "$TASK_FILE" ] && [ -f "$TASK_FILE" ]; then
    TASK_DESC="$(cat "$TASK_FILE")"
  elif [ ! -t 0 ]; then
    TASK_DESC="$(cat)"
  fi
fi

INJECT_BLOCK=""
if [ "$INJECT" = 1 ]; then
  INJECT_BLOCK="$("$FM_ROOT/bin/fm-inject-context.sh" "$REPO" "$PROJECT_DIR" "$TASK_DESC")" || {
    echo "warn: context injection failed; writing brief without injected block" >&2
    INJECT_BLOCK=""
  }
fi

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task

<!-- Contractor contract — replace each field; skip fields that don't apply -->
Goal: {what to find or answer, one sentence}
Context: {why this matters; link to prior session, issue, or report that motivated this}
$("$FM_ROOT/bin/fm-context-load.sh" "$REPO" 3 | sed 's/^/> /' | head -10 || true)
Inputs: {specific files, PRs, or data/<id>/report.md to start from}
Output artifact: $FM_ROOT/data/$ID/report.md
Acceptance check: {what a complete, useful report contains — list the required sections}
Constraints: {what not to touch, any scope limits}
$INJECT_BLOCK
# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by piping one line to both the terminal and the status file:
   \`echo "{state}:$ID: {one short line}" | tee -a $FM_ROOT/state/$ID.status\`
   States: working, needs-decision, blocked, done, failed.
   The task id is baked into the line so firstmate can route it without
   looking up which pane you're in. Each append wakes firstmate, so report
   sparingly: only phase changes a supervisor would act on and the
   needs-decision/blocked/done/failed states. No step-by-step FYI progress
   lines; firstmate reads your pane for that.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.

# Definition of done
Write your findings to \`$FM_ROOT/data/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
inject_learn_log
echo "scaffolded: $BRIEF (scout; fill in Contractor fields: Goal/Context/Inputs/Acceptance check)"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by the project's delivery mode.
# yolo does not affect the brief (it governs firstmate's approval behaviour), so discard it.
read -r MODE _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF

case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
    DOD=$(cat <<EOF
# Definition of done
This project ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The captain reviews and merges the PR; firstmate relays it.
EOF
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
    DOD=$(cat <<EOF
# Definition of done
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
During validation, fix auto-fix findings yourself; escalate ask-user findings per rule 6.
After /no-mistakes reports CI green, append \`done: PR {url} checks green\` and stop. You are finished.
EOF
)
    ;;
esac

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task

<!-- Contractor contract — replace each field; skip fields that don't apply -->
Goal: {what to implement or fix, one sentence}
Context: {why this matters; link to scout report, issue, or session that motivated this}
$("$FM_ROOT/bin/fm-context-load.sh" "$REPO" 3 | sed 's/^/> /' | head -10 || true)
Inputs: {specific files, PRs, tickets, or data/<id>/report.md to start from}
Output artifact: PR at https://github.com/... (or branch fm/$ID for local-only)
Acceptance check: {verifiable criteria — tests pass, PR open with CI green, etc.}
Constraints: {what not to touch; delivery mode: $MODE}
$INJECT_BLOCK
# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
1. First action: create your branch: \`git checkout -b fm/$ID\`$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by piping one line to both the terminal and the status file:
   \`echo "{state}: {one short line}" | tee -a $FM_ROOT/state/$ID.status\`
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

$DOD
EOF
inject_learn_log
echo "scaffolded: $BRIEF (ship, mode=$MODE; fill in Contractor fields: Goal/Context/Inputs/Artifact/Acceptance check)"