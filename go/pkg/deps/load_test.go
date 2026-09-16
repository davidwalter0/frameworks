package deps

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadValidManifest(t *testing.T) {
	p := write(t, t.TempDir(), FileName, `
requires:
  - tool: govulncheck
    policy: required
    why: the vuln stage is a gate
    install: go install golang.org/x/vuln/cmd/govulncheck@latest
  - tool: gtk-update-icon-cache
    policy: best-effort
    why: desktops refresh at next login anyway
`)
	m, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(m.Requires) != 2 {
		t.Fatalf("got %d prerequisites, want 2", len(m.Requires))
	}
}

// TestMisspelledKeyIsAnError: a prerequisite meant to be `required` but spelled
// `requred` would otherwise vanish silently, which is the exact class of
// invisible failure this package exists to remove.
func TestMisspelledKeyIsAnError(t *testing.T) {
	p := write(t, t.TempDir(), FileName, `
requires:
  - tool: x
    polciy: required
    why: typo in the policy key
`)
	_, err := Load(p)
	if err == nil {
		t.Fatal("a misspelled key was accepted; it would silently drop the policy")
	}
}

// TestMissingFileIsNotAnEmptyManifest: "no deps.yaml" and "declares nothing"
// are different statements, and conflating them turns a wrong path into a clean
// bill of health.
func TestMissingFileIsNotAnEmptyManifest(t *testing.T) {
	_, err := Load(filepath.Join(t.TempDir(), "nope.yaml"))
	if err == nil {
		t.Fatal("a missing manifest loaded as empty; that is a vacuous pass")
	}
}

func TestValidateRejectsIncoherentDeclarations(t *testing.T) {
	tests := []struct {
		name string
		tool Tool
		want string
	}{
		{"no name", Tool{Policy: Required, Why: "x", Install: "i"}, "tool name is empty"},
		{"unknown policy", Tool{Name: "a", Policy: "sometimes", Why: "x"}, "unknown policy"},
		{"no why", Tool{Name: "a", Policy: BestEffort}, `"why" is empty`},
		{"required without install", Tool{Name: "a", Policy: Required, Why: "x"}, `needs an "install" hint`},
		{"degrade without target", Tool{Name: "a", Policy: OptionalDegrade, Why: "x"}, `must name "degradeTo"`},
		{"degradeTo on wrong policy", Tool{Name: "a", Policy: BestEffort, Why: "x", DegradeTo: "b"}, "would never be used"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := Manifest{Requires: []Tool{tt.tool}}.Validate()
			if err == nil {
				t.Fatalf("accepted an incoherent declaration; want %q", tt.want)
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Errorf("error = %v, want it to mention %q", err, tt.want)
			}
		})
	}
}

// TestValidateRejectsDuplicateTools: one tool, one policy. Two entries would
// mean the outcome depends on ordering.
func TestValidateRejectsDuplicateTools(t *testing.T) {
	m := Manifest{Requires: []Tool{
		{Name: "a", Policy: BestEffort, Why: "x"},
		{Name: "a", Policy: Required, Why: "y", Install: "i"},
	}}
	if err := m.Validate(); err == nil || !strings.Contains(err.Error(), "declared twice") {
		t.Fatalf("duplicate tool accepted: %v", err)
	}
}

// TestValidateReportsEveryProblem: fixing a manifest one error per run is a
// waste of the reader's time.
func TestValidateReportsEveryProblem(t *testing.T) {
	m := Manifest{Requires: []Tool{
		{Name: "", Policy: "bogus", Why: ""},
	}}
	err := Manifest.Validate(m)
	if err == nil {
		t.Fatal("want errors")
	}
	got := err.Error()
	for _, want := range []string{"tool name is empty", "unknown policy", `"why" is empty`} {
		if !strings.Contains(got, want) {
			t.Errorf("only some problems reported; missing %q\ngot: %s", want, got)
		}
	}
}

// TestFindStopsAtARepoRoot, including a worktree whose .git is a FILE. Treating
// only directories as roots would walk out of every worktree into the parent
// checkout and read the wrong manifest.
func TestFindStopsAtARepoRoot(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".git", "gitdir: /elsewhere/.git/worktrees/wt\n") // a worktree's .git
	write(t, root, FileName, "requires: []\n")
	write(t, filepath.Join(root, "go", "pkg"), ".keep", "")

	got, err := Find(filepath.Join(root, "go", "pkg"))
	if err != nil {
		t.Fatalf("Find: %v", err)
	}
	if want := filepath.Join(root, FileName); got != want {
		t.Errorf("Find = %s, want %s", got, want)
	}
}

func TestFindFailsAtARootWithNoManifest(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".git", "gitdir: x\n")
	write(t, filepath.Join(root, "sub"), ".keep", "")

	if _, err := Find(filepath.Join(root, "sub")); err == nil {
		t.Fatal("Find succeeded at a repo root with no manifest")
	} else if !strings.Contains(err.Error(), "repo root") {
		t.Errorf("error should name the repo root it stopped at: %v", err)
	}
}

// TestEmptyRequiresIsValid: a component with genuinely nothing to declare says
// so explicitly, which is how it stays distinguishable from a missing file.
func TestEmptyRequiresIsValid(t *testing.T) {
	p := write(t, t.TempDir(), FileName, "requires: []\n")
	if _, err := Load(p); err != nil {
		t.Fatalf("an explicitly empty manifest must be valid: %v", err)
	}
}

// TestLoadUnifiedManifest pins that this loader accepts a spec.Manifest — the
// unified file carrying both an application declaration and the host-tool
// list — and reads only its own section.
//
// Strict decoding is right (a mistyped key must fail) but it made the loader
// reject the exact file the family is consolidating on, with "field spec not
// found in type deps.Manifest". A loader that is correct and cannot read the
// canonical format is not correct.
func TestLoadUnifiedManifest(t *testing.T) {
	const unified = `
spec:
  app: textloom
  app-id: com.davidwalter0.textloom
  ships:
    - name: libgtk-3-0
      why: the embedder links GTK3
      resolve: {deb: declare}
requires:
  - tool: jq
    policy: required
    why: the gate classifies findings with it
    install: apt install jq
    profiles: [check]
`
	m, err := LoadBytes([]byte(unified))
	if err != nil {
		t.Fatalf("LoadBytes on a unified manifest: %v", err)
	}
	if len(m.Requires) != 1 || m.Requires[0].Name != "jq" {
		t.Fatalf("Requires = %+v, want the jq tool", m.Requires)
	}
}

// TestLoadStillRejectsAnUnknownKey guards the other direction: absorbing
// `spec:` must not have turned strict decoding off generally.
func TestLoadStillRejectsAnUnknownKey(t *testing.T) {
	if _, err := LoadBytes([]byte("requires: []\nnonsense: 1\n")); err == nil {
		t.Fatal("loader accepted an unknown top-level key")
	}
}
