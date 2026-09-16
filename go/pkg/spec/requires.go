package spec

import (
	"fmt"
	"sort"
	"strings"

	"github.com/davidwalter0/frameworks/go/pkg/deps"
)

// This file is the dependency axis — the one thing neither Spec had, and the
// reason merging them was necessary but not sufficient.
//
// THE MEASUREMENT THAT FORCED IT. word-bank/scripts/package-deb.sh:124 writes
//
//	Depends: libgtk-3-0
//
// beside a comment noting that the AppImage and tarball packagers BUNDLE the
// same library instead. So the SAME logical dependency resolves three different
// ways depending on what is being produced: declared in a deb, bundled in an
// AppImage, absent from a static tarball. No field on either old Spec could say
// that, and no merge of them creates the ability — it is a missing DIMENSION.
//
// Resolution and policy are deliberately separate concerns on the same
// dependency:
//
//	Resolve  how is it SATISFIED for a given output format?   (packaging)
//	Policy   what does its ABSENCE mean when we check?        (presence)
//
// Keeping them apart is what lets pkg/deps' vocabulary serve packaging without
// either becoming a special case of the other.

// Format is an output artifact kind. The family already ships all of these by
// hand: tar.gz (25 references), self-extractor (28), AppImage (14), dmg (11),
// deb (2), apk (2), aab (1).
type Format string

const (
	FormatDeb         Format = "deb"
	FormatRPM         Format = "rpm"
	FormatAPK         Format = "apk"
	FormatDMG         Format = "dmg"
	FormatAppImage    Format = "appimage"
	FormatTarball     Format = "tarball"
	FormatSelfExtract Format = "self-extract"
)

// KnownFormats is every format the model recognises, sorted for stable output.
func KnownFormats() []Format {
	return []Format{
		FormatAPK, FormatAppImage, FormatDeb, FormatDMG,
		FormatRPM, FormatSelfExtract, FormatTarball,
	}
}

// Valid reports whether f is a known format. Unknown is an error rather than a
// default: silently accepting a typo'd format would drop a dependency's
// resolution without a word.
func (f Format) Valid() bool {
	for _, k := range KnownFormats() {
		if f == k {
			return true
		}
	}
	return false
}

// Strategy is HOW a dependency is satisfied for one output format.
type Strategy string

const (
	// StrategyDeclare names the dependency in the package's own metadata and
	// lets the system package manager satisfy it — `Depends: libgtk-3-0` in a
	// deb, `Requires:` in an rpm. The idiomatic choice for a distro package,
	// and the reason a deb must NOT bundle what the distro already ships.
	StrategyDeclare Strategy = "declare"

	// StrategyBundle ships the dependency inside the artifact. Correct where
	// there is no package manager to ask — an AppImage, a dmg, a
	// self-extractor. This is what linuxdeploy does for GTK today.
	StrategyBundle Strategy = "bundle"

	// StrategyRequirePresent neither declares nor bundles: the artifact assumes
	// the dependency is already on the host and FAILS usefully if not. For
	// things a package manager cannot express — a running D-Bus session, a
	// specific kernel feature.
	StrategyRequirePresent Strategy = "require-present"

	// StrategyIgnore means this format does not need it at all. A statically
	// linked tarball needs no libgtk entry of any kind, and saying so
	// explicitly is different from forgetting to mention it.
	StrategyIgnore Strategy = "ignore"
)

func (s Strategy) Valid() bool {
	switch s {
	case StrategyDeclare, StrategyBundle, StrategyRequirePresent, StrategyIgnore:
		return true
	}
	return false
}

// Dependency is one thing the app needs, and how that need is met per format.
type Dependency struct {
	// Name is the dependency as the RESOLVING SYSTEM names it — "libgtk-3-0"
	// is Debian's spelling, and an rpm would want "gtk3". Per-format names
	// belong in NameFor, not here.
	Name string `json:"name" yaml:"name"`

	// Why records what the app needs it FOR, in the app's terms. Mandatory for
	// the same reason pkg/deps makes it mandatory: a dependency nobody can
	// explain cannot be safely removed.
	Why string `json:"why" yaml:"why"`

	// Resolve maps each output format to how the dependency is satisfied
	// there. A format absent from the map is UNSPECIFIED, which is an error at
	// build time rather than a silent default — the whole point is that the
	// answer differs per format, so guessing one would defeat the model.
	Resolve map[Format]Strategy `json:"resolve,omitempty" yaml:"resolve,omitempty"`

	// NameFor overrides Name per format, for ecosystems that spell the same
	// library differently (deb "libgtk-3-0" vs rpm "gtk3").
	NameFor map[Format]string `json:"name-for,omitempty" yaml:"name-for,omitempty"`

	// Policy is what the dependency's ABSENCE means when presence is CHECKED,
	// reusing pkg/deps' vocabulary. Distinct from Resolve: resolution is a
	// packaging decision made at build time, policy is a checking decision made
	// against a host.
	Policy deps.Policy `json:"policy,omitempty" yaml:"policy,omitempty"`
}

// StrategyFor returns the resolution for a format, and whether one was declared.
// A missing entry is reported rather than defaulted.
func (d Dependency) StrategyFor(f Format) (Strategy, bool) {
	s, ok := d.Resolve[f]
	return s, ok
}

// PackageNameFor returns the dependency's name as the given format's ecosystem
// spells it, falling back to Name.
func (d Dependency) PackageNameFor(f Format) string {
	if n, ok := d.NameFor[f]; ok && n != "" {
		return n
	}
	return d.Name
}

// ValidateRequires checks the dependency axis. Called by [Spec.Validate].
func (s Spec) ValidateRequires() error {
	var probs []string
	seen := map[string]bool{}

	for i, d := range s.Requires {
		where := fmt.Sprintf("Requires[%d]", i)
		if d.Name != "" {
			where = fmt.Sprintf("Requires[%d] (%s)", i, d.Name)
		}
		if strings.TrimSpace(d.Name) == "" {
			probs = append(probs, where+": Name is empty")
		} else if seen[d.Name] {
			probs = append(probs, where+": declared twice; one dependency, one resolution map")
		} else {
			seen[d.Name] = true
		}
		if strings.TrimSpace(d.Why) == "" {
			probs = append(probs, where+`: "Why" is empty — a dependency nobody can explain cannot be safely removed`)
		}
		if d.Policy != "" && !d.Policy.Valid() {
			probs = append(probs, fmt.Sprintf("%s: unknown policy %q", where, d.Policy))
		}
		if len(d.Resolve) == 0 {
			probs = append(probs, where+": no Resolve entries; a dependency that never says how it is satisfied cannot be packaged")
		}
		for f, st := range d.Resolve {
			if !f.Valid() {
				probs = append(probs, fmt.Sprintf("%s: unknown format %q", where, f))
			}
			if !st.Valid() {
				probs = append(probs, fmt.Sprintf("%s: unknown strategy %q for format %q", where, st, f))
			}
		}
		for f := range d.NameFor {
			if !f.Valid() {
				probs = append(probs, fmt.Sprintf("%s: NameFor names unknown format %q", where, f))
			}
		}
	}

	if len(probs) == 0 {
		return nil
	}
	sort.Strings(probs)
	return fmt.Errorf("spec: invalid Requires:\n  %s", strings.Join(probs, "\n  "))
}
