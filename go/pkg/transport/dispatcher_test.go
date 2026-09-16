package transport

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"
)

// fakeWire is a controllable Wire. Replies are injected by the test rather than
// generated on send, so reply ORDER is under the test's control — which is the
// only way to assert that correlation does not depend on it.
type fakeWire struct {
	mu     sync.Mutex
	sent   []Frame
	inbox  chan Frame
	closed chan struct{}
	once   sync.Once

	// onSend runs after each send, off the caller's goroutine.
	onSend func(f Frame, w *fakeWire)
}

func newFakeWire() *fakeWire {
	return &fakeWire{
		inbox:  make(chan Frame, 256),
		closed: make(chan struct{}),
	}
}

func (w *fakeWire) Send(ctx context.Context, f Frame) error {
	select {
	case <-w.closed:
		return errors.New("wire closed")
	default:
	}
	w.mu.Lock()
	w.sent = append(w.sent, f)
	fn := w.onSend
	w.mu.Unlock()
	if fn != nil {
		go fn(f, w)
	}
	return nil
}

// setOnSend installs an auto-responder. Guarded because tests install it
// mid-flight, and an unguarded field would be a genuine race even though the
// ordering happens to be safe.
func (w *fakeWire) setOnSend(fn func(Frame, *fakeWire)) {
	w.mu.Lock()
	w.onSend = fn
	w.mu.Unlock()
}

func (w *fakeWire) Recv(ctx context.Context) (Frame, error) {
	select {
	case f := <-w.inbox:
		return f, nil
	case <-w.closed:
		return Frame{}, errors.New("wire closed")
	case <-ctx.Done():
		return Frame{}, ctx.Err()
	}
}

func (w *fakeWire) Close() error {
	w.once.Do(func() { close(w.closed) })
	return nil
}

func (w *fakeWire) reply(f Frame) { w.inbox <- f }

func (w *fakeWire) sentCount() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.sent)
}

// TestCallsCorrelateWhenRepliesArriveOutOfOrder is the core claim of parallel
// dispatch: N requests in flight on ONE wire, replies delivered in an order
// unrelated to the request order, and every caller still gets its own answer.
//
// Replies are deliberately sent in REVERSE, so an implementation that quietly
// assumed FIFO would hand every caller the wrong body and fail loudly here.
func TestCallsCorrelateWhenRepliesArriveOutOfOrder(t *testing.T) {
	w := newFakeWire()
	d, err := New(w, Policy{MaxInFlight: 16})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer closeDispatcher(t, d)

	const n = 8
	var wg sync.WaitGroup
	got := make([]string, n)
	errs := make([]error, n)

	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			body, err := d.Call(context.Background(), "echo", []byte(fmt.Sprintf("req-%d", i)))
			got[i], errs[i] = string(body), err
		}(i)
	}

	// Wait until all N are on the wire, so the replies below are genuinely
	// concurrent rather than accidentally serialized.
	waitFor(t, func() bool { return w.sentCount() == n }, "all calls sent")

	w.mu.Lock()
	sent := append([]Frame(nil), w.sent...)
	w.mu.Unlock()

	for i := len(sent) - 1; i >= 0; i-- {
		w.reply(Frame{ID: sent[i].ID, Body: []byte("reply-for-" + string(sent[i].Body))})
	}

	wg.Wait()
	for i := 0; i < n; i++ {
		if errs[i] != nil {
			t.Fatalf("call %d: %v", i, errs[i])
		}
		want := fmt.Sprintf("reply-for-req-%d", i)
		if got[i] != want {
			t.Errorf("call %d got %q, want %q — replies were mis-correlated", i, got[i], want)
		}
	}
}

// TestSlowReplyDoesNotStallOthers asserts the dispatcher does not impose
// head-of-line blocking of its own. The first call's reply is withheld; every
// later call must still complete.
//
// This is the property that makes multiplexing worth having: on a single byte
// stream a large response stalls what is queued behind it, and the plumbing
// layer must not ADD a second serialization on top of that.
func TestSlowReplyDoesNotStallOthers(t *testing.T) {
	w := newFakeWire()
	d, err := New(w, Policy{MaxInFlight: 8})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer closeDispatcher(t, d)

	slowDone := make(chan struct{})
	go func() {
		defer close(slowDone)
		_, _ = d.Call(context.Background(), "big", []byte("huge"))
	}()
	waitFor(t, func() bool { return w.sentCount() == 1 }, "slow call sent")

	const n = 4
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if _, err := d.Call(context.Background(), "small", []byte("s")); err != nil {
				t.Errorf("small call %d: %v", i, err)
			}
		}(i)
	}
	waitFor(t, func() bool { return w.sentCount() == n+1 }, "small calls sent")

	// Answer ONLY the small ones. The big call stays outstanding.
	w.mu.Lock()
	sent := append([]Frame(nil), w.sent...)
	w.mu.Unlock()
	for _, f := range sent[1:] {
		w.reply(Frame{ID: f.ID, Body: []byte("ok")})
	}

	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("small calls did not complete while a slow reply was outstanding — the dispatcher is serializing")
	}

	select {
	case <-slowDone:
		t.Fatal("slow call returned early; test did not exercise what it claims")
	default:
	}

	w.reply(Frame{ID: sent[0].ID, Body: []byte("finally")})
	<-slowDone
}

