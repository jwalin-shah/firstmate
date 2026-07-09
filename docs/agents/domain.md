# Domain Knowledge

This document captures project-level domain knowledge for firstmate:
architectural invariants, design principles, and key concepts that any
agent working on this codebase must understand.

## What firstmate is

Firstmate is a bash-based agent orchestration system. It spawns LLM
crewmates in isolated git worktrees via treehouse, supervises them
through tmux or herdr, manages task lifecycles (scout vs. ship), enforces
verification gates, and integrates with no-mistakes for CI/CD validation.

The user speaks to a single agent (the "first mate"), and that agent
dispatches work to crewmates rather than doing the work itself. This is
not an agent harness -- it is a directory (`AGENTS.md`, helper scripts,
and bundled skills) that turns any terminal coding agent into an
orchestrator.

## Core invariants

### The first mate never writes to projects

All project changes go through crewmates in isolated worktrees. The
first mate reads projects to understand them; crewmates change them. A
small set of sanctioned write exceptions exists (fleet sync, config
propagation, local-only merge, self-update), all of which are fast-forward
or guarded operations.

### Crewmates never address the captain

All crewmate communication flows through the first mate. The captain can
watch or type into any crewmate window directly; such intervention is
treated as authoritative and the first mate reconciles records at the
next heartbeat.

### Never tear down a worktree that holds unlanded work

`bin/fm-teardown.sh` enforces this. "Landed" means `HEAD` is reachable
from a remote-tracking branch, a merged PR's head contains the local
work, or the content is already in the up-to-date default branch.

### Worktree tangle prevention

The primary checkout (`FM_ROOT`) must stay on its default branch.
Crewmate worktrees and secondmate homes are linked worktrees at detached
HEAD. If a crewmate working on firstmate-itself branches the primary
instead of its worktree, the "tangle guard" surfaces this immediately.

## Architecture layers

```
Captain (user)
    |
First Mate (AGENTS.md + bin/ scripts)
    |
    +-- fm-spawn.sh --> treehouse worktree
    |
    +-- fm-watch.sh --> tmux/herdr supervision
    |
    +-- fm-brief.sh --> task/scout/secondmate brief scaffolds
    |
    +-- fm-teardown.sh --> safe worktree teardown
    |
    v
Crewmate (LLM agent in isolated worktree)
    |
    +-- ship task --> no-mistakes/direct-PR/local-only --> PR or local merge
    |
    +-- scout task --> data/<id>/report.md
    |
    +-- secondmate --> persistent domain supervisor in its own FM_HOME
```

## Key concepts

### Task shapes

- **Ship** -- deliverable is a change to the project. Shipped through the
  project's delivery mode (`no-mistakes`, `direct-PR`, `local-only`).
- **Scout** -- deliverable is knowledge (investigation, plan, bug
  reproduction, audit). Ends in a report, never a PR.

### Delivery modes

- **no-mistakes** (default) -- full pipeline review, test, lint, push,
  PR, CI. Highest assurance.
- **direct-PR** -- push + open PR via `gh-axi`, no pipeline.
- **local-only** -- local branch, no remote, no PR. Firstmate reviews
  and merges to local `main`.

### Runtime backends

- **tmux** -- verified reference backend. Task windows named `fm-<id>`.
- **herdr** -- experimental backend. Workspace-per-home, tab-per-task.

### Worktree isolation

Treehouse pools clean git worktrees. Each crewmate gets a disposable
worktree distinct from the primary checkout. Ship tasks branch from
a clean default-branch detached HEAD; scout worktrees are declared
scratch.

### Supervision

A zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet and
wakes the first mate only on actionable events. Benign wakes (working
notes, idle heartbeats) are absorbed in bash. The watcher is singleton-safe
and carries a liveness beacon; `bin/fm-guard.sh` warns if the watcher is
stale.

### Secondmates

Persistent domain supervisors that run from isolated firstmate homes
(`FM_HOME`). Each has its own state, backlog, projects, and session lock.
Secondmates are idle by default -- they reconcile in-flight work on
startup and wait for routed tasks, never self-initiating surveys.

### X mode

Opt-in feature that lets firstmate answer public `@myfirstmate` mentions
on X. Activated by placing `FMX_PAIRING_TOKEN` in `.env`. The relay
polls every 30 seconds, and mentions are classified by the `fmx-respond`
skill. Public replies are held to strict outcome-only safety rules.

## Script conventions

- Each `bin/` script has a matching `tests/<script-name>.test.sh`.
- Tests run under a hermetic sandbox with mocked `fakebin/` tools.
- Backend abstraction goes through `bin/fm-backend.sh`.
- Meta files (`state/<id>.meta`) use `key=value` line format.
- All path references in scripts should be absolute.
- `*-lib.sh` files are sourced helpers, not standalone entrypoints.

## Sharp edges

- `kill` is a bash built-in -- fakebin mocks will not shadow it.
- Process group kill (`kill -- -$PGID`) must guard against self-kill.
- `tmux list-panes -t` fails when the window is already gone; use `|| true`.
- `treehouse return --force` also kills processes; kill the process group first.
- macOS `ps` output format differs from Linux; use `command` for full argv.
- Firstmate's own `.no-mistakes/` stays gitignored; CI rejects tracked paths.
