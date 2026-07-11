# Firstmate Verification Strategy

## Governing Principle

> The probabilistic agent may make imperfect proposals, but the deterministic
> harness cannot silently violate its orchestration protocol.

## Scope

Verify the deterministic control plane:

- State transitions
- Admission and dispatch predicates
- Lease ownership
- Capacity accounting
- Attempts and retry eligibility
- Durable event ordering
- Expiration and recovery
- Replay and idempotence
- Stable rejection and deferral reasons

Do NOT try to prove:

- That an LLM selected the best plan
- That generated code is semantically correct
- That a test suite fully captures user intent
- That external tools behave correctly
- Performance under realistic load
- Absence of every implementation or infrastructure defect

## Stack

| Layer | Tool | What it catches |
|-------|------|-----------------|
| Abstract protocol model | TLA+/TLC | Deep interleaving bugs (leases, expiry, retries) |
| Go reference reducer | Pure Go, no I/O | Single source of transition truth |
| Stateful property testing | Go PBT library | Implementation vs reference model |
| Mutation testing | Seeded defect catalog | Weak invariants, missing checks |
| Event replay + trace validation | `firstmate verify-trace` | Production drift, illegal transitions |
| Fuzzing | Go native fuzzer | Parser bugs, malformed input |
| Race detection | `go test -race` | Implementation concurrency bugs |

## Property Classification

- STATE-*    State predicates (CheckInvariants)
- TRANS-*    Legal-transition properties
- HISTORY-*  Event-prefix properties
- REPLAY-*   Reducer/replay properties
- LIVE-*     Temporal progress properties
- CONFORM-*  Implementation/model correspondence

## Minimum Initial Invariants

### STATE-LEASE-001 — Exclusive current authority
At most one unexpired lease epoch authorizes execution for an exclusive task.

### STATE-ATTEMPT-001 — Current-attempt protection
Only the current attempt revision may change task-level completion or
verification state.

### STATE-CAPACITY-001 — Capacity conservation
Worker usage equals active capacity-consuming reservations and remains
within bounds.

### TRANS-TERMINAL-001 — Terminal monotonicity
A terminal attempt cannot return to an executing state.

### HISTORY-DISPATCH-001 — Durable intent before effect
No external dispatch effect may be authorized without committed durable
intent containing task, attempt, revision, lease epoch, and idempotency key.

### REPLAY-IDEMPOTENCE-001 — Replay purity
Replaying an event prefix reconstructs the same state and does not
re-authorize already-issued external effects.

### TRANS-LEASE-002 — Expired epoch rejection
Commands carrying an expired or superseded lease epoch cannot start,
heartbeat, complete, or authorize a new side effect.

## Two-Model Strategy

### Model A: Lease, attempt, and capacity
Reserve, dispatch, start, expire, complete, retry, stale completion,
release, worker crash.

Checks: ownership, revisions, quota, terminal monotonicity.

### Model B: Durable dispatch and recovery
Persist intent, issue external effect, receive acknowledgement, crash,
recover, reconcile, retry safely.

## Implementation Order

1. Protocol vocabulary + negative examples (day 1)
2. Pure Go reducer: `func Step(State, Command) Transition` (days 1-2)
3. Stabilize commands and abstract state (days 2-3)
4. Stateful property testing against reference (days 3-6)
5. TLA+ model translated from Go vocabulary (days 6-12)
6. Counterexample bridge: TLC trace → JSON scenario (days 12-14)
7. `firstmate verify-trace` command (days 14-18)
8. Mutation catalog + CI integration (days 18-21)

## Success Criteria

### Required
- Detects 5+ intentionally seeded state-machine defects
- Catches stale-completion acceptance
- Catches double quota release or leaked reservation
- Catches dispatch without durable intent
- Produces minimized reproducible scenario
- Runs bounded safety model in ordinary CI time
- Replays integration-test event trace deterministically
- Reports invariant IDs and offending event prefix
- Reference and implementation agree on generated scenarios

### Stronger
- Mutation score ≥ 80% for protocol mutations
- All major abstract actions reached
- All task and attempt states reached
- Each invariant has at least one negative fixture
- Model counterexample → Go regression fixture within 1 hour
- Schema version drift causes CI failure
- At least one previously unknown issue found

## Repository Structure

```
internal/protocol/
    state.go
    command.go
    event.go
    effect.go
    transition.go
    reducer.go
    invariants.go
    projection.go
internal/protocol/scenarios/
    stale_completion.json
    double_release.json
    dispatch_ack_lost.json
    expired_epoch_completion.json
    replay_prefix_twice.json
verification/tla/
    LeaseAttempt.tla
    LeaseAttempt.cfg
    DispatchRecovery.tla
    DispatchRecovery.cfg
    README.md
cmd/firstmate/
    verify_trace.go
```

## Protocol Package Constraints

Zero dependencies on:
- subprocesses
- filesystem access
- real clocks
- network clients
- LLM APIs
- Git
- goroutines

## References

- Newcombe et al., "Use of Formal Methods at Amazon Web Services" (CACM, 2015)
- AWS S3 ShardStore automated reasoning (2021)
- FoundationDB deterministic simulation (SIGMOD 2021)
- MongoDB logless reconfiguration protocol (2020)
- MongoDB conformance checking (2021)
- Temporal deterministic event-history replay
- Cirstea et al., "Validating Traces of Distributed Programs Against TLA+ Specifications" (2024)