// TestOverflowRejectFires proves the concurrency policy is real. A limit that
// is never observed to reject is indistinguishable from no limit at all.
func TestOverflowRejectFires(t *testing.T) {
	w := newFakeWire()
	d, err := New(w, Policy{MaxInFlight: 2, Overflow: OverflowReject})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer closeDispatcher(t, d)

	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, _ = d.Call(context.Background(), "hold", nil) }()
	}
	waitFor(t, func() bool { return d.InFlight() == 2 }, "limit reached")

	_, err = d.Call(context.Background(), "third", nil)
	if !errors.Is(err, ErrOverflow) {
		t.Fatalf("third call: got %v, want ErrOverflow", err)
	}
	if h := d.Health(); h != Degraded {
		t.Errorf("health after saturation = %v, want degraded — saturation must be observable", h)
	}

	w.mu.Lock()
	sent := append([]Frame(nil), w.sent...)
	w.mu.Unlock()
	for _, f := range sent {
		w.reply(Frame{ID: f.ID, Body: []byte("ok")})
	}
	wg.Wait()

	waitFor(t, func() bool { return d.Health() == Ready }, "health recovers once drained")
}

// TestOverflowBlockWaitsForASlot is the default policy: backpressure reaches
// the caller instead of a queue growing without bound.
func TestOverflowBlockWaitsForASlot(t *testing.T) {
	w := newFakeWire()
	d, err := New(w, Policy{MaxInFlight: 1, Overflow: OverflowBlock})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer closeDispatcher(t, d)

	first := make(chan struct{})
	go func() { defer close(first); _, _ = d.Call(context.Background(), "first", nil) }()
	waitFor(t, func() bool { return d.InFlight() == 1 }, "first in flight")

	secondStarted := make(chan struct{})
	secondDone := make(chan struct{})
	go func() {
		close(secondStarted)
		defer close(secondDone)
		_, _ = d.Call(context.Background(), "second", nil)
	}()
	<-secondStarted

	select {
	case <-secondDone:
		t.Fatal("second call proceeded past a full in-flight limit — the limit is not enforced")
	case <-time.After(150 * time.Millisecond):
	}

	if w.sentCount() != 1 {
		t.Fatalf("blocked call was sent anyway: %d frames on the wire, want 1", w.sentCount())
	}

	w.mu.Lock()
	id := w.sent[0].ID
	w.mu.Unlock()
	w.reply(Frame{ID: id, Body: []byte("ok")})
	<-first

	waitFor(t, func() bool { return w.sentCount() == 2 }, "second call proceeds after a slot frees")
	w.mu.Lock()
	id2 := w.sent[1].ID
	w.mu.Unlock()
	w.reply(Frame{ID: id2, Body: []byte("ok")})
	<-secondDone
}

// TestOverflowDropDiscardsNotifications: dropping a tick is the deliberate
// choice that keeps a hot path unblocked, and it is not an error.
func TestOverflowDropDiscardsNotifications(t *testing.T) {
	w := newFakeWire()
	d, err := New(w, Policy{MaxInFlight: 1, Overflow: OverflowDrop})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer closeDispatcher(t, d)

	go func() { _, _ = d.Call(context.Background(), "hold", nil) }()
	waitFor(t, func() bool { return d.InFlight() == 1 }, "saturated")

	before := w.sentCount()
	if err := d.Notify(context.Background(), "tick", nil); err != nil {
		t.Fatalf("dropped notification must not be an error, got %v", err)
	}
	if got := w.sentCount(); got != before {
		t.Errorf("notification was sent despite drop policy: %d -> %d", before, got)
	}

	// A Call, by contrast, cannot be dropped — the caller is waiting.
	if _, err := d.Call(context.Background(), "c", nil); !errors.Is(err, ErrOverflow) {
		t.Errorf("Call under drop policy: got %v, want ErrOverflow", err)
	}
}

