package transport

import (
	"context"
	"fmt"
	"strconv"
	"sync"
	"sync/atomic"
)

// Dispatcher provides correlated, concurrent request/response over any [Wire].
//
// It is the piece the census says is missing: of the 6,379 forked lines, this
// is the part every app rewrote — issue a request, match a reply to it, do not
// let one slow reply stall the others, and give up cleanly when the caller
// cancels.
//
// Concurrency model, stated because adapters depend on it:
//   - Send is serialized by a mutex, so a Wire needs no internal locking.
//   - Exactly one goroutine calls Recv, for the dispatcher's whole life.
//   - Call is safe from any number of goroutines.
type Dispatcher struct {
	wire Wire
	pol  Policy

	// slots is the in-flight semaphore. Its capacity IS MaxInFlight; acquiring
	// is what makes the concurrency policy real rather than advisory.
	slots chan struct{}

	sendMu sync.Mutex

	mu      sync.Mutex
	pending map[string]chan Frame

	seq    atomic.Uint64
	health atomic.Int32

	onNotify func(Frame)

	closeOnce sync.Once
	closed    chan struct{}
	loopDone  chan struct{}

	errMu   sync.Mutex
	loopErr error
}

// Option configures a Dispatcher at construction.
type Option func(*Dispatcher)

// OnNotify registers a handler for inbound notifications (frames with no ID).
// It runs on the read loop goroutine, so it must not block: a handler that
// blocks stalls every reply behind it, which is the exact head-of-line problem
// this package exists to avoid.
func OnNotify(fn func(Frame)) Option {
	return func(d *Dispatcher) { d.onNotify = fn }
}

// New wraps a Wire. The policy is validated here so a malformed one fails at
// construction rather than at first saturation.
func New(w Wire, p Policy, opts ...Option) (*Dispatcher, error) {
	if w == nil {
		return nil, fmt.Errorf("transport: nil Wire")
	}
	if err := p.Validate(); err != nil {
		return nil, err
	}
	p = p.withDefaults()

	d := &Dispatcher{
		wire:     w,
		pol:      p,
		slots:    make(chan struct{}, p.MaxInFlight),
		pending:  make(map[string]chan Frame),
		closed:   make(chan struct{}),
		loopDone: make(chan struct{}),
	}
	for _, o := range opts {
		o(d)
	}
	d.health.Store(int32(Ready))
	go d.readLoop()
	return d, nil
}

// Health reports the current liveness state.
func (d *Dispatcher) Health() Health { return Health(d.health.Load()) }

// InFlight reports how many calls are currently outstanding. Exported because
// a saturation policy that cannot be observed cannot be tuned — and because it
// is what makes the overflow tests assert on state rather than on timing.
func (d *Dispatcher) InFlight() int { return len(d.slots) }

// Call issues a request and waits for its correlated reply.
//
// Safe for concurrent use: N callers may have N requests outstanding on one
// wire, and replies may arrive in ANY order. That is the whole point — a large
// reply must not stall the small ones queued behind it beyond the transport's
// own framing.
func (d *Dispatcher) Call(ctx context.Context, method string, body []byte) ([]byte, error) {
	if err := d.acquire(ctx); err != nil {
		return nil, err
	}
	defer d.release()

	if d.pol.CallTimeout > 0 {
		if _, hasDeadline := ctx.Deadline(); !hasDeadline {
			var cancel context.CancelFunc
			ctx, cancel = context.WithTimeout(ctx, d.pol.CallTimeout)
			defer cancel()
		}
	}

	id := strconv.FormatUint(d.seq.Add(1), 10)
	reply := make(chan Frame, 1)

	d.mu.Lock()
	select {
	case <-d.closed:
		d.mu.Unlock()
		return nil, ErrClosed
	default:
	}
	d.pending[id] = reply
	d.mu.Unlock()

	// Always retire the correlation entry. Without this a cancelled call leaks
	// a map entry and a channel for the dispatcher's lifetime — a slow leak
	// that only shows under exactly the load this package is meant to handle.
	defer func() {
		d.mu.Lock()
		delete(d.pending, id)
		d.mu.Unlock()
	}()

	if err := d.send(ctx, Frame{ID: id, Method: method, Body: body}); err != nil {
		return nil, err
	}

	select {
	case f := <-reply:
		if f.Err != nil {
			return nil, f.Err
		}
		return f.Body, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-d.closed:
		return nil, ErrClosed
	case <-d.loopDone:
		return nil, d.loopError()
	}
}

