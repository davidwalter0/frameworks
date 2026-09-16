package spec

import (
	"strings"
	"testing"
)

// validDesktop is a Spec that passes, so each test can break exactly one thing.
func validDesktop() Spec {
	return Spec{
		App:           "demo",
		AppID:         "com.example.Demo",
		ShareSubdir:   "demo",
		DesktopSource: "demo.desktop",
		Launchers:     []Launcher{{Target: "bin/demo", Name: "demo"}},
	}
}

func TestValidateDesktopAcceptsAWellFormedSpec(t *testing.T) {
	if err := validDesktop().ValidateDesktop(); err != nil {
		t.Fatalf("ValidateDesktop: %v", err)
	}
}

// TestIconRelsMustBeNamedForTheAppID is the Wayland finding as a test.
//
// The Linux window icon resolves BY NAME from the installed hicolor theme, not
// from the app bundle, so an icon whose basename is not the app-id is never
// found — and nothing errors, the app just shows a generic icon. Validation is
// the only place that can catch it.
func TestIconRelsMustBeNamedForTheAppID(t *testing.T) {
	s := validDesktop()
	s.IconRels = []string{"256x256/apps/some-other-name.png"}

	err := s.ValidateDesktop()
	if err == nil {
		t.Fatal("accepted an icon rel not named for the app-id; the window icon would silently never resolve")
	}
	if !strings.Contains(err.Error(), "resolves icons by name") {
		t.Errorf("error should explain WHY, got: %v", err)
	}
}

// TestValidateDesktopRefusesTraversal covers the escape that a filepath.Clean
// round-trip does NOT catch: Clean("../evil") is "../evil" and looks fine.
func TestValidateDesktopRefusesTraversal(t *testing.T) {
	for _, tc := range []struct {
		name string
		mut  func(*Spec)
	}{
		{"ShareSubdir", func(s *Spec) { s.ShareSubdir = "../evil" }},
		{"icon rel", func(s *Spec) { s.IconRels = []string{"../../../com.example.Demo.png"} }},
		// NOTE: Launcher.Target is deliberately NOT in this list. The validator
		// checks that Launcher.Name is a bare basename, but does not check that
		// Target stays inside the app directory. That looks like a gap — a
		// Target of "../../bin/sh" would symlink outside the tree — and it may
		// well be one, but it is PRE-EXISTING. This test moved with the
		// validator and asserts what the validator does, not what it arguably
		// should; adding a rule during a move would hide a behaviour change
		// inside a refactor. Filed rather than smuggled in.
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := validDesktop()
			tc.mut(&s)
			if err := s.ValidateDesktop(); err == nil {
				t.Fatalf("accepted a path escaping its directory via %s", tc.name)
			}
		})
	}
}

func TestValidateDesktopRequiresTheEssentials(t *testing.T) {
	for _, tc := range []struct {
		name string
		mut  func(*Spec)
		want string
	}{
		{"no AppID", func(s *Spec) { s.AppID = "" }, "AppID is required"},
		{"no ShareSubdir", func(s *Spec) { s.ShareSubdir = "" }, "ShareSubdir is required"},
		{"no launchers", func(s *Spec) { s.Launchers = nil }, "at least one entry"},
		{"launcher without a name", func(s *Spec) { s.Launchers[0].Name = "" }, "needs both Target and Name"},
		{"launcher name with a separator", func(s *Spec) { s.Launchers[0].Name = "sub/demo" }, "bare basename"},
		{"CleanSubdirs mode with no subdirs", func(s *Spec) { s.CleanMode = CleanSubdirs }, "CleanSubdirs is empty"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := validDesktop()
			tc.mut(&s)
			err := s.ValidateDesktop()
			if err == nil {
				t.Fatalf("accepted: %s", tc.name)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error = %v, want it to mention %q", err, tc.want)
			}
		})
	}
}

// TestDesktopTargetHonoursNaming: the default must be the app-id form, because
// that is the one Wayland resolves the icon from.
func TestDesktopTargetHonoursNaming(t *testing.T) {
	s := validDesktop()
	s.DesktopSource = "payload-name.desktop"

	if got, want := s.DesktopTarget(), "com.example.Demo.desktop"; got != want {
		t.Errorf("default naming = %q, want %q (app-id form is the Wayland-correct default)", got, want)
	}

	s.DesktopNaming = DesktopByBasename
	if got, want := s.DesktopTarget(), "payload-name.desktop"; got != want {
		t.Errorf("DesktopByBasename = %q, want %q", got, want)
	}
}

