package spec

import (
	"path/filepath"
	"strings"
	"testing"
)

// testEnv describes a machine without touching the real one, so these tests
// say nothing about the host they run on and cannot race a sibling test's
// setenv.
func testEnv() Env {
	h := "/home/tester"
	return Env{
		Home:       h,
		DataHome:   filepath.Join(h, ".local", "share"),
		ConfigHome: filepath.Join(h, ".config"),
		StateHome:  filepath.Join(h, ".local", "state"),
		CacheHome:  filepath.Join(h, ".cache"),
		RuntimeDir: "/run/user/1000",
	}
}

func testSpec() Spec {
	return Spec{
		App:         "demo",
		AppID:       "com.example.demo",
		ShareSubdir: "demo",
		Components: []Component{
			{Name: "demod", Role: RoleDaemon, Rel: "bin/demod", Args: []string{"--serve"}},
			{Name: "demo", Role: RoleCLI, Rel: "bin/demo"},
			{Name: "demo-ui", Role: RoleGUI, Rel: "demo-ui"},
			{Name: "helper", Role: RoleHelper, Rel: "libexec/helper"},
		},
	}
}

func TestLayoutForPlatformLinux(t *testing.T) {
	lay, err := testSpec().LayoutForPlatform(PlatformLinux, testEnv(), Overrides{})
	if err != nil {
		t.Fatalf("LayoutForPlatform: %v", err)
	}
	for _, tc := range []struct{ name, got, want string }{
		{"BinDir", lay.BinDir, "/home/tester/.local/bin"},
		{"AppDir", lay.AppDir, "/home/tester/.local/share/demo"},
		{"AppsDir", lay.AppsDir, "/home/tester/.local/share/applications"},
		{"Theme", lay.Theme, "/home/tester/.local/share/icons/hicolor"},
		{"ConfigDir", lay.ConfigDir, "/home/tester/.config/demo"},
		{"StateDir", lay.StateDir, "/home/tester/.local/state/demo"},
		{"CacheDir", lay.CacheDir, "/home/tester/.cache/demo"},
		{"UnitDir", lay.UnitDir, "/home/tester/.config/systemd/user"},
	} {
		if tc.got != tc.want {
			t.Errorf("%s = %q, want %q", tc.name, tc.got, tc.want)
		}
	}
}

// An explicitly set XDG_DATA_HOME must be honoured rather than silently
// replaced by <prefix>/share. Deriving from the variable is the whole rule.
func TestLayoutHonoursXDGDataHome(t *testing.T) {
	env := testEnv()
	env.DataHome = "/mnt/data/share"
	lay, err := testSpec().LayoutForPlatform(PlatformLinux, env, Overrides{})
	if err != nil {
		t.Fatalf("LayoutForPlatform: %v", err)
	}
	if lay.AppDir != "/mnt/data/share/demo" {
		t.Errorf("AppDir = %q, want it under the explicit XDG_DATA_HOME", lay.AppDir)
	}
}

// Prefix moves the install tree and deliberately does NOT move config. An app
// whose prefix silently relocated its settings installs fine and then cannot
// find them.
func TestPrefixDoesNotMoveConfig(t *testing.T) {
	lay, err := testSpec().LayoutForPlatform(
		PlatformLinux, testEnv(), Overrides{Prefix: "/opt/demo"})
	if err != nil {
		t.Fatalf("LayoutForPlatform: %v", err)
	}
	if lay.AppDir != "/opt/demo/share/demo" {
		t.Errorf("AppDir = %q, want it under the prefix", lay.AppDir)
	}
	if lay.BinDir != "/opt/demo/bin" {
		t.Errorf("BinDir = %q, want it under the prefix", lay.BinDir)
	}
	if lay.ConfigDir != "/home/tester/.config/demo" {
		t.Errorf("ConfigDir = %q, want it UNMOVED by prefix", lay.ConfigDir)
	}
}

func TestLayoutForPlatformDarwin(t *testing.T) {
	lay, err := testSpec().LayoutForPlatform(PlatformDarwin, testEnv(), Overrides{})
	if err != nil {
		t.Fatalf("LayoutForPlatform: %v", err)
	}
	if lay.AppDir != "/home/tester/Library/Application Support/demo" {
		t.Errorf("AppDir = %q", lay.AppDir)
	}
	if lay.UnitDir != "/home/tester/Library/LaunchAgents" {
		t.Errorf("UnitDir = %q", lay.UnitDir)
	}
	// Recorded debt, asserted so it cannot drift silently: darwin's BinDir is
	// ~/go/bin until cross-bridge's three mac-side scripts stop hardcoding it.
	if lay.BinDir != "/home/tester/go/bin" {
		t.Errorf("BinDir = %q, want the recorded ~/go/bin debt", lay.BinDir)
	}
	// macOS installs no icon theme; empty must stay empty, not be filled in.
	if lay.Theme != "" {
		t.Errorf("Theme = %q, want empty on darwin", lay.Theme)
	}
}

