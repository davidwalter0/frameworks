package transport

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

// zero is a Schedule with no delay, so loop-behaviour tests measure the loop
// rather than the clock.
func zero() Schedule { return func(int) time.Duration { return 0 } }

// TestRetryRunsFirstAttemptImmediately is why Retry is usable for a FIRST
// connect and not only a reconnect: a loop that slept before attempt 1 would
// add latency to every cold start.
func TestRetryRunsFirstAttemptImmediately(t *testing.T) {
	start := time.Now()
	slow := func(int) time.Duration { return time.Hour }

	err := Retry(context.Background(), slow, func(context.Context, int) error { return nil })
	if err != nil {
		t.Fatalf("Retry: %v", err)
	}
	if d := time.Since(start); d > time.Second {
		t.Fatalf("first attempt waited %s; it must run immediately", d)
	}
}

// TestRetryCountsAttemptsFromOne pins the contract the Schedule depends on.
// An off-by-one here silently shifts every delay one step down the curve.
func TestRetryCountsAttemptsFromOne(t *testing.T) {
	var seen []int
	err := Retry(context.Background(), zero(), func(_ context.Context, n int) error {
		seen = append(seen, n)
		if n == 3 {
			return nil
		}
		return errors.New("not yet")
	})
	if err != nil {
		t.Fatalf("Retry: %v", err)
	}
	want := []int{1, 2, 3}
	if len(seen) != len(want) {
		t.Fatalf("attempts = %v, want %v", seen, want)
	}
	for i := range want {
		if seen[i] != want[i] {
			t.Fatalf("attempts = %v, want %v", seen, want)
		}
	}
}

// TestRetryStopsOnContextAndReportsCancellation covers the deliberate choice
// NOT to return the last attempt's error: the caller asked to keep trying
// until told to stop, so a cancelled shutdown must not read as a transport
// fault.
func TestRetryStopsOnContextAndReportsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	var calls atomic.Int64
	attemptErr := errors.New("connect refused")

	done := make(chan error, 1)
	go func() {
		done <- Retry(ctx, zero(), func(context.Context, int) error {
			if calls.Add(1) == 3 {
				cancel()
			}
			return attemptErr
		})
	}()

	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("got %v, want context.Canceled", err)
		}
		if errors.Is(err, attemptErr) {
			t.Error("returned the attempt error; a cancelled retry is not a transport failure")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Retry did not stop when its context was cancelled")
	}
}

// TestRetryDoesNotAttemptWithAnAlreadyDeadContext: a caller shutting down must
// not have one more connection opened on its way out.
func TestRetryDoesNotAttemptWithAnAlreadyDeadContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	var calls atomic.Int64
	err := Retry(ctx, zero(), func(context.Context, int) error {
		calls.Add(1)
		return nil
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v, want context.Canceled", err)
	}
	if n := calls.Load(); n != 0 {
		t.Errorf("attempted %d times with a dead context; want 0", n)
	}
}

// TestRetryHonoursTheSchedule proves the Schedule is actually driven — the
// whole point of the split. A loop that ignored it would pass every other test
// here.
func TestRetryHonoursTheSchedule(t *testing.T) {
	const delay = 60 * time.Millisecond
	var asked []int
	s := func(n int) time.Duration {
		asked = append(asked, n)
		return delay
	}

	start := time.Now()
	err := Retry(context.Background(), s, func(_ context.Context, n int) error {
		if n == 3 {
			return nil
		}
		return errors.New("again")
	})
	if err != nil {
		t.Fatalf("Retry: %v", err)
	}
	// Two sleeps: after attempt 1 and after attempt 2.
	if elapsed := time.Since(start); elapsed < 2*delay {
		t.Errorf("elapsed %s < 2x%s; the schedule was not driven", elapsed, delay)
	}
	if len(asked) != 2 || asked[0] != 1 || asked[1] != 2 {
		t.Errorf("schedule consulted with %v, want [1 2]", asked)
	}
}

// TestRetryNilScheduleFallsBack keeps a zero-value caller from panicking.
func TestRetryNilScheduleFallsBack(t *testing.T) {
	err := Retry(context.Background(), nil, func(context.Context, int) error { return nil })
	if err != nil {
		t.Fatalf("Retry with nil schedule: %v", err)
	}
}

// TestExponentialJitterStaysInItsHalfInterval checks the property the jitter
// exists for: every delay lands in [d/2, d] for that attempt's d, so N peers
// dying together do not retry in lockstep.
func TestExponentialJitterStaysInItsHalfInterval(t *testing.T) {
	const (
		base = 100 * time.Millisecond
		max  = 2 * time.Second
	)
	s := ExponentialJitter(base, max)

	for attempt := 1; attempt <= 12; attempt++ {
		d := base * time.Duration(int64(1)<<uint(min(attempt, 10)-1))
		if d > max {
			d = max
		}
		lo, hi := d/2, d
		for i := 0; i < 200; i++ {
			got := s(attempt)
			if got < lo || got > hi {
				t.Fatalf("attempt %d: %s outside [%s, %s]", attempt, got, lo, hi)
			}
		}
	}
}

// TestExponentialJitterActuallyJitters: a schedule returning a constant would
// satisfy the bounds test above while defeating the entire purpose.
func TestExponentialJitterActuallyJitters(t *testing.T) {
	s := ExponentialJitter(100*time.Millisecond, time.Minute)
	first := s(5)
	for i := 0; i < 500; i++ {
		if s(5) != first {
			return
		}
	}
	t.Fatal("500 samples identical; the delay is not jittered, so peers will retry in lockstep")
}

// TestExponentialJitterCapsAndClamps covers the two guards: the cap, and the
// attempt clamp that keeps the shift out of overflow.
func TestExponentialJitterCapsAndClamps(t *testing.T) {
	const max = 5 * time.Second
	s := ExponentialJitter(250*time.Millisecond, max)

	for _, attempt := range []int{0, -7, 1, 40, 1 << 20} {
		got := s(attempt)
		if got < 0 {
			t.Errorf("attempt %d produced a negative delay %s — the shift overflowed", attempt, got)
		}
		if got > max {
			t.Errorf("attempt %d produced %s, above the %s cap", attempt, got, max)
		}
	}
}

// TestDefaultScheduleMatchesThePoolValues documents where the numbers came
// from: gatehub-kit's upstream pool ran 250ms base / 30s cap in production.
func TestDefaultScheduleMatchesThePoolValues(t *testing.T) {
	s := DefaultSchedule()
	if d := s(1); d < 125*time.Millisecond || d > 250*time.Millisecond {
		t.Errorf("attempt 1 = %s, want within [125ms, 250ms]", d)
	}
	if d := s(99); d < 15*time.Second || d > 30*time.Second {
		t.Errorf("capped attempt = %s, want within [15s, 30s]", d)
	}
}
