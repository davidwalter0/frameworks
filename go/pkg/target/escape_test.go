package target

import (
	"os/exec"
	"strings"
	"testing"
)

func TestEscapeUnitName(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{
		{"plain", "ghk", "ghk"},
		{"dot kept mid-string", "a.b", "a.b"},
		{"leading dot escaped", ".hidden", `\x2ehidden`},
		{"slash becomes dash", "a/b", "a-b"},
		{"dash is escaped", "my-disk", `my\x2ddisk`},
		{"at sign", "you@example.com", `you\x40example.com`},
		{"space", "two words", `two\x20words`},
		{"colon and underscore survive", "a:b_c", "a:b_c"},
		{"empty", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := EscapeUnitName(c.in); got != c.want {
				t.Errorf("EscapeUnitName(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

func TestEscapePath(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{
		{"root is a bare dash", "/", "-"},
		{"simple", "/mnt/data", "mnt-data"},
		{"trailing slash ignored", "/mnt/data/", "mnt-data"},
		{"duplicate slashes collapse", "/mnt//data", "mnt-data"},
		{"dot segments dropped", "/mnt/./data", "mnt-data"},
		{"dash in a segment", "/mnt/my-disk", `mnt-my\x2ddisk`},
		{"deep", "/srv/a/b/c", "srv-a-b-c"},
		{"space in a segment", "/mnt/my data", `mnt-my\x20data`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := EscapePath(c.in); got != c.want {
				t.Errorf("EscapePath(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

// TestEscapeMatchesSystemd checks our pure implementation against the real
// tool. A .mount unit whose filename is not exactly `systemd-escape --path` of
// its mount point is IGNORED by systemd rather than rejected, so a divergence
// here would be invisible in every other test.
func TestEscapeMatchesSystemd(t *testing.T) {
	bin, err := exec.LookPath("systemd-escape")
	if err != nil {
		t.Skip("systemd-escape not installed; skipping the cross-check against the real tool")
	}

	paths := []string{
		"/", "/mnt/data", "/mnt/my-disk", "/srv/a/b/c", "/mnt/my data",
		"/mnt/data/", "/home/user/.cache/thing", "/mnt/ünicode",
	}
	for _, p := range paths {
		t.Run("path "+p, func(t *testing.T) {
			out, err := exec.Command(bin, "--path", p).Output()
			if err != nil {
				t.Fatalf("systemd-escape --path %q: %v", p, err)
			}
			want := strings.TrimSpace(string(out))
			if got := EscapePath(p); got != want {
				t.Errorf("EscapePath(%q) = %q, systemd-escape says %q", p, got, want)
			}
		})
	}

	names := []string{"ghk", "you@example.com", "two words", "my-disk", "a.b"}
	for _, n := range names {
		t.Run("name "+n, func(t *testing.T) {
			out, err := exec.Command(bin, n).Output()
			if err != nil {
				t.Fatalf("systemd-escape %q: %v", n, err)
			}
			want := strings.TrimSpace(string(out))
			if got := EscapeUnitName(n); got != want {
				t.Errorf("EscapeUnitName(%q) = %q, systemd-escape says %q", n, got, want)
			}
		})
	}
}