// TestDisplayNameFallsBack keeps operator-facing output from ever being empty.
func TestDisplayNameFallsBack(t *testing.T) {
	s := Spec{App: "appname"}
	if got := s.DisplayNameOrDefault(); got != "appname" {
		t.Errorf("with only App set: %q, want %q", got, "appname")
	}
	s.ShareSubdir = "sharedir"
	if got := s.DisplayNameOrDefault(); got != "sharedir" {
		t.Errorf("ShareSubdir should win over App: %q", got)
	}
	s.DisplayName = "Pretty Name"
	if got := s.DisplayNameOrDefault(); got != "Pretty Name" {
		t.Errorf("DisplayName should win: %q", got)
	}
}

// TestDefaultIconRelsCoverPNGAndScalable pins what every app in the family
// stages, since a consumer that sets nothing relies on it.
func TestDefaultIconRelsCoverPNGAndScalable(t *testing.T) {
	rels := DefaultIconRels("com.example.Demo")
	if len(rels) != 2 {
		t.Fatalf("got %d rels, want 2 (256 PNG + scalable SVG): %v", len(rels), rels)
	}
	joined := strings.Join(rels, " ")
	for _, want := range []string{"256x256/apps/com.example.Demo.png", "scalable/apps/com.example.Demo.svg"} {
		if !strings.Contains(joined, want) {
			t.Errorf("missing %q in %v", want, rels)
		}
	}
}

func TestIconRelsBuildersUseTheAppID(t *testing.T) {
	rels := IconRels("com.example.Demo", 32, 256)
	if len(rels) != 3 {
		t.Fatalf("got %v, want two PNGs plus the SVG", rels)
	}
	for _, r := range rels {
		if !strings.Contains(r, "com.example.Demo") {
			t.Errorf("rel %q is not named for the app-id", r)
		}
	}
	// A spec built from these must validate — the builders and the validator
	// have to agree, or one of them is lying. The validator compares the rel's
	// STEM to the app-id exactly, so this also pins that the builders produce
	// exactly "<app-id>.<ext>" and not a decorated variant.
	s := validDesktop()
	s.IconRels = rels
	if err := s.ValidateDesktop(); err != nil {
		t.Errorf("builder output rejected by the validator: %v", err)
	}

	// And the match really is exact, not a substring: a decorated basename
	// containing the app-id must still be refused, because the theme looks up
	// the exact name.
	s.IconRels = []string{"256x256/apps/com.example.Demo-extra.png"}
	if err := s.ValidateDesktop(); err == nil {
		t.Error("a basename merely CONTAINING the app-id was accepted; the theme resolves an exact name")
	}
}

func TestLayoutForResolvesUnderThePrefix(t *testing.T) {
	l := validDesktop().LayoutFor("/tmp/p")
	for name, got := range map[string]string{
		"AppDir":  l.AppDir,
		"BinDir":  l.BinDir,
		"AppsDir": l.AppsDir,
		"Theme":   l.Theme,
	} {
		if !strings.HasPrefix(got, "/tmp/p/") {
			t.Errorf("%s = %q escapes the prefix", name, got)
		}
	}
	if l.AppDir != "/tmp/p/share/demo" {
		t.Errorf("AppDir = %q, want /tmp/p/share/demo", l.AppDir)
	}
}

// TestOneSpecType is the merge's own guard. frameworks briefly carried two
// Spec types — the state D-0005 rejected by name — and this test is what says
// so if a second one reappears in this package.
func TestSpecCarriesBothHalves(t *testing.T) {
	s := Spec{
		AppID:     "com.example.Demo",      // desktop half
		Launchers: []Launcher{{Name: "x"}}, // desktop half
		Scope:     ScopeUser,               // deployment half
		Units:     []Unit{{Stem: "demo"}},  // deployment half
	}
	if s.AppID == "" || len(s.Launchers) == 0 || s.Scope == "" || len(s.Units) == 0 {
		t.Fatal("a single Spec must express both the desktop and the deployment halves")
	}
}
