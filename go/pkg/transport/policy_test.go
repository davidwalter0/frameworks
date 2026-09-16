package transport

import (
	"reflect"
	"testing"
	"time"
)

func TestPolicyValidate(t *testing.T) {
	tests := []struct {
		name    string
		pol     Policy
		wantErr bool
	}{
		{"zero is valid (defaults apply)", Policy{}, false},
		{"default policy", DefaultPolicy(), false},
		{"negative MaxInFlight", Policy{MaxInFlight: -1}, true},
		{"negative CallTimeout", Policy{CallTimeout: -time.Second}, true},
		{"unknown overflow", Policy{Overflow: Overflow(99)}, true},
		{"reject is valid", Policy{Overflow: OverflowReject}, false},
		{"drop is valid", Policy{Overflow: OverflowDrop}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.pol.Validate()
			if (err != nil) != tt.wantErr {
				t.Fatalf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

// TestDefaultsAreBounded is the guard against the family's actual default.
// An unbounded queue converts a slow consumer into unbounded memory growth
// instead of a signal, so "unset" must resolve to a FINITE limit — and one
// small enough to be reached in a test, or the overflow path stays unexercised
// until production.
func TestDefaultsAreBounded(t *testing.T) {
	p := Policy{}.withDefaults()
	if p.MaxInFlight <= 0 {
		t.Fatalf("default MaxInFlight = %d; an unset policy must not be unbounded", p.MaxInFlight)
	}
	if p.MaxInFlight > 1024 {
		t.Errorf("default MaxInFlight = %d is too large to ever be observed failing", p.MaxInFlight)
	}
}

// TestPolicyCarriesNoSchedule guards the defect this package already made once.
//
// Policy used to hold a NewBackOff factory that nothing consumed: the
// Dispatcher never called it and no loop existed to drive it. A schedule with
// no repetitive code around it is not a backoff. Reconnect belongs to [Retry],
// which takes its [Schedule] as an argument, so Policy must stay free of it —
// if a future change adds a delay field back here, this test says why not.
func TestPolicyCarriesNoSchedule(t *testing.T) {
	typ := reflect.TypeOf(Policy{})
	for i := 0; i < typ.NumField(); i++ {
		f := typ.Field(i)
		if f.Type == reflect.TypeOf(Schedule(nil)) {
			t.Errorf("Policy.%s is a Schedule; reconnect is a loop (Retry), not a setting", f.Name)
		}
		if f.Name == "CallTimeout" {
			continue // a per-call deadline is a bound, not a retry schedule
		}
		if f.Type == reflect.TypeOf(time.Duration(0)) {
			t.Errorf("Policy.%s is a Duration — if this is a retry delay it belongs in a Schedule", f.Name)
		}
	}
}

func TestOverflowString(t *testing.T) {
	for _, tt := range []struct {
		o    Overflow
		want string
	}{
		{OverflowBlock, "block"},
		{OverflowReject, "reject"},
		{OverflowDrop, "drop"},
	} {
		if got := tt.o.String(); got != tt.want {
			t.Errorf("Overflow(%d).String() = %q, want %q", int(tt.o), got, tt.want)
		}
	}
}

func TestHealthLive(t *testing.T) {
	for _, tt := range []struct {
		h    Health
		want bool
	}{
		{Disconnected, false},
		{Connecting, false},
		{Ready, true},
		{Degraded, true},
		{Closed, false},
	} {
		if got := tt.h.Live(); got != tt.want {
			t.Errorf("%v.Live() = %v, want %v", tt.h, got, tt.want)
		}
	}
}
