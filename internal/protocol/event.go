package protocol

// ──────────────────────────────────────────────────────────────
// Event interface
// ──────────────────────────────────────────────────────────────

// Event is a durable record of a state transition. Events are appended
// to the event log and replayed during recovery. Events reconstruct state;
// they do not re-authorize external effects.
type Event interface {
	isEvent()
}

// ──────────────────────────────────────────────────────────────
// Task events
// ──────────────────────────────────────────────────────────────

type EvTaskSubmitted struct {
	Task     TaskID
	Required string
}
type EvTaskAdmitted struct{ Task TaskID }
type EvTaskRejected struct {
	Task   TaskID
	Reason ReasonCode
}
type EvTaskDeferred struct {
	Task   TaskID
	Reason ReasonCode
}
type EvTaskEscalated struct {
	Task   TaskID
	Reason ReasonCode
}
type EvTaskCancelled struct {
	Task   TaskID
	Reason ReasonCode
}
type EvTaskSucceeded struct {
	Task    TaskID
	Attempt AttemptID
}
type EvTaskFailed struct {
	Task    TaskID
	Attempt AttemptID
	Reason  ReasonCode
}

// ──────────────────────────────────────────────────────────────
// Attempt events
// ──────────────────────────────────────────────────────────────

type EvAttemptReserved struct {
	Task       TaskID
	Attempt    AttemptID
	Worker     WorkerID
	LeaseEpoch LeaseEpoch
	Revision   AttemptRevision
}
type EvAttemptStarted struct {
	Task       TaskID
	Attempt    AttemptID
	LeaseEpoch LeaseEpoch
}
type EvAttemptCompleted struct {
	Task       TaskID
	Attempt    AttemptID
	Revision   AttemptRevision
	LeaseEpoch LeaseEpoch
}
type EvAttemptFailed struct {
	Task    TaskID
	Attempt AttemptID
	Reason  ReasonCode
}
type EvAttemptCancelled struct {
	Task    TaskID
	Attempt AttemptID
	Reason  ReasonCode
}

// ──────────────────────────────────────────────────────────────
// Lease events
// ──────────────────────────────────────────────────────────────

type EvLeaseAcquired struct {
	Task   TaskID
	Worker WorkerID
	Epoch  LeaseEpoch
}
type EvLeaseExpired struct {
	Task  TaskID
	Epoch LeaseEpoch
}
type EvLeaseReleased struct {
	Task    TaskID
	Attempt AttemptID
	Worker  WorkerID
}

// ──────────────────────────────────────────────────────────────
// Dispatch events
// ──────────────────────────────────────────────────────────────

// EvDispatchIntentCommitted records that dispatch intent was durably
// persisted before the external side effect was issued.
type EvDispatchIntentCommitted struct {
	Task           TaskID
	Attempt        AttemptID
	Revision       AttemptRevision
	Worker         WorkerID
	LeaseEpoch     LeaseEpoch
	IdempotencyKey string
}

// EvDispatchConfirmed records that the external dispatch was acknowledged.
type EvDispatchConfirmed struct {
	Task           TaskID
	Attempt        AttemptID
	IdempotencyKey string
}

// EvDispatchUncertain records that the external dispatch acknowledgement
// was lost and reconciliation is required.
type EvDispatchUncertain struct {
	Task           TaskID
	Attempt        AttemptID
	IdempotencyKey string
}

// ──────────────────────────────────────────────────────────────
// Verification events
// ──────────────────────────────────────────────────────────────

type EvVerificationPassed struct {
	Task     TaskID
	Attempt  AttemptID
	Revision AttemptRevision
}
type EvVerificationFailed struct {
	Task     TaskID
	Attempt  AttemptID
	Revision AttemptRevision
	Reason   ReasonCode
}

// ──────────────────────────────────────────────────────────────
// Retry events
// ──────────────────────────────────────────────────────────────

type EvRetryCreated struct {
	Task         TaskID
	PriorAttempt AttemptID
	NewAttempt   AttemptID
	LeaseEpoch   LeaseEpoch
	Reason       ReasonCode
}

// ──────────────────────────────────────────────────────────────
// Worker events
// ──────────────────────────────────────────────────────────────

type EvWorkerCrashed struct {
	Worker WorkerID
}
type EvWorkerRecovered struct {
	Worker WorkerID
}

// ──────────────────────────────────────────────────────────────
// Dispatch evaluation events
// ──────────────────────────────────────────────────────────────

