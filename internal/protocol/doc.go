// Package protocol defines the abstract vocabulary, types, and state model
// for Firstmate's deterministic orchestration core.
//
// Every type, constant, and field name in this package is the canonical
// vocabulary shared with the TLA+ specification. Changes to names here must
// be reflected in verification/tla/ and vice versa.
//
// Constraints:
//   - No goroutines
//   - No real clocks (time is a logical epoch or explicit step)
//   - No filesystem access
//   - No network clients
//   - No LLM APIs
//   - No subprocesses
//   - Serializable state and commands
//
// This package is the single source of transition truth. Production code
// adapts into it; the reducer (reducer.go) implements pure state transitions.
package protocol
