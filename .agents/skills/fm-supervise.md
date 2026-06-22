## 8. Supervision protocol

The watcher is the backbone.
Whenever at least one task is in flight, `bin/fm-watch.sh` must be running as a background task.
It costs zero tokens while running and exits with one reason line when something needs you.
It also writes each detected wake to the durable queue at `state/.wake-queue` before advancing suppression markers such as `.seen-*`, `.stale-*`, `.last-check`, or `.last-heartbeat`.
At the start of every wake-handling turn and every recovery turn, run `bin/fm-wake-drain.sh` before peeking panes, reading status files beyond the reason line, or starting new work.
The printed one-shot reason line is still useful, but the drained queue is the lossless backlog.
After handling drained wakes, re-arm `bin/fm-watch.sh` before you end the turn.
The watcher is singleton-safe: if one is already alive with a fresh liveness beacon, another invocation exits cleanly instead of creating a duplicate watcher; if the live holder's beacon is stale, the new invocation exits with an actionable failure.
Do not pkill-and-restart the watcher as a routine operation; just arm it, and let the singleton lock no-op when appropriate.
P2/P3 of the watcher reliability design - a persistent detector daemon and blocking waiter split - are deferred; this phase intentionally preserves the current one-shot restart model.
Waiting on the watcher is intentionally silent.
After arming it, do not send idle progress updates to the captain; wait until it returns `signal`, `stale`, `check`, or `heartbeat`, unless the captain asks for status.
Empty polls, elapsed waiting time, and "still no change" are tool bookkeeping, not conversational progress.

```sh
bin/fm-watch.sh   # run in background; exits with: signal|stale|check|heartbeat
bin/fm-wake-drain.sh   # drain queued wake records at turn start
```

On wake, in order of cheapness:

1. Read the reason line and drain queued wake records with `bin/fm-wake-drain.sh`.
2. `signal:` read the listed status files first; a wake lists every signal that landed within the coalescing grace window (e.g. a status write plus the same turn's turn-end marker), and each is ~30 tokens and usually sufficient.
3. `stale:` the crewmate stopped without reporting; peek the pane (`bin/fm-peek.sh <window>`) to diagnose.
4. `check:` a per-task poll fired (usually a merge); act on it.
5. `heartbeat:` review the whole fleet: skim each window's status file, peek panes that look off, check PR-ready tasks for merge, reconcile data/backlog.md, then re-arm the watcher.
   A heartbeat with no captain-relevant change is internal; do not report that the fleet is unchanged.

Heartbeats back off exponentially while they are the only wakes firing (600s doubling to a 2h cap - an idle fleet stops burning turns); any signal, stale, or check wake resets the cadence to the base interval.
Due per-task checks run before signal scanning so chatty crewmate status updates cannot starve slow polls like merge detection.

Never rely on hooks or status files alone; the heartbeat review of every window is mandatory and unconditional.
tmux is the ground truth.

**Watcher liveness is guarded, not just disciplined.**
`fm-watch.sh` touches `state/.last-watcher-beat` every poll cycle. The supervision scripts (`fm-peek`, `fm-send`, `fm-spawn`, `fm-teardown`, `fm-pr-check`, `fm-promote`, `fm-review-diff`, `fm-fleet-sync`) call `bin/fm-guard.sh` first, which warns to stderr when queued wakes are pending or the beacon is missing/older than `FM_GUARD_GRACE` (default 300s). If guard warns about pending wakes: drain them first. If guard warns about stale liveness: arm `bin/fm-watch.sh` after draining.
Do not run foreground-blocking operations (long builds, pipelines) while tasks are in flight — background them so watcher wakes can interleave.

Token discipline: status files before panes; default peeks to 40 lines; never stream a pane repeatedly through yourself; batch what you tell the captain.
The context-% shown in a peek is not actionable as crew health; ignore it and intervene only on real signals (`signal`, `stale`, `needs-decision`, `blocked`), looping or confusion in the pane, or a question the brief already answers.
Silence is the correct state while a healthy background watcher is waiting.

### Stuck-crewmate playbook (escalate in order)

1. Peek the pane.
2. Crewmate is waiting on a question its brief already answers: answer in one line via fm-send.
3. Crewmate is confused or looping: interrupt with the adapter's interrupt key (the window's harness is recorded as `harness=` in `state/<id>.meta`; e.g. `bin/fm-send.sh <window> --key Escape`), then redirect with one corrective line.
4. Crewmate is genuinely wedged after redirection: exit the agent with the adapter's exit command, relaunch with the same brief plus a `progress so far` note you append to it.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist; this is cheap.
5. Second relaunch fails too: write `failed` to backlog, tell the captain with evidence.
