package protocol

// ──────────────────────────────────────────────────────────────
// Command interface
// ──────────────────────────────────────────────────────────────

// Command is a sealed interface for all orchestration-protocol commands.
// Every command is a value object: comparable, serializable, and
// self-describing. New commands may be added; existing commands must
// not change their field semantics.
type Command interface {
	isCommand()
}

// ──────────────────────────────────────────────────────────────
// Task lifecycle commands
// ──────────────────────────────────────────────────────────────

// Submit creates a new task in the submitted state.
type Submit struct {
	Task     TaskID
	Required string // required capability (e.g. "go", "rust")
}

// Admit transitions a task from submitted to admitted.
// Requires: task is submitted.
type Admit struct {
	Task TaskID
}

// Reject transitions a task from submitted to rejected with a reason.
// Requires: task is submitted.
type Reject struct {
	Task   TaskID
	Reason ReasonCode
}

// Defer transitions a task from submitted to deferred.
// Requires: task is submitted, reason indicates temporary unavailability.
type Defer struct {
	Task   TaskID
	Reason ReasonCode
}

// Escalate transitions a task to escalated (terminal, requires human intervention).
type Escalate struct {
	Task   TaskID
	Reason ReasonCode
}

// Cancel transitions a task to cancelled (terminal).
type Cancel struct {
	Task   TaskID
	Reason ReasonCode
}

// ──────────────────────────────────────────────────────────────
// Attempt and lease commands
// ──────────────────────────────────────────────────────────────

// Reserve reserves capacity and creates an attempt for a task.
// Requires: task is admitted or being retried, worker has available capacity.
type Reserve struct {
	Task       TaskID
	Attempt    AttemptID
	Worker     WorkerID
	LeaseEpoch LeaseEpoch
}

// Dispatch persists dispatch intent and authorizes external effect.
// Requires: reservation exists, lease is valid, epoch matches.
type Dispatch struct {
	Task       TaskID
	Attempt    AttemptID
	LeaseEpoch LeaseEpoch
}

// Start transitions an attempt from pending to running.
// Requires: attempt is pending, lease is valid, epoch matches.
type Start struct {
	Task       TaskID
	Attempt    AttemptID
	LeaseEpoch LeaseEpoch
}

// Heartbeat refreshes lease validity.
// Requires: attempt is running, lease is valid, epoch matches.
type Heartbeat struct {
	Task       TaskID
	Attempt    AttemptID
	LeaseEpoch LeaseEpoch
}

// Complete transitions an attempt from running to completed.
// Requires: attempt is running, lease is valid, epoch matches, revision is current.
type Complete struct {
	Task       TaskID
	Attempt    AttemptID
	Revision   AttemptRevision
	LeaseEpoch LeaseEpoch
}

// VerifyPass transitions a task from completed-unverified to succeeded.
// Requires: task is completed-unverified, attempt revision is current.
type VerifyPass struct {
	Task     TaskID
	Attempt  AttemptID
	Revision AttemptRevision
}

// VerifyFail transitions a task from completed-unverified to verification-failed.
// Requires: task is completed-unverified, attempt revision is current.
type VerifyFail struct {
	Task     TaskID
	Attempt  AttemptID
	Revision AttemptRevision
	Reason   ReasonCode
}

// Fail transitions an attempt from running to failed.
// Requires: attempt is running.
type Fail struct {
	Task    TaskID
	Attempt AttemptID
	Reason  ReasonCode
}

// Retry creates a new attempt after a failed or timed-out attempt.
// Requires: prior attempt is terminal, new lease epoch is strictly greater.
type Retry struct {
	Task         TaskID
	PriorAttempt AttemptID
	NewAttempt   AttemptID
	LeaseEpoch   LeaseEpoch
	Reason       ReasonCode
}

// ──────────────────────────────────────────────────────────────
// Lease lifecycle commands
// ──────────────────────────────────────────────────────────────

// ExpireLease marks a lease epoch as expired.
// After expiry, no command carrying that epoch is accepted.
type ExpireLease struct {
	Task       TaskID
	LeaseEpoch LeaseEpoch
}

// Release releases a worker's capacity reservation for an attempt.
type Release struct {
	Task    TaskID
	Attempt AttemptID
	Worker  WorkerID
}

// ──────────────────────────────────────────────────────────────
// Worker lifecycle commands
// ──────────────────────────────────────────────────────────────

// CrashWorker marks a worker as crashed and expires all its leases.
type CrashWorker struct {
	Worker WorkerID
}

// RecoverWorker marks a worker as idle after recovery.
// Any tasks that were running on this worker enter recovery reconciliation.
type RecoverWorker struct {
	Worker WorkerID
}

// ──────────────────────────────────────────────────────────────
// Dispatch eligibility
// ──────────────────────────────────────────────────────────────

// EvaluateDispatch records the result of evaluating a single dispatch
// predicate against a candidate worker for a task.
type EvaluateDispatch struct {
	Task      TaskID
	Worker    WorkerID
	Decision  Decision
	Reason    ReasonCode
	Predicate string // which predicate produced this result (e.g. "capability_check")
}

// SelectWorker commits the dispatch decision after all predicates evaluated.
type SelectWorker struct {
	Task   TaskID
	Worker WorkerID
}

// ──────────────────────────────────────────────────────────────
// Marker implementations
// ──────────────────────────────────────────────────────────────

func (Submit) isCommand()           {}
func (Admit) isCommand()            {}
func (Reject) isCommand()           {}
func (Defer) isCommand()            {}
func (Escalate) isCommand()         {}
func (Cancel) isCommand()           {}
func (Reserve) isCommand()          {}
func (Dispatch) isCommand()         {}
func (Start) isCommand()            {}
func (Heartbeat) isCommand()        {}
func (Complete) isCommand()         {}
func (VerifyPass) isCommand()       {}
func (VerifyFail) isCommand()       {}
func (Fail) isCommand()             {}
func (Retry) isCommand()            {}
func (ExpireLease) isCommand()      {}
func (Release) isCommand()          {}
func (CrashWorker) isCommand()      {}
func (RecoverWorker) isCommand()    {}
func (EvaluateDispatch) isCommand() {}
func (SelectWorker) isCommand()     {}