// An unknown platform must ERROR. Falling back to Linux would not fail at
// install time; it would succeed and put files where nothing looks for them.
func TestUnknownPlatformErrors(t *testing.T) {
	_, err := testSpec().LayoutForPlatform(Platform("plan9"), testEnv(), Overrides{})
	if err == nil {
		t.Fatal("want an error for an unsupported platform, got nil")
	}
	if !strings.Contains(err.Error(), "plan9") {
		t.Errorf("error should name the offending platform, got: %v", err)
	}
}

// Every override must reach its own field, or a flag silently does nothing.
func TestOverridesApplyPerDirectory(t *testing.T) {
	ov := Overrides{
		BinDir: "/o/bin", AppDir: "/o/app", AppsDir: "/o/apps", Theme: "/o/theme",
		ConfigDir: "/o/cfg", StateDir: "/o/state", CacheDir: "/o/cache", UnitDir: "/o/units",
	}
	lay, err := testSpec().LayoutForPlatform(PlatformLinux, testEnv(), ov)
	if err != nil {
		t.Fatalf("LayoutForPlatform: %v", err)
	}
	for _, tc := range []struct{ name, got, want string }{
		{"BinDir", lay.BinDir, "/o/bin"}, {"AppDir", lay.AppDir, "/o/app"},
		{"AppsDir", lay.AppsDir, "/o/apps"}, {"Theme", lay.Theme, "/o/theme"},
		{"ConfigDir", lay.ConfigDir, "/o/cfg"}, {"StateDir", lay.StateDir, "/o/state"},
		{"CacheDir", lay.CacheDir, "/o/cache"}, {"UnitDir", lay.UnitDir, "/o/units"},
	} {
		if tc.got != tc.want {
			t.Errorf("override %s = %q, want %q", tc.name, tc.got, tc.want)
		}
	}
}

// Only a cli lands on PATH. systemd's file-hierarchy(7) draws this line and a
// helper on PATH is how eight cross-bridge binaries came to shadow each other.
func TestDestinationForByRole(t *testing.T) {
	s := testSpec()
	lay, err := s.LayoutForPlatform(PlatformLinux, testEnv(), Overrides{})
	if err != nil {
		t.Fatalf("LayoutForPlatform: %v", err)
	}
	want := map[string]string{
		"demo":    "/home/tester/.local/bin/demo",
		"demod":   "/home/tester/.local/share/demo/bin/demod",
		"demo-ui": "/home/tester/.local/share/demo/demo-ui",
		"helper":  "/home/tester/.local/share/demo/libexec/helper",
	}
	for _, c := range s.Components {
		if got := lay.DestinationFor(c); got != want[c.Name] {
			t.Errorf("DestinationFor(%s) = %q, want %q", c.Name, got, want[c.Name])
		}
	}
}

// THE LOAD-BEARING TEST. The token a unit substitutes must equal the path the
// installer writes, so the two cannot disagree. Changing the layout must move
// the token with it — that is what mountbridge's hand-written units did not do.
func TestTokensTrackTheComputedDestination(t *testing.T) {
	s := testSpec()

	lay, err := s.LayoutForPlatform(PlatformLinux, testEnv(), Overrides{})
	if err != nil {
		t.Fatalf("LayoutForPlatform: %v", err)
	}
	tok, err := lay.Tokens(s)
	if err != nil {
		t.Fatalf("Tokens: %v", err)
	}

	daemon := s.Components[0] // demod
	if got, want := tok[TokenExec], lay.DestinationFor(daemon); got != want {
		t.Errorf("__EXEC__ = %q, want the computed destination %q", got, want)
	}
	if tok[TokenExec] != "/home/tester/.local/share/demo/bin/demod" {
		t.Errorf("__EXEC__ = %q", tok[TokenExec])
	}

	// Move the install, and the token must move with it.
	moved, err := s.LayoutForPlatform(
		PlatformLinux, testEnv(), Overrides{AppDir: "/somewhere/else"})
	if err != nil {
		t.Fatalf("LayoutForPlatform: %v", err)
	}
	movedTok, err := moved.Tokens(s)
	if err != nil {
		t.Fatalf("Tokens: %v", err)
	}
	if movedTok[TokenExec] == tok[TokenExec] {
		t.Fatal("__EXEC__ did not follow the layout — the token is not derived from it")
	}
	if movedTok[TokenExec] != "/somewhere/else/bin/demod" {
		t.Errorf("relocated __EXEC__ = %q", movedTok[TokenExec])
	}
}

