package transport

import (
	"errors"
	"fmt"
	"time"
)

// ErrOverflow is returned by [Dispatcher.Call] when the in-flight limit is
// reached and the policy is [OverflowReject].
//
// It is a distinct error rather than a generic failure because the whole point
// of a concurrency policy is that saturation becomes a SIGNAL. A caller that
// cannot tell "the peer is slow" from "the call failed" will retry into the
// congestion it is already causing.
var ErrOverflow = errors.New("transport: in-flight limit reached")

// ErrClosed is returned once the dispatcher has been closed, or after its read
// loop has terminated.
var ErrClosed = errors.New("transport: dispatcher closed")

// Overflow names what happens when [Policy.MaxInFlight] is already reached.
//
// There is deliberately no "unbounded" member. Family-wide, an unbounded queue
// is the default almost everywhere, and it converts a slow consumer into
// unbounded memory growth rather than into a signal — which is a failure that
// shows up as an OOM far from its cause. Choosing is mandatory here.
type Overflow int

const (
	// OverflowBlock waits for a slot, honouring the caller's context. This is
	// the default: it propagates backpressure to the caller, which is the only
	// option that cannot lose work or lie about capacity.
	OverflowBlock Overflow = iota

	// OverflowReject fails immediately with [ErrOverflow]. Correct where a
	// caller has something better to do than wait — a UI that should stay
	// responsive and show a "busy" state rather than queue indefinitely.
	OverflowReject

	// OverflowDrop discards the message. Valid for notifications ONLY, where
	// losing one tick is preferable to stalling the producer; this is the
	// documented drop-on-full policy that keeps a hot path unblocked.
	//
	// A request/response Call can never be dropped — the caller is waiting for
	// a reply — so Call treats Drop as Reject and returns [ErrOverflow].
	OverflowDrop
)

func (o Overflow) String() string {
	switch o {
	case OverflowBlock:
		return "block"
	case OverflowReject:
		return "reject"
	case OverflowDrop:
		return "drop"
	default:
		return fmt.Sprintf("Overflow(%d)", int(o))
	}
}

// Policy is the concurrency and recovery contract. It is part of the shared
// plumbing rather than per-app precisely because every app otherwise invents
// its own — and the census found most invent nothing at all.
type Policy struct {
	// MaxInFlight bounds concurrent outstanding calls on one connection.
	// Zero means DefaultMaxInFlight; negative is invalid.
	MaxInFlight int

	// Overflow selects the behaviour when MaxInFlight is reached.
	Overflow Overflow

	// CallTimeout bounds a single call when its context has no deadline of its
	// own. Zero means no default timeout — the context governs entirely.
	CallTimeout time.Duration
}

// REMOVED in go/v0.1.4: Policy.NewBackOff and DefaultBackOff.
//
// They supplied a reconnect schedule that NOTHING in this package ever
// consumed — the Dispatcher never called the factory, and no reconnect loop
// existed to drive it. A delay calculator with no repetitive code around it is
// not a backoff; it is dead weight that reads as a feature, and it carried an
// external dependency (github.com/davidwalter0/backoff) for the privilege.
//
// The replacement is [Retry] in retry.go — the LOOP — parameterised by a
// [Schedule]. Removing exported symbols is a breaking change; it is taken
// deliberately here because this is a 0.y.z module and both symbols had zero
// consumers outside their own tests.

// DefaultMaxInFlight is deliberately finite and small enough to be reached in
// testing. A limit that is never hit in practice is not a limit, it is a
// comment — and it would leave the overflow path unexercised until production.
const DefaultMaxInFlight = 32

// DefaultPolicy returns the policy applied when a zero Policy is supplied:
// bounded concurrency, backpressure propagated to the caller, no implicit
// deadline.
//
// Reconnect is deliberately NOT part of Policy. It is a loop, not a setting —
// see [Retry], which takes its [Schedule] as an argument.
func DefaultPolicy() Policy {
	return Policy{
		MaxInFlight: DefaultMaxInFlight,
		Overflow:    OverflowBlock,
	}
}

// Validate reports whether the policy is usable. It is called by [New] so a
// malformed policy fails at construction rather than at the first saturation —
// the point at which it would be hardest to diagnose.
func (p Policy) Validate() error {
	if p.MaxInFlight < 0 {
		return fmt.Errorf("transport: MaxInFlight must be >= 0, got %d", p.MaxInFlight)
	}
	if p.CallTimeout < 0 {
		return fmt.Errorf("transport: CallTimeout must be >= 0, got %s", p.CallTimeout)
	}
	switch p.Overflow {
	case OverflowBlock, OverflowReject, OverflowDrop:
	default:
		return fmt.Errorf("transport: unknown Overflow value %d", int(p.Overflow))
	}
	return nil
}

// withDefaults fills zero values. Kept separate from Validate so that "unset"
// and "invalid" stay distinguishable.
func (p Policy) withDefaults() Policy {
	if p.MaxInFlight == 0 {
		p.MaxInFlight = DefaultMaxInFlight
	}
	return p
}
