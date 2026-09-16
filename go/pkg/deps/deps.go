// Package deps declares a component's environment prerequisites and the POLICY
// for each one's absence.
//
// # Why this exists
//
// A census of this family found `command -v` checks hand-rolled in 38 repos,
// with the same tool re-declared over and over: golangci-lint 23x, govulncheck
// 21x, gtk-update-icon-cache 19x, flutter 19x, update-desktop-database 17x,
// osv-scanner 16x.
//
// Removing that duplication is the incidental benefit. The real defect is that
// the same missing tool is handled FOUR DIFFERENT WAYS across those sites:
//
//	"golangci-lint absent — skipped (noted)"
//	"golangci-lint not installed; skipping"
//	"golangci-lint not installed; running go vet"    <- degrades the gate
//	command -v gtk-update-icon-cache && … || true     <- never fails
//
// So `make lint` means something different in each repo: a real gate in one, a
// silent downgrade to `go vet` in another, a vacuous pass in a third. That is
// the "a gate that cannot fail is not a gate" rule broken independently ~23
// times, each time buried in shell where nobody reads it.
//
// This package makes the policy explicit and uniform. It does not decide the
// policy — each repo still chooses — but the choice becomes a declaration
// someone can read, diff and disagree with, instead of an `|| true`.
//
// # What it deliberately does not cover
//
// Libraries. Go modules and Dart packages already have real resolvers that
// lock versions and get audited by osv-scanner; restating them here would
// create a second source of truth that can disagree with the first. This
// package covers only what nothing else resolves: tools that must simply be
// present on the host.
//
// # Bootstrap limit
//
// A Go program cannot check whether Go is installed, and `go` is itself one of
// the 21x-checked tools. `go` and `make` stay inline shell checks in each
// Makefile; everything downstream of a working toolchain comes here. Stated
// plainly rather than discovered by someone later.
package deps

import (
	"gopkg.in/yaml.v3"

	"fmt"
	"os/exec"
	"sort"
	"strings"
)

// Policy says what the absence of a tool MEANS. It is the whole point of the
// package: presence is a fact, but absence is a decision, and that decision is
// what was scattered across 38 repos.
type Policy string

const (
	// Required: absence fails the gate. Use when the tool IS the check — a
	// missing linter means the lint stage did not run, and a stage that cannot
	// run must not report success.
	//
	// This is the "project gap" of the check-suite convention: the language
	// supports the instrument and this host lacks it. That is a defect to fix,
	// not a skip to record.
	Required Policy = "required"

	// OptionalSkip: absence is recorded and the gate still passes. Use for an
	// "ecosystem gap" — a category the language genuinely lacks — never to
	// paper over a tool someone simply has not installed.
	//
	// The skip is REPORTED, never silent. An unexplained skip is
	// indistinguishable from an ignored one.
	OptionalSkip Policy = "optional-skip"

	// OptionalDegrade: absence falls back to a weaker instrument, named in
	// DegradeTo, and SAYS SO. This is the golangci-lint -> go vet case found in
	// the census, where a gate quietly became a lesser gate and nothing
	// announced it.
	//
	// Degradation is legitimate; silent degradation is not.
	OptionalDegrade Policy = "optional-degrade"

	// BestEffort: absence is genuinely fine and needs no report. Reserved for
	// things that are conveniences rather than checks —
	// gtk-update-icon-cache, whose work the desktop redoes at next login.
	BestEffort Policy = "best-effort"
)

// Valid reports whether p is a known policy. An unknown policy is a manifest
// error rather than a default, because defaulting would silently pick someone's
// gate semantics for them.
func (p Policy) Valid() bool {
	switch p {
	case Required, OptionalSkip, OptionalDegrade, BestEffort:
		return true
	}
	return false
}

