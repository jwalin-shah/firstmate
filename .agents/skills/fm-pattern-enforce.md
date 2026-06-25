# Pattern Enforcement Guide — for firstmate's internal use

Wired into every spawn and teardown to enforce the agent design patterns from data/patterns/.

## Pre-spawn checklist (run after writing brief, before fm-spawn.sh)

1. **Routing** — is this Ship or Scout? (data/patterns/routing.md)
   - Goal unclear → Scout. No acceptance check possible → Scout.
   - Single repo, multi-file, goal clear → Ship.
   - N independent repos → Parallel (batch dispatch).

2. **Contractor** — does the brief have all 7 fields filled? (data/patterns/contractor.md)
   - **Enforced**: `bin/fm-pattern-check.sh <id>` runs in `fm-spawn.sh` — **blocks spawn** on missing fields
   - Override: `FM_SKIP_PATTERN_CHECK=1 bin/fm-spawn.sh ...` (emergency only)
   - Goal: one sentence, what not how
   - Context: why it matters, link to source
   - Inputs: specific files/PRs/reports
   - Output artifact: exact path or URL
   - Acceptance check: verifiable criteria
   - Constraints: what not to touch
   - Escalation: when to stop and ask

3. **Memory** — does the crewmate need AGENTS.md injection? (data/patterns/memory.md)
   - Check if project has AGENTS.md
   - If project knowledge exists in data/, include it in brief

## Post-done checklist (run after crewmate says done)

4. **Reflection** — critic pass (data/patterns/reflection.md)
   - **Automated**: `bin/fm-reflection-check.sh <task-id>` verifies output vs acceptance criteria
   - **Wired**: runs automatically in `fm-teardown.sh` before learn-log append
   - For small tasks: self-review the status output
   - For high-stakes: spawn a critic scout (Option B)
   - Always check: does output satisfy the acceptance check?
   - Flags: missing PR URL (ship tasks), key terms absent from status

5. **Memory persistence** (data/patterns/memory.md)
   - Did the crewmate produce durable project knowledge?
   - If so, ensure it lands in the project's AGENTS.md via fm-ensure-agents-md.sh
   - Did the captain give new preferences? Save to data/captain.md
   - Save key learnings to data/learn-log.md

## Teardown checklist

6. **Learn hook** — capture outcome
   - fm-teardown.sh writes to data/learn-log.md automatically
   - Manually add any meta-lessons the hook missed

## Tool hierarchy (from ~/.agent-rules/TOOL_REGISTRY.md)

Before raw shell commands, use in order:
1. coco-axi — first call on unfamiliar tasks
2. llm-tldr — code structure/arch/search
3. memjuice — session history recall
4. gh-axi — GitHub operations
5. File ops — rg, fd, eza, bat (not cd+cat+ls+find)
6. gh — only when gh-axi doesn't cover it
