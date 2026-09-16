package installer

import "testing"

// RunFlags is the flag surface every consuming installer inherits from Run,
// so a silent change here changes three shipped binaries at once.

func TestParseRunFlagsDefaults(t *testing.T) {
	rf, err := ParseRunFlags(nil)
	if err != nil {
		t.Fatal(err)
	}
	if rf.Uninstall {
		t.Error("Uninstall must default false — it is destructive")
	}
	if rf.Version {
		t.Error("Version must default false")
	}
	if rf.Prefix != DefaultPrefix() {
		t.Errorf("Prefix default: got %q, want %q", rf.Prefix, DefaultPrefix())
	}
}

func TestParseRunFlagsOverrides(t *testing.T) {
	rf, err := ParseRunFlags([]string{"--prefix", "/opt/x", "--uninstall"})
	if err != nil {
		t.Fatal(err)
	}
	if rf.Prefix != "/opt/x" {
		t.Errorf("--prefix: got %q", rf.Prefix)
	}
	if !rf.Uninstall {
		t.Error("--uninstall was not set")
	}
}

// -V is the one shorthand this surface has ever exposed; it predates the
// autocfg conversion and consumers' docs reference it.
func TestParseRunFlagsVersionShorthand(t *testing.T) {
	rf, err := ParseRunFlags([]string{"-V"})
	if err != nil {
		t.Fatal(err)
	}
	if !rf.Version {
		t.Error("-V must still set Version after the autocfg conversion")
	}
}

func TestParseRunFlagsRejectsUnknownFlag(t *testing.T) {
	if _, err := ParseRunFlags([]string{"--nope"}); err == nil {
		t.Fatal("an unknown flag must be an error, not silently ignored")
	}
}