// Tool is one environment prerequisite.
type Tool struct {
	// Name is the executable looked up on PATH.
	Name string `yaml:"tool" json:"tool"`

	// Policy is what absence means. Required by design: there is no default,
	// because every default would be a guess at someone's gate semantics.
	Policy Policy `yaml:"policy" json:"policy"`

	// Why records what this tool is FOR, in the consuming repo's terms. It is
	// mandatory because the census's worst artifact was a bare `command -v`
	// with no statement of purpose — nobody could tell whether removing it was
	// safe.
	Why string `yaml:"why" json:"why"`

	// Install is the command that obtains it. Printed on a Required failure,
	// so the error is actionable rather than an accusation.
	Install string `yaml:"install,omitempty" json:"install,omitempty"`

	// DegradeTo names the weaker instrument used when an OptionalDegrade tool
	// is absent. Meaningless for other policies, and required for this one.
	DegradeTo string `yaml:"degradeTo,omitempty" json:"degradeTo,omitempty"`

	// Profiles limits this prerequisite to named profiles ("check", "dist").
	// Empty means every profile: the common case is a tool the repo always
	// needs, and requiring a profile list for that would be noise.
	Profiles []string `yaml:"profiles,omitempty" json:"profiles,omitempty"`
}

// Manifest is a repo's declared prerequisites, read from deps.yaml at its root.
type Manifest struct {
	// Requires are tools that must be present where the component is USED or
	// BUILT. The Debian analogue is Depends/Build-Depends collapsed to one
	// list, since a profile already distinguishes them here.
	Requires []Tool `yaml:"requires" json:"requires"`

	// Spec absorbs the application declaration when this file is a UNIFIED
	// manifest (spec.Manifest) rather than a bare deps.yaml. It is captured as
	// a raw node and never interpreted here.
	//
	// Two reasons it is a yaml.Node and not a spec.Spec. The obvious one is
	// the import cycle: pkg/spec imports pkg/deps for Policy, so pkg/deps
	// cannot import pkg/spec back. The better one is that this package has no
	// business validating an application declaration — it answers one
	// question, "are the declared host tools present", and a manifest section
	// addressed to a different consumer should pass through it untouched
	// rather than become a second thing it can reject.
	//
	// Without this field the loader is strict-mode-correct and USELESS: it
	// rejects the very file the family is consolidating on, with
	// "field spec not found in type deps.Manifest".
	Spec yaml.Node `yaml:"spec,omitempty" json:"-"`
}

// Validate reports every problem at once rather than the first, so a malformed
// manifest is fixed in one pass instead of N.
func (m Manifest) Validate() error {
	var probs []string
	seen := map[string]bool{}

	for i, t := range m.Requires {
		where := fmt.Sprintf("requires[%d]", i)
		if t.Name != "" {
			where = fmt.Sprintf("requires[%d] (%s)", i, t.Name)
		}
		if strings.TrimSpace(t.Name) == "" {
			probs = append(probs, where+": tool name is empty")
		} else if seen[t.Name] {
			probs = append(probs, where+": declared twice; one tool, one policy")
		} else {
			seen[t.Name] = true
		}
		if !t.Policy.Valid() {
			probs = append(probs, fmt.Sprintf(
				"%s: unknown policy %q (want required|optional-skip|optional-degrade|best-effort)",
				where, t.Policy))
		}
		if strings.TrimSpace(t.Why) == "" {
			probs = append(probs, where+`: "why" is empty — a prerequisite nobody can explain cannot be safely removed`)
		}
		if t.Policy == Required && strings.TrimSpace(t.Install) == "" {
			probs = append(probs, where+`: policy "required" needs an "install" hint, or the failure is not actionable`)
		}
		if t.Policy == OptionalDegrade && strings.TrimSpace(t.DegradeTo) == "" {
			probs = append(probs, where+`: policy "optional-degrade" must name "degradeTo" — an unnamed fallback is a silent downgrade`)
		}
		if t.Policy != OptionalDegrade && strings.TrimSpace(t.DegradeTo) != "" {
			probs = append(probs, fmt.Sprintf(`%s: "degradeTo" is set but policy is %q; it would never be used`, where, t.Policy))
		}
	}

	if len(probs) == 0 {
		return nil
	}
	sort.Strings(probs)
	return fmt.Errorf("deps: invalid manifest:\n  %s", strings.Join(probs, "\n  "))
}

// InProfile reports whether t applies to the named profile. An empty profile
// argument means "all", and an empty Profiles list means "every profile".
func (t Tool) InProfile(profile string) bool {
	if profile == "" || len(t.Profiles) == 0 {
		return true
	}
	for _, p := range t.Profiles {
		if p == profile {
			return true
		}
	}
	return false
}

// Probe reports whether a tool is present. It is injected so the policy
// branches can be tested without uninstalling anything — the same seam that
// makes osv-gate.sh's failure path testable via OSV_GATE_JSON.
type Probe func(name string) bool

// LookPath is the real probe.
func LookPath(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}
