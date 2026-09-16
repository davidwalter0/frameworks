package transport

import (
	"context"
	"math/rand"
	"time"
)

// Schedule computes the delay before attempt n, counted from 1.
//
// A Schedule is NOT a backoff. It is a pure function of an attempt number —
// it sleeps nothing, retries nothing, and observes nothing. It becomes a
// backoff only when [Retry] drives it.
//
// That distinction is load-bearing here rather than pedantic. An earlier
// revision of this package carried a `Policy.NewBackOff` field supplying a
// schedule, and nothing in the package ever called it: a delay calculator with
// no repetitive code around it is dead weight that reads as a feature. It was
// removed when this file landed, and the shape below — schedule as a
// parameter, loop as the exported thing — is what replaced it.
type Schedule func(attempt int) time.Duration

// ExponentialJitter returns the family's reconnect schedule: base doubled per
// attempt, capped at max, with FULL JITTER over the upper half of the interval.
//
// The jitter is the part worth keeping. Without it, N upstreams that die
// together retry in lockstep and arrive as a thundering herd on the peer that
// just came back; spreading each delay over [d/2, d] decorrelates them. The
// attempt counter is clamped at 10 before the shift, which is not
// defensiveness — 250ms << 10 already exceeds the 30s cap, and a caller that
// loops long enough would otherwise shift into overflow.
//
// Extracted from gatehub-kit's upstream pool, where it ran as `defaultBackoff`
// against real upstreams. It is promoted here as MEASURED code with a consumer,
// not as a guess at what a schedule should look like.
func ExponentialJitter(base, max time.Duration) Schedule {
	return func(attempt int) time.Duration {
		if attempt < 1 {
			attempt = 1
		}
		if attempt > 10 {
			attempt = 10
		}
		d := base * time.Duration(int64(1)<<uint(attempt-1))
		if d > max {
			d = max
		}
		half := d / 2
		return half + time.Duration(rand.Int63n(int64(half)+1))
	}
}

// DefaultSchedule is ExponentialJitter with the values the pool used in
// production: 250ms base, 30s cap.
func DefaultSchedule() Schedule { return ExponentialJitter(250*time.Millisecond, 30*time.Second) }

// Retry is the backoff: the loop that turns a [Schedule] into repeated
// attempts. It calls attempt with a 1-based counter until one returns nil, or
// ctx is done.
//
// It returns nil once an attempt succeeds, or ctx.Err() if the context ends
// first. The last attempt's error is deliberately NOT returned in that case:
// the caller asked to keep trying until told to stop, so "we were told to stop"
// is the outcome, and reporting a transient connect failure instead would make
// a cancelled shutdown look like a transport fault.
//
// The attempt function receives ctx. A caller wanting a per-attempt deadline
// applies it inside — see the pool, which wraps each connect in its own
// timeout so one wedged dial cannot stall the whole retry sequence.
//
// Sleeping happens between attempts, never before the first: attempt 1 runs
// immediately, which is what makes Retry usable on a first connect as well as
// on a reconnect.
func Retry(ctx context.Context, s Schedule, attempt func(ctx context.Context, n int) error) error {
	if s == nil {
		s = DefaultSchedule()
	}
	for n := 1; ; n++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := attempt(ctx, n); err == nil {
			return nil
		}
		t := time.NewTimer(s(n))
		select {
		case <-t.C:
		case <-ctx.Done():
			t.Stop()
			return ctx.Err()
		}
	}
}
