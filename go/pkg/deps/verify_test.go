package deps

import (
	"bytes"
	"strings"
	"testing"
)

// absent is a probe reporting that none of the named tools exist. This is the
// seam that makes every policy branch testable without uninstalling anything —
// the same trick ui/tools/osv-gate.sh uses with OSV_GATE_JSON to make its
// FAILURE path reachable in a test.
func absent(names ...string) Probe {
	gone := map[string]bool{}
	for _, n := range names {
		gone[n] = true
	}
	return func(name string) bool { return !gone[name] }
}

func allPresent(string) bool { return true }

func tool(name string, p Policy) Tool {
	t := Tool{Name: name, Policy: p, Why: "because " + name}
	if p == Required {
		t.Install = "install " + name
	}
	if p == OptionalDegrade {
		t.DegradeTo = name + "-lite"
	}
	return t
}

// TestEachPolicyBranchFires is the core of this package: absence means four
// different things, and each must be reachable and distinguishable.
func TestEachPolicyBranchFires(t *testing.T) {
	tests := []struct {
		policy   Policy
		want     Outcome
		wantExit int
	}{
		{Required, Failed, ExitUnsatisfied},
		{OptionalSkip, Skipped, ExitOK},
		{OptionalDegrade, Degraded, ExitOK},
		{BestEffort, Ignored, ExitOK},
	}
	for _, tt := range tests {
		t.Run(string(tt.policy), func(t *testing.T) {
			m := Manifest{Requires: []Tool{tool("thing", tt.policy)}}
			if err := m.Validate(); err != nil {
				t.Fatalf("Validate: %v", err)
			}
			rep := Verify(m, "", absent("thing"))
			if got := rep.Results[0].Outcome; got != tt.want {
				t.Errorf("outcome = %q, want %q", got, tt.want)
			}
			if got := rep.ExitCode(); got != tt.wantExit {
				t.Errorf("exit = %d, want %d", got, tt.wantExit)
			}
		})
	}
}

// TestOnlyRequiredFailsTheGate states the contract in one assertion: exactly
// one of the four policies is allowed to stop the build.
func TestOnlyRequiredFailsTheGate(t *testing.T) {
	m := Manifest{Requires: []Tool{
		tool("a", OptionalSkip),
		tool("b", OptionalDegrade),
		tool("c", BestEffort),
	}}
	rep := Verify(m, "", absent("a", "b", "c"))
	if rep.ExitCode() != ExitOK {
		t.Fatalf("exit = %d; only a missing REQUIRED tool may fail the gate", rep.ExitCode())
	}

	m.Requires = append(m.Requires, tool("d", Required))
	rep = Verify(m, "", absent("a", "b", "c", "d"))
	if rep.ExitCode() != ExitUnsatisfied {
		t.Fatalf("exit = %d, want %d once a required tool is missing", rep.ExitCode(), ExitUnsatisfied)
	}
	if n := len(rep.Unsatisfied()); n != 1 {
		t.Errorf("Unsatisfied() = %d, want 1", n)
	}
}

// TestDegradationIsAnnounced is the census's worst finding turned into a test.
// One repo answered a missing golangci-lint by running `go vet` and saying
// "not installed; running go vet" — the gate silently became a weaker gate.
// Degrading is allowed; degrading QUIETLY is not.
func TestDegradationIsAnnounced(t *testing.T) {
	m := Manifest{Requires: []Tool{tool("golangci-lint", OptionalDegrade)}}
	rep := Verify(m, "", absent("golangci-lint"))

	var buf bytes.Buffer
	rep.Write(&buf, false)
	out := buf.String()

	for _, want := range []string{"DEGRADED", "golangci-lint", "golangci-lint-lite", "weaker"} {
		if !strings.Contains(out, want) {
			t.Errorf("degradation report missing %q; a silent downgrade is the defect this package exists to end\ngot:\n%s", want, out)
		}
	}
}

// TestSkipsAreReported: an unexplained skip is indistinguishable from an
// ignored one, so a passing gate must still say what it did not run.
func TestSkipsAreReported(t *testing.T) {
	m := Manifest{Requires: []Tool{tool("lcov", OptionalSkip)}}
	rep := Verify(m, "", absent("lcov"))
	if rep.ExitCode() != ExitOK {
		t.Fatalf("a skip must not fail the gate")
	}
	var buf bytes.Buffer
	rep.Write(&buf, false)
	if !strings.Contains(buf.String(), "skipped") || !strings.Contains(buf.String(), "lcov") {
		t.Errorf("skip was not reported:\n%s", buf.String())
	}
}

// TestFailureCarriesItsInstallHint: an error that only accuses is not
// actionable.
func TestFailureCarriesItsInstallHint(t *testing.T) {
	m := Manifest{Requires: []Tool{tool("govulncheck", Required)}}
	rep := Verify(m, "", absent("govulncheck"))
	var buf bytes.Buffer
	rep.Write(&buf, false)
	out := buf.String()
	if !strings.Contains(out, "MISSING") || !strings.Contains(out, "install govulncheck") {
		t.Errorf("required failure lacks its install hint:\n%s", out)
	}
	if !strings.Contains(out, "FAIL") {
		t.Errorf("required failure did not say FAIL:\n%s", out)
	}
}

// TestPresentToolsAreQuietByDefault: a wall of green hides the two lines that
// matter.
func TestPresentToolsAreQuietByDefault(t *testing.T) {
	m := Manifest{Requires: []Tool{tool("a", Required), tool("b", Required)}}
	rep := Verify(m, "", allPresent)

	var quiet, loud bytes.Buffer
	rep.Write(&quiet, false)
	rep.Write(&loud, true)

	if strings.Contains(quiet.String(), "  ok ") {
		t.Errorf("present tools listed without --verbose:\n%s", quiet.String())
	}
	if !strings.Contains(loud.String(), "ok") {
		t.Errorf("--verbose did not list present tools:\n%s", loud.String())
	}
	if !strings.Contains(quiet.String(), "PASS") {
		t.Errorf("a clean run must still say PASS:\n%s", quiet.String())
	}
}

// TestProfilesScopeTheCheck: a dist-only tool must not fail `make check`.
func TestProfilesScopeTheCheck(t *testing.T) {
	distOnly := tool("docker", Required)
	distOnly.Profiles = []string{"dist"}
	always := tool("govulncheck", Required)

	m := Manifest{Requires: []Tool{distOnly, always}}

	if rep := Verify(m, "check", absent("docker")); rep.ExitCode() != ExitOK {
		t.Errorf("a dist-only prerequisite failed the check profile")
	}
	if rep := Verify(m, "dist", absent("docker")); rep.ExitCode() != ExitUnsatisfied {
		t.Errorf("a dist-only prerequisite did not fail its own profile")
	}
	// An empty profile means "everything", so it must still catch it.
	if rep := Verify(m, "", absent("docker")); rep.ExitCode() != ExitUnsatisfied {
		t.Errorf("the empty profile skipped a prerequisite instead of checking all")
	}
}

func TestExitCodesAreDistinct(t *testing.T) {
	if ExitOK == ExitUnsatisfied || ExitUnsatisfied == ExitManifest || ExitOK == ExitManifest {
		t.Fatal("exit codes collapsed; a missing tool, a broken manifest and success must be distinguishable")
	}
}
