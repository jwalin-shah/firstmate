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

## Agent Design Patterns (active — must follow)

**Routing EVERY brief.** Every spawn requires `## Routing` with Classification and Tier.
- Unclear goal → Scout (report, not PR). Clear goal → Ship or Parallel.
- Single repo, multi-file → Ship. N independent repos → Parallel (batch dispatch).
- L1=1 file, L2=1 repo, L3=cross-repo, L3+=multi-repo fan-out.

**Decompose L3+ Ship tasks.** Briefs > 30 lines for Ship MUST have `## Decomposition` section.
- No 92-line monoliths. Break into independent parallel pieces.
- See data/patterns/routing.md (Step 2) and data/patterns/parallelization.md.

**Contractor:** Goal/Context/Inputs/Artifact/Acceptance/Constraints/Escalation. 7 fields.
**Reflection:** bin/fm-reflection-check.sh checks output vs acceptance criteria.
**Memory:** Project knowledge → AGENTS.md. Fleet → data/learn-log.md. Captain → data/captain.md.

**Tool hierarchy (use in order):**
1. coco-axi — first call on unfamiliar tasks (unified DB)
2. llm-tldr structure|calls|arch — code analysis
3. memjuice recall — session history
4. gh-axi — GitHub operations
5. rg / fd / eza / bat — file ops (not cd+cat+ls)
6. gh — only when gh-axi doesn't cover it

**Enforcement:** fm-pattern-check.sh blocks spawn on:
- Missing Routing classification (new)
- Brief > 30 lines without Decomposition (new)
- Missing contractor fields (existing)
Override: FM_SKIP_PATTERN_CHECK=1 bin/fm-spawn.sh ...
PATTERNS

# 4. Write session agenda (from backlog + wakes)
"$FM_ROOT/bin/fm-session-agenda.sh" --write 2>/dev/null || true

# 5. Initialize session todos from agenda (idempotent)
"$FM_ROOT/bin/fm-todos.sh" list >/dev/null 2>&1 || true

exit 0