// TestCancelledCallReleasesItsSlotAndCorrelation guards the leak that only
// appears under the load this package exists to serve.
func TestCancelledCallReleasesItsSlotAndCorrelation(t *testing.T) {
	w := newFakeWire()
	d, err := New(w, Policy{MaxInFlight: 4})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer closeDispatcher(t, d)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { _, e := d.Call(ctx, "doomed", nil); done <- e }()
	waitFor(t, func() bool { return d.InFlight() == 1 }, "call in flight")

	cancel()
	if e := <-done; !errors.Is(e, context.Canceled) {
		t.Fatalf("cancelled call: got %v, want context.Canceled", e)
	}
	waitFor(t, func() bool { return d.InFlight() == 0 }, "slot released on cancel")

	d.mu.Lock()
	n := len(d.pending)
	d.mu.Unlock()
	if n != 0 {
		t.Errorf("pending correlation entries after cancel = %d, want 0 (leak)", n)
	}

	// A late reply for an id nobody is waiting on must be harmless. The read
	// loop has to survive it: dropping it is correct, wedging on it is not.
	w.mu.Lock()
	id := w.sent[0].ID
	w.mu.Unlock()
	w.reply(Frame{ID: id, Body: []byte("late")})

	// Prove the dispatcher still works AFTER swallowing that orphan reply, by
	// completing a fresh call end to end. This must be a call that actually
	// gets answered — an unanswered one would simply block forever and turn a
	// correctness test into a hang.
	w.setOnSend(func(f Frame, wi *fakeWire) { wi.reply(Frame{ID: f.ID, Body: []byte("pong")}) })
	body, err := d.Call(context.Background(), "after", nil)
	if err != nil {
		t.Fatalf("dispatcher unusable after an orphan reply: %v", err)
	}
	if string(body) != "pong" {
		t.Errorf("got %q, want %q", body, "pong")
	}
}

// TestCloseUnblocksOutstandingCalls: shutdown must not hang.
func TestCloseUnblocksOutstandingCalls(t *testing.T) {
	w := newFakeWire()
	d, err := New(w, Policy{MaxInFlight: 4})
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	done := make(chan error, 1)
	go func() { _, e := d.Call(context.Background(), "hangs", nil); done <- e }()
	waitFor(t, func() bool { return d.InFlight() == 1 }, "call in flight")

	if err := d.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	select {
	case e := <-done:
		if e == nil {
			t.Fatal("outstanding call returned nil error after Close")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Close did not unblock an outstanding call")
	}
	if h := d.Health(); h != Closed {
		t.Errorf("health after Close = %v, want closed", h)
	}
	if err := d.Close(); err != nil {
		t.Errorf("Close must be idempotent, second call: %v", err)
	}
}

// TestNotificationsReachTheHandler covers the no-reply path.
func TestNotificationsReachTheHandler(t *testing.T) {
	w := newFakeWire()
	got := make(chan Frame, 1)
	d, err := New(w, DefaultPolicy(), OnNotify(func(f Frame) { got <- f }))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer closeDispatcher(t, d)

	w.reply(Frame{Method: "progress", Body: []byte("50%")})
	select {
	case f := <-got:
		if f.Method != "progress" || string(f.Body) != "50%" {
			t.Errorf("handler got %v", f)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("notification never reached the handler")
	}
}

// TestPeerErrorIsDistinctFromPlumbingError: a protocol-level failure must not
// look like a transport failure, or a caller cannot tell "retry" from "fix".
func TestPeerErrorIsDistinctFromPlumbingError(t *testing.T) {
	w := newFakeWire()
	peerErr := errors.New("method not found")
	w.setOnSend(func(f Frame, wi *fakeWire) { wi.reply(Frame{ID: f.ID, Err: peerErr}) })

	d, err := New(w, DefaultPolicy())
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer closeDispatcher(t, d)

	_, err = d.Call(context.Background(), "nope", nil)
	if !errors.Is(err, peerErr) {
		t.Fatalf("got %v, want the peer error", err)
	}
	if errors.Is(err, ErrClosed) || errors.Is(err, ErrOverflow) {
		t.Error("peer error was conflated with a plumbing error")
	}
}

// closeDispatcher tears d down in a defer. The error is discarded deliberately,
// not carelessly: Close's behaviour is asserted explicitly where it is the
// subject (TestCloseUnblocksOutstandingCalls), and failing a test during
// teardown elsewhere would mask whichever assertion actually broke.
func closeDispatcher(t *testing.T, d *Dispatcher) {
	t.Helper()
	_ = d.Close()
}

func waitFor(t *testing.T, cond func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for: %s", what)
}
