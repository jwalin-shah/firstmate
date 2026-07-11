# Mutation Catalog

Seeded defects used to evaluate whether the verification system actually catches
realistic bugs. Each mutation has a link to the property it should violate.

## Ownership

| ID | Mutation | Expected Detector |
|----|----------|-------------------|
| MUT-OWN-01 | Remove lease-epoch comparison on completion | PBT, TLC, replay checker |
| MUT-OWN-02 | Accept completion from old attempt revision | PBT, TLC |
| MUT-OWN-03 | Allow terminal attempt to restart | TRANS-TERMINAL-001 |
| MUT-OWN-04 | Reject command with current epoch due to stale comparison | Monitoring only |

## Capacity and Quota

| ID | Mutation | Expected Detector |
|----|----------|-------------------|
| MUT-CAP-01 | Change `used < capacity` to `used <= capacity` | PBT, unit test, TLC |
| MUT-CAP-02 | Double-release quota (release on both failure and cleanup) | STATE-CAPACITY-001 |
| MUT-CAP-03 | Omit quota release after lease expiry | Liveness/final-state check |
| MUT-CAP-04 | Silently cap used at capacity instead of rejecting | State invariant |

## Durability and Dispatch

| ID | Mutation | Expected Detector |
|----|----------|-------------------|
| MUT-DUR-01 | Skip dispatch-intent persistence before external effect | HISTORY-DISPATCH-001 |
| MUT-DUR-02 | Treat uncertain dispatch as definitely failed | Recovery model |
| MUT-DUR-03 | Reuse old idempotency key for new attempt | History property |

## Replay

| ID | Mutation | Expected Detector |
|----|----------|-------------------|
| MUT-REP-01 | Reissue external effect during replay | REPLAY-IDEMPOTENCE-001 |
| MUT-REP-02 | Omit replay state comparison (always return "ok") | Differential test |
| MUT-REP-03 | Skip event when revision already seen (silent drop) | Trace validation |

## Lifecycle

| ID | Mutation | Expected Detector |
|----|----------|-------------------|
| MUT-LIFE-01 | Allow stale completion to overwrite newer attempt | STATE-ATTEMPT-001 |
| MUT-LIFE-02 | Mark task succeeded on process exit zero alone | Verification-gated success |
| MUT-LIFE-03 | Defer without reason code | Structured rejection check |
| MUT-LIFE-04 | Allow dispatch of task with no eligible worker | Capability safety |
