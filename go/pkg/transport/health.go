package transport

import "fmt"

// Health is the liveness state a consumer can render without knowing anything
// about the transport underneath.
//
// It exists as a shared vocabulary because the census found every app inventing
// its own — and a UI that wants to show "reconnecting" needs the same four
// answers whether the wire is a subprocess pipe, a D-Bus proxy or a socket.
type Health int

const (
	// Disconnected: no wire, and none being established.
	Disconnected Health = iota

	// Connecting: a connect or reconnect attempt is in progress.
	Connecting

	// Ready: the wire is up and calls are being served.
	Ready

	// Degraded: the wire is up but not healthy — saturated, or answering
	// slowly enough that a caller should be told. Distinguished from
	// Disconnected because the remedy differs: waiting helps, reconnecting
	// does not.
	Degraded

	// Closed: terminal. Close was called; the dispatcher will not recover.
	Closed
)

func (h Health) String() string {
	switch h {
	case Disconnected:
		return "disconnected"
	case Connecting:
		return "connecting"
	case Ready:
		return "ready"
	case Degraded:
		return "degraded"
	case Closed:
		return "closed"
	default:
		return fmt.Sprintf("Health(%d)", int(h))
	}
}

// Live reports whether calls can currently be attempted. Callers branch on this
// rather than comparing against a list of states, so adding a state later does
// not silently change every call site's meaning.
func (h Health) Live() bool { return h == Ready || h == Degraded }