type EvDispatchEvaluated struct {
	Task      TaskID
	Worker    WorkerID
	Decision  Decision
	Reason    ReasonCode
	Predicate string
}
type EvWorkerSelected struct {
	Task   TaskID
	Worker WorkerID
}

// ──────────────────────────────────────────────────────────────
// Marker implementations
// ──────────────────────────────────────────────────────────────

func (EvTaskSubmitted) isEvent()         {}
func (EvTaskAdmitted) isEvent()          {}
func (EvTaskRejected) isEvent()          {}
func (EvTaskDeferred) isEvent()          {}
func (EvTaskEscalated) isEvent()         {}
func (EvTaskCancelled) isEvent()         {}
func (EvTaskSucceeded) isEvent()         {}
func (EvTaskFailed) isEvent()            {}
func (EvAttemptReserved) isEvent()       {}
func (EvAttemptStarted) isEvent()        {}
func (EvAttemptCompleted) isEvent()      {}
func (EvAttemptFailed) isEvent()         {}
func (EvAttemptCancelled) isEvent()      {}
func (EvLeaseAcquired) isEvent()         {}
func (EvLeaseExpired) isEvent()          {}
func (EvLeaseReleased) isEvent()         {}
func (EvDispatchIntentCommitted) isEvent() {}
func (EvDispatchConfirmed) isEvent()     {}
func (EvDispatchUncertain) isEvent()     {}
func (EvVerificationPassed) isEvent()    {}
func (EvVerificationFailed) isEvent()    {}
func (EvRetryCreated) isEvent()          {}
func (EvWorkerCrashed) isEvent()         {}
func (EvWorkerRecovered) isEvent()       {}
func (EvDispatchEvaluated) isEvent()     {}
func (EvWorkerSelected) isEvent()        {}

// ──────────────────────────────────────────────────────────────
// EffectIntent — side effects to perform
// ──────────────────────────────────────────────────────────────

// EffectIntent represents a side effect that must be performed after
// the corresponding event is durably persisted. During replay, effects
// are skipped — the event log reconstructs state, but effects must not
// be re-issued.
type EffectIntent struct {
	Kind           string            // "dispatch", "notify", "release_worktree"
	IdempotencyKey string            // unique per effect instance
	Task           TaskID            `json:",omitempty"`
	Attempt        AttemptID         `json:",omitempty"`
	Worker         WorkerID          `json:",omitempty"`
	LeaseEpoch     LeaseEpoch        `json:",omitempty"`
	Meta           map[string]string `json:",omitempty"`
}

// ──────────────────────────────────────────────────────────────
// Result
// ──────────────────────────────────────────────────────────────

// Result is the outcome of applying a command.
type Result struct {
	Accepted bool       // false means the command was rejected
	Reason   ReasonCode // why the command was accepted or rejected
	Message  string     // human-readable explanation
}

// ──────────────────────────────────────────────────────────────
// Transition
// ──────────────────────────────────────────────────────────────

// Transition is the complete outcome of applying a Command to State
// via the Step reducer. It captures the new state, durable events to
// append, side effects to perform, and the result.
//
// During replay, Events are used to reconstruct State but Effects are
// skipped — their idempotency keys have already been consumed.
type Transition struct {
	State   State          // new state after command
	Events  []Event        // durable events to append to the event log
	Effects []EffectIntent // side effects to perform (skipped during replay)
	Result  Result         // outcome
}

// ──────────────────────────────────────────────────────────────
// Violation
// ──────────────────────────────────────────────────────────────

// Violation describes an invariant check failure.
type Violation struct {
	Invariant string // stable invariant ID (e.g. "STATE-LEASE-001")
	Message   string // human-readable description of the violation
	Detail    string // specific state that caused the violation
}

// ──────────────────────────────────────────────────────────────
// Property classifications
// ──────────────────────────────────────────────────────────────

// PropertyClass categorizes each invariant/property by what it checks.
type PropertyClass string

const (
	ClassState   PropertyClass = "STATE"   // state predicate (CheckInvariants)
	ClassTrans   PropertyClass = "TRANS"   // legal-transition property
	ClassHistory PropertyClass = "HISTORY" // event-prefix property
	ClassReplay  PropertyClass = "REPLAY"  // reducer/replay property
	ClassLive    PropertyClass = "LIVE"    // temporal progress property
	ClassConform PropertyClass = "CONFORM" // implementation/model correspondence
)
