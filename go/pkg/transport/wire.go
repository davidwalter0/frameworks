package transport

import (
	"context"
	"fmt"
)

// Frame is one message on the wire, reduced to the fields the plumbing layer
// needs in order to correlate and route it.
//
// This is the ONLY place form and function meet, and it is deliberately thin.
// A frame carries an opaque Body: this package never encodes or decodes it, so
// a JSON-RPC adapter, a protobuf adapter and a D-Bus adapter each keep their own
// dependency and none of them leaks into a consumer that does not want it.
type Frame struct {
	// ID correlates a reply with its request. Empty means a notification —
	// no reply is expected and none will be routed.
	ID string

	// Method is the operation name. Adapters that have no notion of a method
	// (a raw byte channel) may leave it empty.
	Method string

	// Body is the opaque payload. Never inspected by this package.
	Body []byte

	// Err carries a peer-reported error for this ID. An adapter sets it when
	// the remote end answered with a failure rather than a result, so that a
	// protocol-level error and a plumbing-level one stay distinguishable.
	Err error
}

// IsNotification reports whether the frame expects no reply.
func (f Frame) IsNotification() bool { return f.ID == "" }

func (f Frame) String() string {
	kind := "call"
	if f.IsNotification() {
		kind = "notify"
	}
	return fmt.Sprintf("Frame{%s id=%q method=%q body=%dB err=%v}",
		kind, f.ID, f.Method, len(f.Body), f.Err)
}

// Wire is the form-specific half of the contract: everything that depends on
// how bytes are encoded and framed, and nothing else.
//
// Implementations are expected to be safe for ONE concurrent Send and ONE
// concurrent Recv — that is what a single byte stream can offer. [Dispatcher]
// serializes sends internally and owns the only Recv caller, so an adapter does
// not have to solve concurrency itself. This is the same total-interface
// discipline the kit's host seams use: callers branch on values, never on which
// transport they think they have.
type Wire interface {
	// Send writes one frame. It must respect ctx cancellation.
	Send(ctx context.Context, f Frame) error

	// Recv blocks for the next inbound frame. It must return a non-nil error
	// when the wire is closed or the context is cancelled, and must not return
	// a zero Frame with a nil error.
	Recv(ctx context.Context) (Frame, error)

	// Close releases the underlying resource. It must be safe to call while a
	// Recv is blocked, and must cause that Recv to return an error.
	Close() error
}