// Notify sends a fire-and-forget message. No reply is awaited and no in-flight
// slot is held beyond the send itself.
//
// Under [OverflowDrop] a saturated dispatcher discards the notification and
// returns nil: dropping a progress tick is the documented, deliberate choice
// that keeps a hot path unblocked, and it is not an error.
func (d *Dispatcher) Notify(ctx context.Context, method string, body []byte) error {
	if err := d.acquire(ctx); err != nil {
		if d.pol.Overflow == OverflowDrop && err == ErrOverflow {
			return nil
		}
		return err
	}
	defer d.release()
	return d.send(ctx, Frame{Method: method, Body: body})
}

// acquire takes an in-flight slot according to the overflow policy. This is
// where backpressure becomes real: with no limit, a slow peer turns into
// unbounded memory growth instead of a signal.
func (d *Dispatcher) acquire(ctx context.Context) error {
	select {
	case <-d.closed:
		return ErrClosed
	default:
	}

	switch d.pol.Overflow {
	case OverflowReject, OverflowDrop:
		select {
		case d.slots <- struct{}{}:
			return nil
		default:
			// Saturated. Report it rather than silently queueing.
			d.health.CompareAndSwap(int32(Ready), int32(Degraded))
			return ErrOverflow
		}
	default: // OverflowBlock
		select {
		case d.slots <- struct{}{}:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		case <-d.closed:
			return ErrClosed
		}
	}
}

func (d *Dispatcher) release() {
	select {
	case <-d.slots:
	default:
	}
	// Recovering from Degraded is only correct once there is genuine headroom;
	// flapping the state on every release would make it useless to a UI.
	if len(d.slots) == 0 {
		d.health.CompareAndSwap(int32(Degraded), int32(Ready))
	}
}

func (d *Dispatcher) send(ctx context.Context, f Frame) error {
	d.sendMu.Lock()
	defer d.sendMu.Unlock()
	return d.wire.Send(ctx, f)
}

// readLoop owns the only Recv caller. It routes each reply to the waiting
// caller by ID and never blocks on a caller that has gone away — a reply
// channel is buffered with capacity 1 and the send is non-blocking, so a
// cancelled call cannot wedge the loop and stall every other reply.
func (d *Dispatcher) readLoop() {
	defer close(d.loopDone)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		select {
		case <-d.closed:
			cancel()
		case <-ctx.Done():
		}
	}()

	for {
		f, err := d.wire.Recv(ctx)
		if err != nil {
			d.setLoopErr(err)
			d.failAllPending(err)
			// Closed is TERMINAL and must win. Close() tears the wire down on
			// purpose, so this loop always observes a Recv error on the way
			// out; storing Disconnected unconditionally would overwrite the
			// deliberate state with an incidental one, and a consumer would
			// see a closed dispatcher advertising itself as merely
			// disconnected — i.e. as something worth reconnecting.
			d.setHealthUnlessClosed(Disconnected)
			return
		}

		if f.IsNotification() {
			if d.onNotify != nil {
				d.onNotify(f)
			}
			continue
		}

		d.mu.Lock()
		ch, ok := d.pending[f.ID]
		d.mu.Unlock()
		if !ok {
			// A reply for an ID nobody is waiting on: the call was cancelled or
			// timed out. Dropping it is correct, and it is NOT an error — but
			// it must not be silent to the loop, hence the explicit branch.
			continue
		}
		select {
		case ch <- f:
		default:
		}
	}
}

func (d *Dispatcher) failAllPending(err error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for id, ch := range d.pending {
		select {
		case ch <- Frame{ID: id, Err: err}:
		default:
		}
	}
}

// setHealthUnlessClosed moves health to h unless the dispatcher has already
// reached its terminal Closed state.
func (d *Dispatcher) setHealthUnlessClosed(h Health) {
	for {
		cur := d.health.Load()
		if cur == int32(Closed) {
			return
		}
		if d.health.CompareAndSwap(cur, int32(h)) {
			return
		}
	}
}

func (d *Dispatcher) setLoopErr(err error) {
	d.errMu.Lock()
	defer d.errMu.Unlock()
	if d.loopErr == nil {
		d.loopErr = err
	}
}

func (d *Dispatcher) loopError() error {
	d.errMu.Lock()
	defer d.errMu.Unlock()
	if d.loopErr == nil {
		return ErrClosed
	}
	return d.loopErr
}

// Close terminates the dispatcher and its read loop. It is idempotent, and safe
// to call while calls are outstanding: those calls return [ErrClosed] rather
// than hanging.
func (d *Dispatcher) Close() error {
	var err error
	d.closeOnce.Do(func() {
		d.health.Store(int32(Closed))
		close(d.closed)
		err = d.wire.Close()
		<-d.loopDone
	})
	return err
}
