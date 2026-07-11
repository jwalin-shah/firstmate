package protocol

// ──────────────────────────────────────────────────────────────
// Identifiers
// ──────────────────────────────────────────────────────────────

// TaskID uniquely identifies a unit of work across all attempts.
type TaskID string

// AttemptID identifies one execution attempt of a task.
// A task may have multiple attempts (retries); each gets a new AttemptID.
type AttemptID string

// WorkerID identifies a backend or crewmate that can execute tasks.
type WorkerID string

// LeaseEpoch is a monotonically increasing counter that distinguishes
// successive lease grants. An epoch is invalidated on expiry or transfer.
type LeaseEpoch uint64

// AttemptRevision is a monotonically increasing counter per attempt
// that protects against stale completions and duplicate events.
type AttemptRevision uint64

// ReasonCode is a stable machine-readable identifier for why a dispatch
// decision was made. New codes may be added; existing codes must not change
// their semantics.
type ReasonCode string

// ──────────────────────────────────────────────────────────────
// Task lifecycle
// ──────────────────────────────────────────────────────────────

// TaskStatus is the lifecycle state of a task.
//
// Legal transitions:
//
//	submitted            → admitted | rejected | deferred | escalated
//	admitted             → running | failed-terminal | cancelled | escalated
//	running              → completed-unverified | failed | lease-lost
//	completed-unverified → succeeded | verification-failed | verification-timeout
//
// Terminal states (no further transitions):
//	succeeded, failed-terminal, cancelled, escalated
type TaskStatus string

const (
	TaskSubmitted           TaskStatus = "submitted"
	TaskAdmitted            TaskStatus = "admitted"
	TaskRunning             TaskStatus = "running"
	TaskCompletedUnverified TaskStatus = "completed-unverified"
	TaskSucceeded           TaskStatus = "succeeded"
	TaskFailed              TaskStatus = "failed-terminal"
	TaskCancelled           TaskStatus = "cancelled"
	TaskEscalated           TaskStatus = "escalated"
)

// IsTerminal reports whether the task status is a terminal state from
// which no further transitions are permitted.
func (s TaskStatus) IsTerminal() bool {
	switch s {
	case TaskSucceeded, TaskFailed, TaskCancelled, TaskEscalated:
		return true
	default:
		return false
	}
}

// ──────────────────────────────────────────────────────────────
// Attempt lifecycle
// ──────────────────────────────────────────────────────────────

// AttemptStatus is the lifecycle state of a single execution attempt.
//
// Terminal: completed, failed, cancelled.
type AttemptStatus string

const (
	AttemptPending   AttemptStatus = "pending"
	AttemptRunning   AttemptStatus = "running"
	AttemptCompleted AttemptStatus = "completed"
	AttemptFailed    AttemptStatus = "failed"
	AttemptCancelled AttemptStatus = "cancelled"
)

// IsTerminal reports whether the attempt status is terminal.
func (s AttemptStatus) IsTerminal() bool {
	switch s {
	case AttemptCompleted, AttemptFailed, AttemptCancelled:
		return true
	default:
		return false
	}
}

// ──────────────────────────────────────────────────────────────
// Lease
// ──────────────────────────────────────────────────────────────

// LeaseState represents the authority grant for exclusive task access.
type LeaseState string

const (
	LeaseNone    LeaseState = "none"
	LeaseValid   LeaseState = "valid"
	LeaseExpired LeaseState = "expired"
)

// ──────────────────────────────────────────────────────────────
// Workers
// ──────────────────────────────────────────────────────────────

// WorkerState is the operational state of a worker.
type WorkerState string

const (
	WorkerIdle    WorkerState = "idle"
	WorkerBusy    WorkerState = "busy"
	WorkerCrashed WorkerState = "crashed"
)

// ──────────────────────────────────────────────────────────────
// Dispatch decisions
// ──────────────────────────────────────────────────────────────

// Decision is the result of evaluating a dispatch predicate.
type Decision string

const (
	DecAdmit    Decision = "admit"
	DecReject   Decision = "reject"
	DecDefer    Decision = "defer"
	DecEscalate Decision = "escalate"
)

// ──────────────────────────────────────────────────────────────
// Reason codes
// ──────────────────────────────────────────────────────────────