// The derivation SOURCE, pinned. mountbridge derived its path from
// os.Executable(), so a unit written by ~/go/bin/mountbridge named ~/go/bin
// forever. Nothing here may consult the running binary: this test process lives
// somewhere unrelated to the layout, and the token must ignore that entirely.
func TestTokensIgnoreTheRunningBinary(t *testing.T) {
	s := testSpec()
	lay, err := s.LayoutForPlatform(PlatformLinux, testEnv(), Overrides{})
	if err != nil {
		t.Fatalf("LayoutForPlatform: %v", err)
	}
	tok, err := lay.Tokens(s)
	if err != nil {
		t.Fatalf("Tokens: %v", err)
	}
	// The test binary runs from a temp build directory, never /home/tester.
	if !strings.HasPrefix(tok[TokenExec], "/home/tester/") {
		t.Fatalf("__EXEC__ = %q — it must come from the layout, not the running process",
			tok[TokenExec])
	}
	for name, v := range tok {
		if strings.Contains(v, "/go/bin/") && !strings.HasPrefix(v, "/home/tester/") {
			t.Errorf("token %s = %q leaked a real path from the running environment", name, v)
		}
	}
}

func TestExecTokenNaming(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"mountbridge", "__EXEC_MOUNTBRIDGE__"},
		{"mountbridge-ui", "__EXEC_MOUNTBRIDGE_UI__"},
		{"wwkeymap-visual", "__EXEC_WWKEYMAP_VISUAL__"},
		{"a.b-c", "__EXEC_A_B_C__"},
	} {
		if got := ExecToken(tc.in); got != tc.want {
			t.Errorf("ExecToken(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// Two components whose names collapse to one token would silently share a
// destination. Refuse instead.
func TestExecTokenCollisionIsAnError(t *testing.T) {
	s := testSpec()
	s.Components = []Component{
		{Name: "a-b", Role: RoleCLI},
		{Name: "a.b", Role: RoleCLI},
	}
	lay, err := s.LayoutForPlatform(PlatformLinux, testEnv(), Overrides{})
	if err != nil {
		t.Fatalf("LayoutForPlatform: %v", err)
	}
	if _, err := lay.Tokens(s); err == nil {
		t.Fatal("want an error when two component names map to one token")
	}
}

// With several daemons a bare __EXEC__ cannot mean one of them. ghk, mountbridge
// and alert-log all ship more than one unit.
func TestNoBareExecTokenWithSeveralDaemons(t *testing.T) {
	s := testSpec()
	s.Components = append(s.Components,
		Component{Name: "demod2", Role: RoleDaemon, Rel: "bin/demod2"})
	lay, err := s.LayoutForPlatform(PlatformLinux, testEnv(), Overrides{})
	if err != nil {
		t.Fatalf("LayoutForPlatform: %v", err)
	}
	tok, err := lay.Tokens(s)
	if err != nil {
		t.Fatalf("Tokens: %v", err)
	}
	if _, present := tok[TokenExec]; present {
		t.Error("__EXEC__ must be absent with more than one daemon")
	}
	if tok[ExecToken("demod")] == "" || tok[ExecToken("demod2")] == "" {
		t.Error("per-component exec tokens must still be present")
	}
}

// A hand-written token that also gets computed is either redundant or wrong.
// Both deserve to be said at install time.
func TestAuthoredTokenCollidingWithDerivedIsAnError(t *testing.T) {
	s := testSpec()
	lay, err := s.LayoutForPlatform(PlatformLinux, testEnv(), Overrides{})
	if err != nil {
		t.Fatalf("LayoutForPlatform: %v", err)
	}
	derived, err := lay.Tokens(s)
	if err != nil {
		t.Fatalf("Tokens: %v", err)
	}

	authored := map[string]string{TokenExec: "/home/tester/go/bin/demod"}
	if _, err := MergeTokens(derived, authored); err == nil {
		t.Fatal("want an error when tokens: re-declares a computed value")
	}

	// A token the layout does not compute passes through untouched.
	ok, err := MergeTokens(derived, map[string]string{"__ACCOUNT__": "someone"})
	if err != nil {
		t.Fatalf("MergeTokens: %v", err)
	}
	if ok["__ACCOUNT__"] != "someone" {
		t.Error("author-supplied non-colliding token was dropped")
	}
	if ok[TokenExec] != derived[TokenExec] {
		t.Error("derived token lost during merge")
	}
}

// Theme is absent rather than empty on darwin, so a unit referencing it fails
// as an unknown token instead of substituting "" into a path.
func TestThemeTokenAbsentOnDarwin(t *testing.T) {
	s := testSpec()
	lay, err := s.LayoutForPlatform(PlatformDarwin, testEnv(), Overrides{})
	if err != nil {
		t.Fatalf("LayoutForPlatform: %v", err)
	}
	tok, err := lay.Tokens(s)
	if err != nil {
		t.Fatalf("Tokens: %v", err)
	}
	if _, present := tok[TokenTheme]; present {
		t.Error("__THEME__ must be absent on darwin, which installs no icon theme")
	}
}
