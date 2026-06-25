#!/usr/bin/env bash
# bin/fm-session-start.sh — SessionStart hook for firstmate.
# Wired from ~/.claude/settings.json hooks.SessionStart.
# Must complete within 5s timeout. Silent exit 0 on success.
# Injects agent design pattern reminders as additionalContext.
set -u

FM_ROOT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$FM_ROOT" ] || [ ! -d "$FM_ROOT/state" ]; then
  FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd 2>/dev/null)" || exit 0
fi

cd "$FM_ROOT" 2>/dev/null || exit 0

# 1. Fleet lock
[ -f "state/.lock" ] && echo "⚠ fleet locked by $(cat state/.lock 2>/dev/null || echo '?')" && exit 0

# 2. Pending wakes
if [ -f "state/.wake-queue" ] && [ -s "state/.wake-queue" ]; then
  echo "📬 $(wc -l < state/.wake-queue) pending wakes — drain with bin/fm-wake-drain.sh"
  exit 0
fi

# 3. Inject agent design pattern header as context
cat << 'PATTERNS'

## Agent Design Patterns (active)

**Routing:** Ship (PR) vs Scout (report) vs Parallel (batch). Classify before spawning.
**Contractor:** Goal/Context/Inputs/Artifact/Acceptance/Constraints/Escalation. 7 fields required.
**Reflection:** Check output vs acceptance criteria. `bin/fm-reflection-check.sh <task-id>`
**Parallel:** N independent tasks → batch dispatch (`id1=repo1 id2=repo2`).
**Memory:** Project knowledge → AGENTS.md. Fleet knowledge → data/learn-log.md. Captain prefs → data/captain.md.

**Tool hierarchy (use in order):**
1. `coco-axi <task>` — first call on unfamiliar tasks (unified DB: 525k transcripts, 31k code, 33k ledgers)
2. `llm-tldr structure|calls|arch <repo>` — code analysis
3. `memjuice recall <query>` — session history
4. `gh-axi` — GitHub operations
5. `rg` / `fd` / `eza` / `bat` — file ops (not cd+cat+ls)
6. `gh` — only when gh-axi doesn't cover it

**Enforcement:** `fm-pattern-check.sh` blocks spawn if brief is missing contractor fields.
Override: `FM_SKIP_PATTERN_CHECK=1 bin/fm-spawn.sh ...`
PATTERNS

exit 0