// Stable reason codes for dispatch and lifecycle decisions.
// Taxonomy: capability.* capacity.* health.* quota.* permission.*
// policy.* isolation.* repository.* configuration.* admission.*
const (
	ReasonCapabilityMissing       ReasonCode = "capability.missing"
	ReasonCapacityExhausted       ReasonCode = "capacity.exhausted"
	ReasonHealthStale             ReasonCode = "health.stale"
	ReasonHealthUnhealthy         ReasonCode = "health.unhealthy"
	ReasonQuotaExhausted          ReasonCode = "quota.exhausted"
	ReasonPermissionDenied        ReasonCode = "permission.denied"
	ReasonPolicyRejected          ReasonCode = "policy.rejected"
	ReasonIsolationUnavailable    ReasonCode = "isolation.unavailable"
	ReasonRepositoryNotReady      ReasonCode = "repository.not_ready"
	ReasonConfigurationInvalid    ReasonCode = "configuration.invalid"
	ReasonAdmissionContention     ReasonCode = "admission.contention"
	ReasonAdmissionLeaseLost      ReasonCode = "admission.lease_lost"
	ReasonAdmissionEpochExpired   ReasonCode = "admission.epoch_expired"
	ReasonInternalError           ReasonCode = "internal.error"
	ReasonEligibleAtEvalButAdmissionLost ReasonCode = "admission.eval_passed_admission_lost"
)

// ──────────────────────────────────────────────────────────────
// Abstract state
// ──────────────────────────────────────────────────────────────

// State is the complete abstract model of the Firstmate orchestration
// control plane. Every field is serializable and every transition is a
// pure function from State → State.
type State struct {
	// Tasks
	TaskStatus     map[TaskID]TaskStatus
	CurrentAttempt map[TaskID]AttemptID
	RetryCount     map[TaskID]int
	DeferReason    map[TaskID]ReasonCode

	// Attempts
	AttemptStatus   map[AttemptID]AttemptStatus
	AttemptRevision map[AttemptID]AttemptRevision
	AssignedWorker  map[AttemptID]WorkerID

	// Leases
	LeaseOwner map[TaskID]WorkerID
	LeaseEpoch map[TaskID]LeaseEpoch
	LeaseState map[TaskID]LeaseState

	// Workers
	WorkerState      map[WorkerID]WorkerState
	WorkerCapacity   map[WorkerID]int
	WorkerUsed       map[WorkerID]int
	WorkerCapability map[WorkerID][]string
}

// NewState returns an empty initial state with all maps initialized.
func NewState() State {
	return State{
		TaskStatus:       make(map[TaskID]TaskStatus),
		CurrentAttempt:   make(map[TaskID]AttemptID),
		RetryCount:       make(map[TaskID]int),
		DeferReason:      make(map[TaskID]ReasonCode),
		AttemptStatus:    make(map[AttemptID]AttemptStatus),
		AttemptRevision:  make(map[AttemptID]AttemptRevision),
		AssignedWorker:   make(map[AttemptID]WorkerID),
		LeaseOwner:       make(map[TaskID]WorkerID),
		LeaseEpoch:       make(map[TaskID]LeaseEpoch),
		LeaseState:       make(map[TaskID]LeaseState),
		WorkerState:      make(map[WorkerID]WorkerState),
		WorkerCapacity:   make(map[WorkerID]int),
		WorkerUsed:       make(map[WorkerID]int),
		WorkerCapability: make(map[WorkerID][]string),
	}
}

// Clone returns a deep copy of the state for use in testing and replay.
func (s State) Clone() State {
	c := NewState()
	for k, v := range s.TaskStatus {
		c.TaskStatus[k] = v
	}
	for k, v := range s.CurrentAttempt {
		c.CurrentAttempt[k] = v
	}
	for k, v := range s.RetryCount {
		c.RetryCount[k] = v
	}
	for k, v := range s.DeferReason {
		c.DeferReason[k] = v
	}
	for k, v := range s.AttemptStatus {
		c.AttemptStatus[k] = v
	}
	for k, v := range s.AttemptRevision {
		c.AttemptRevision[k] = v
	}
	for k, v := range s.AssignedWorker {
		c.AssignedWorker[k] = v
	}
	for k, v := range s.LeaseOwner {
		c.LeaseOwner[k] = v
	}
	for k, v := range s.LeaseEpoch {
		c.LeaseEpoch[k] = v
	}
	for k, v := range s.LeaseState {
		c.LeaseState[k] = v
	}
	for k, v := range s.WorkerState {
		c.WorkerState[k] = v
	}
	for k, v := range s.WorkerCapacity {
		c.WorkerCapacity[k] = v
	}
	for k, v := range s.WorkerUsed {
		c.WorkerUsed[k] = v
	}
	for k, v := range s.WorkerCapability {
		cp := make([]string, len(v))
		copy(cp, v)
		c.WorkerCapability[k] = cp
	}
	return c
}
