# Harness Stack

This document is the repo's canonical harness spec.
It turns the AXI ideas and the current firstmate conventions into one concrete operating model.

## Goal

Keep one stable body around many swappable models.
The body is the harness: files, hooks, permissions, subagents, memory, and machine-level provisioning.

The model is only one part of the system.
The repo should make the rest of the system obvious, repeatable, and hard to drift.

## Canonical layout

Use the repo itself as the source of truth for fleet behavior.

- [`AGENTS.md`](../AGENTS.md) is the operating manual for the orchestrator.
- [`README.md`](../README.md) is the short public overview.
- [`docs/`](.) holds human-facing architecture, configuration, and system docs.
- [`bin/`](../bin) holds the runtime scripts.
- [`.agents/skills/`](../.agents/skills) holds firstmate-only skills.
- [`skills/`](../skills) holds public installer-facing skills.
- `config/`, `data/`, `state/`, and `projects/` stay local and gitignored.
- [`CLAUDE.md`](../CLAUDE.md) symlinks to `AGENTS.md` so one manual serves multiple harnesses.

This layout keeps shared behavior in tracked docs and code, while all fleet-specific state stays local.

## Canonical agent stack

Use a small, opinionated stack.

1. Primary coordinator.
   This is the captain-facing firstmate session.
   It owns intake, routing, status, and teardown.
2. Explorer subagent.
   Read-heavy, read-only, used for codebase mapping, evidence gathering, and dependency tracing.
3. Implementer subagent.
   Write-focused, used only after the shape of the work is known.
4. Verifier subagent.
   Independent checker.
   This agent should not share the implementer's context when possible.
5. Optional specialist subagents.
   Use these only when a task is clearly distinct, such as browser debugging or docs verification.

The stack should stay narrow.
Prefer a few specialized agents over many generic ones.

## Hooks and permissions

Treat hooks and permissions as the safety envelope for unattended work.

- Default to read-only unless a task needs a write.
- Allow writes only where the repo already expects them.
- Keep dangerous operations gated behind explicit human approval.
- Use hooks for automatic, repeatable checks.
- Prefer post-edit lint/test validation over manual memory.
- Keep turn-end and idle-state hooks outside project worktrees when possible.

The current firstmate runtime already follows this pattern with turn-end hooks, watcher checks, and guarded teardown.
This doc defines the broader policy.

## Memory surfaces

Use one layer for each kind of memory.

- Standing rules live in `AGENTS.md`.
- Short operational reminders live in `README.md` or a focused doc.
- Durable fleet facts live in `data/captain.md` and `data/learnings.md`.
- Task-specific notes live in `state/` and `data/<id>/brief.md`.
- Project-intrinsic knowledge lives in the target project's own `AGENTS.md`.

Do not spread the same rule across many files.
If a rule matters to the fleet, put it in one canonical place and link to it.

## AXI tools to adopt first

Adopt the AXI tools in this order:

1. `gh-axi`
   Use this first for GitHub operations.
   It gives agent-ergonomic output for PRs, issues, and repo state.
2. `chrome-devtools-axi`
   Use this for browser automation and web UI inspection.
   It is the first browser tool to standardize because it reduces action-observation churn.
3. `lavish-axi`
   Use this for rich review surfaces when an artifact needs human-style feedback.

These map cleanly onto firstmate's current needs:
GitHub, browser work, and artifact review.

## Knowledge tooling

Use the knowledge stack as a layered system, not one monolith.

- `llm-tldr` handles fast structural reads, call tracing, and impact mapping on local repos.
- `cocoindex` is the bulk recall and transcript/code/ledger index.
- `cognee` is a sidecar for higher-value graph memory and curated relationships.
- `memjuice` remains the session-history layer where available.

Keep the knowledge tooling in the machine layer, not inside firstmate itself.
That keeps the orchestrator portable while the machine still gets the best available search and recall surfaces.
`openwiki` is not currently wired in this stack.

## Nix wiring

Keep Nix in the dotfiles repo, not in firstmate.
That keeps machine provisioning separate from fleet behavior.

Recommended split:

- `projects/firstmate` owns the agent harness, docs, and scripts.
- `projects/dotfiles` owns `nix-darwin`, Home Manager, packages, aliases, and symlinks.
- The dotfiles layer installs the tools firstmate expects: shell, Git, tmux, treehouse, jq, curl, the agent CLIs, and the AXI tools.
- The dotfiles layer should expose the AXI tools directly through shell aliases or wrappers so the agent does not have to remember install details.
- Preferred access paths are `gh-axi` for GitHub, `chrome-devtools-axi` for browser automation, and `lavish-axi` for rich review.
- If a tool is not available as a declarative package, keep the install command documented and make the runtime wrapper obvious.

That split is deliberate.
It lets the machine bootstrap stay declarative while firstmate stays portable and repo-local.

## Minimum startup checklist

Before firstmate work starts, the machine should have:

- `nix` and the dotfiles bootstrap in place
- `git`, `gh`, `node`, `jq`, `tmux`, `curl`, and `treehouse`
- `claude`, `codex`, `opencode`, `pi`, or `grok` as the active harness
- `gh-axi`, `chrome-devtools-axi`, and `lavish-axi` reachable through the shell

If one of those is missing, fix the machine layer before trying to compensate in repo docs.

## Minimal firstmate policy

The firstmate repo should continue to enforce:

- no direct project writes
- explicit task shapes
- explicit backend selection
- bounded checks
- durable state on disk
- tracked docs for policy, not hidden prompt lore

If a policy cannot be described cleanly in tracked docs, the repo is too vague.
