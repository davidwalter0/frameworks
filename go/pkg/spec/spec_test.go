package spec

import (
	"strings"
	"testing"
)

func TestParseUnitKind(t *testing.T) {
	for _, k := range AllUnitKinds {
		got, err := ParseUnitKind(string(k))
		if err != nil || got != k {
			t.Errorf("ParseUnitKind(%q) = %v, %v", k, got, err)
		}
	}
	// A typo must fail by name. Silently accepting it would install zero
	// units and report success.
	_, err := ParseUnitKind("sevice")
	if err == nil {
		t.Fatal("expected an error for a typo")
	}
	if !strings.Contains(err.Error(), "sevice") || !strings.Contains(err.Error(), "service") {
		t.Errorf("error should name the typo and the valid set; got %v", err)
	}
}

func TestParseScope(t *testing.T) {
	for _, s := range []Scope{ScopeUser, ScopeSystem} {
		got, err := ParseScope(string(s))
		if err != nil || got != s {
			t.Errorf("ParseScope(%q) = %v, %v", s, got, err)
		}
	}
	if _, err := ParseScope("root"); err == nil {
		t.Error("expected an error for an unknown scope")
	}
}

func TestUnitsOfKinds(t *testing.T) {
	s := Spec{Units: []Unit{
		{Kind: KindService, Stem: "a"},
		{Kind: KindSocket, Stem: "a"},
		{Kind: KindTimer, Stem: "b"},
	}}

	// No filter means "whatever the payload ships".
	if got := len(s.UnitsOfKinds(nil)); got != 3 {
		t.Errorf("nil filter = %d units, want 3", got)
	}
	got := s.UnitsOfKinds([]UnitKind{KindSocket, KindTimer})
	if len(got) != 2 || got[0].Kind != KindSocket || got[1].Kind != KindTimer {
		t.Errorf("filtered = %v", got)
	}
	// Spec order is preserved, not filter order.
	got = s.UnitsOfKinds([]UnitKind{KindTimer, KindSocket})
	if got[0].Kind != KindSocket {
		t.Errorf("Spec order should win, got %v first", got[0].Kind)
	}
	if len(s.UnitsOfKinds([]UnitKind{KindMount})) != 0 {
		t.Error("a kind the payload does not ship yields nothing")
	}
}

func TestTokenNamesAreSorted(t *testing.T) {
	s := Spec{Tokens: map[string]string{"Z": "1", "A": "2", "M": "3"}}
	got := s.TokenNames()
	want := []string{"A", "M", "Z"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("TokenNames() = %v, want %v", got, want)
		}
	}
}

func TestDesktopFileName(t *testing.T) {
	for _, tc := range []struct {
		name string
		s    Spec
		want string
	}{
		// The AppID name is the Wayland-correct default; the bare-App
		// fallback serves daemons with no desktop presence.
		{"app fallback", Spec{App: "demo"}, "demo.desktop"},
		{"app-id wins", Spec{App: "demo", AppID: "com.example.Demo"}, "com.example.Demo.desktop"},
		{"explicit override", Spec{App: "demo", AppID: "com.example.Demo", DesktopName: "legacy.desktop"}, "legacy.desktop"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.s.DesktopFileName(); got != tc.want {
				t.Errorf("DesktopFileName() = %q, want %q", got, tc.want)
			}
		})
	}
}
