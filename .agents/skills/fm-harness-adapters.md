## 4. Harness adapters

Crewmates default to the same harness you are running on.
The captain may override this at any time, typically at bootstrap: record the choice in `config/crew-harness` (a single word - an adapter name below; the file is local and gitignored, so each machine keeps its own; absent or `default` means mirror your own harness).
The recorded harness is used for every dispatch until changed; a per-task instruction from the captain ("run this one on codex") overrides it for that dispatch only.
Resolve `default` by detecting your own harness (below).

Each adapter splits into mechanics and knowledge.
The mechanics (launch command, autonomy flag, turn-end hook) live in `bin/fm-spawn.sh`; the knowledge you need while supervising (busy signature, exit, interrupt, dialogs, quirks) lives in the tables below.
**Never dispatch a crewmate on an unverified adapter.**
If `config/crew-harness` names an unverified one, tell the captain and fall back to your own harness until it is verified.
If the captain asks for a new harness, propose verifying it first: spawn a trivial supervised task using fm-spawn's raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in fm-spawn, the busy signature in fm-watch's `FM_BUSY_REGEX` default, and the knowledge here, and commit.

### Detecting harnesses

`bin/fm-harness.sh` prints your own harness (verified env markers first, then process ancestry); `bin/fm-harness.sh crew` resolves the effective crewmate harness from `config/crew-harness`.
On `unknown`, ask the captain instead of guessing; a captain override always beats detection.
When you verify a new adapter, record its env marker and command name in that script.

### claude (VERIFIED)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |

First launch in a fresh worktree (or first ever on a machine) may show a trust or bypass-permissions confirmation.
After every spawn, peek the pane within ~20s; if such a dialog is showing, accept it with `bin/fm-send.sh <window> --key Enter` (or the choice the dialog requires) and verify the brief started processing.

### codex (VERIFIED 2026-06-11, codex-cli 0.139.0)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` (shown as `• Working (Xs • esc to interrupt)`) |
| Exit command | `/quit` (slash popup needs ~1s between text and Enter; fm-send handles it) |
| Interrupt | single Escape |
| Skill invocation | `$<skill>` (e.g. `$no-mistakes`); `/<skill>` is claude-only and codex rejects it as "Unrecognized command" |

Directory trust dialog on first run per repo root ("Do you trust the contents of this directory?") - accept with Enter; the decision persists for the repo, so later worktrees of the same project skip it.
Resume after exit: `codex resume <session-id>` (printed on quit).

### opencode (VERIFIED 2026-06-11, v1.15.7-1.17.3)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc interrupt` (dotted spinner footer; note: no "to") |
| Exit command | `/exit` |
| Interrupt | double Escape; known flaky while a long shell command runs - a wedged pane may need `/exit` and relaunch |

No trust dialog.
Caution: opencode auto-upgrades itself in the background and the running TUI can exit mid-task (observed live: 1.15.7 -> 1.17.3).
If a pane shows the exit banner, relaunch with `--continue` to resume the session - but `--prompt` does NOT auto-submit alongside `--continue`; send the next instruction via fm-send once the TUI is up.

### pi (VERIFIED 2026-06-11)

| Fact | Value |
|---|---|
| Busy-pane signature | `Working...` (braille spinner prefix; no "esc to interrupt" text) |
| Exit command | `/quit` |
| Interrupt | single Escape |

pi has no permission system - crewmates are always autonomous.
Keep the brief as ONE positional argument - multiple positional args become separate queued messages (fm-spawn's template does this correctly).
Project trust dialog can appear on the first pi run in any not-yet-trusted directory (observed even on clean worktrees); accept with Enter - the decision persists per path in `~/.pi/agent/trust.json`, so later spawns in the same worktree slot skip it.
Environment marker for harness detection: pi sets `PI_CODING_AGENT=true` for its children.

### cb (ADDED 2026-06-22 — needs smoke-test spawn)

`cb` is a shell function wrapping `~/bin/claude-rollover run b --dangerously-skip-permissions`.
Since it launches the same Claude Code CLI under account B, it inherits all claude adapter facts:

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |

Turn-end hook and trust dialog behavior are identical to `claude`.
Needs a smoke-test spawn to empirically confirm (first spawn in a fresh worktree may show a trust/bypass-permissions dialog; follow the claude spawn protocol from section 4).

### ctoken (ADDED 2026-06-22 — needs smoke-test spawn)

`ctoken` is `~/bin/claude-rollover run token --dangerously-skip-permissions` — Token account API key auth, otherwise identical to `claude`/`cb`.

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |

Turn-end hook and trust dialog behavior are identical to `claude`.
Needs a smoke-test spawn to empirically confirm (first spawn in a fresh worktree may show a trust/bypass-permissions dialog; follow the claude spawn protocol from section 4).

### cursor-agent (ADDED 2026-06-22 — needs smoke-test spawn)

`cursor-agent` is a CLI at `~/.local/bin/cursor-agent` that runs an interactive TUI (same paradigm as claude/codex/pi — visible pane in tmux, not headless). Cursor uses `.cursor/rules/` for project rules, not `/<skill>` invocation, so skills are not invokable the same way.

| Fact | Value |
|---|---|
| Busy-pane signature | TBD — needs smoke test |
| Exit command | TBD — check on first spawn |
| Interrupt | TBD — likely Escape |
| Skill invocation | N/A — cursor uses `.cursor/rules/` not `/<skill>` |

Launch: `cursor-agent "$(cat brief.md)"` in the treehouse worktree — do NOT pass `--worktree` (cursor-agent has its own worktree mechanism, but firstmate uses treehouse, so let it run in the treehouse-managed directory).
Model override: pass `--model <model>` (e.g. `sonnet-4`, `gpt-5`) if needed; defaults to account default.
Turn-end: no Stop hook; watcher relies on status file writes per brief rules.
Needs a smoke-test spawn to fill in busy signature and exit command.
