package spec

import (
	"strings"
	"testing"

	"github.com/davidwalter0/frameworks/go/pkg/deps"
)

// TestWordBankGTKResolvesThreeWays is the fixture the whole design was
// justified by, and it is a GATE: if the Spec cannot state this, the model is
// wrong and no repo should be migrated onto it.
//
// The real case, from word-bank/scripts/package-deb.sh:124 and the comment
// above it:
//
//	deb       -> Depends: libgtk-3-0   (the distro ships it; declaring is idiomatic)
//	appimage  -> bundled               (no package manager to ask)
//	tarball   -> absent                (statically linked; needs nothing)
//
// One logical dependency, three answers. Neither of the two Specs that were
// merged could express it — it is a missing dimension, not a missing field.
func TestWordBankGTKResolvesThreeWays(t *testing.T) {
	gtk := Dependency{
		Name: "libgtk-3-0",
		Why:  "the Flutter linux embedder links GTK3",
		Resolve: map[Format]Strategy{
			FormatDeb:      StrategyDeclare,
			FormatAppImage: StrategyBundle,
			FormatTarball:  StrategyIgnore,
		},
		NameFor: map[Format]string{
			FormatRPM: "gtk3", // same library, different ecosystem spelling
		},
		Policy: deps.Required,
	}

	s := validDesktop()
	s.Requires = []Dependency{gtk}
	if err := s.ValidateRequires(); err != nil {
		t.Fatalf("the motivating real-world case does not validate: %v", err)
	}

	for _, tc := range []struct {
		format Format
		want   Strategy
	}{
		{FormatDeb, StrategyDeclare},
		{FormatAppImage, StrategyBundle},
		{FormatTarball, StrategyIgnore},
	} {
		got, ok := gtk.StrategyFor(tc.format)
		if !ok {
			t.Errorf("%s: no strategy declared", tc.format)
			continue
		}
		if got != tc.want {
			t.Errorf("%s: strategy %q, want %q", tc.format, got, tc.want)
		}
	}

	// The three answers must actually DIFFER — a model that returned the same
	// strategy everywhere would pass a naive check while expressing nothing.
	deb, _ := gtk.StrategyFor(FormatDeb)
	img, _ := gtk.StrategyFor(FormatAppImage)
	tar, _ := gtk.StrategyFor(FormatTarball)
	if deb == img || img == tar || deb == tar {
		t.Fatal("the three formats resolved identically; the dimension is not being expressed")
	}
}

// TestPerFormatNaming: the same library is spelled differently per ecosystem,
// so a single Name would produce a broken rpm.
func TestPerFormatNaming(t *testing.T) {
	gtk := Dependency{
		Name:    "libgtk-3-0",
		NameFor: map[Format]string{FormatRPM: "gtk3"},
	}
	if got := gtk.PackageNameFor(FormatDeb); got != "libgtk-3-0" {
		t.Errorf("deb name = %q, want the default", got)
	}
	if got := gtk.PackageNameFor(FormatRPM); got != "gtk3" {
		t.Errorf("rpm name = %q, want the override", got)
	}
}

// TestAnUnspecifiedFormatIsReportedNotDefaulted. The entire point is that the
// answer differs per format, so inventing one for a format nobody declared
// would defeat the model — quietly, and in the direction of shipping a package
// with a wrong dependency list.
func TestAnUnspecifiedFormatIsReportedNotDefaulted(t *testing.T) {
	d := Dependency{
		Name:    "libfoo",
		Why:     "x",
		Resolve: map[Format]Strategy{FormatDeb: StrategyDeclare},
	}
	if _, ok := d.StrategyFor(FormatDMG); ok {
		t.Error("an undeclared format returned a strategy; it must report absence instead")
	}
}

// TestResolveAndPolicyAreIndependent is the separation the design rests on:
// one dependency can be bundled at package time AND required at check time,
// and neither answer implies the other.
func TestResolveAndPolicyAreIndependent(t *testing.T) {
	d := Dependency{
		Name:    "libgtk-3-0",
		Why:     "embedder links it",
		Resolve: map[Format]Strategy{FormatAppImage: StrategyBundle},
		Policy:  deps.Required,
	}
	s := validDesktop()
	s.Requires = []Dependency{d}
	if err := s.ValidateRequires(); err != nil {
		t.Fatalf("bundle + required is a legitimate combination: %v", err)
	}

	// The reverse combination is equally legitimate: declared in the package,
	// but merely best-effort when probing a host.
	d.Resolve = map[Format]Strategy{FormatDeb: StrategyDeclare}
	d.Policy = deps.BestEffort
	s.Requires = []Dependency{d}
	if err := s.ValidateRequires(); err != nil {
		t.Fatalf("declare + best-effort is a legitimate combination: %v", err)
	}
}

func TestValidateRequiresRejectsIncoherentDeclarations(t *testing.T) {
	for _, tc := range []struct {
		name string
		dep  Dependency
		want string
	}{
		{"no name", Dependency{Why: "x", Resolve: map[Format]Strategy{FormatDeb: StrategyDeclare}}, "Name is empty"},
		{"no why", Dependency{Name: "a", Resolve: map[Format]Strategy{FormatDeb: StrategyDeclare}}, `"Why" is empty`},
		{"no resolutions", Dependency{Name: "a", Why: "x"}, "cannot be packaged"},
		{"unknown format", Dependency{Name: "a", Why: "x", Resolve: map[Format]Strategy{"snap": StrategyDeclare}}, "unknown format"},
		{"unknown strategy", Dependency{Name: "a", Why: "x", Resolve: map[Format]Strategy{FormatDeb: "vendor"}}, "unknown strategy"},
		{"unknown policy", Dependency{Name: "a", Why: "x", Resolve: map[Format]Strategy{FormatDeb: StrategyDeclare}, Policy: "sometimes"}, "unknown policy"},
		{"NameFor unknown format", Dependency{Name: "a", Why: "x", Resolve: map[Format]Strategy{FormatDeb: StrategyDeclare}, NameFor: map[Format]string{"snap": "b"}}, "NameFor names unknown format"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := validDesktop()
			s.Requires = []Dependency{tc.dep}
			err := s.ValidateRequires()
			if err == nil {
				t.Fatalf("accepted: %s", tc.name)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error = %v, want it to mention %q", err, tc.want)
			}
		})
	}
}

func TestValidateRequiresRejectsDuplicates(t *testing.T) {
	d := Dependency{Name: "libfoo", Why: "x", Resolve: map[Format]Strategy{FormatDeb: StrategyDeclare}}
	s := validDesktop()
	s.Requires = []Dependency{d, d}
	if err := s.ValidateRequires(); err == nil || !strings.Contains(err.Error(), "declared twice") {
		t.Fatalf("duplicate dependency accepted: %v", err)
	}
}

// TestEmptyRequiresIsValid: most apps declare nothing, and that must not be an
// error — only an incoherent declaration is.
func TestEmptyRequiresIsValid(t *testing.T) {
	if err := validDesktop().ValidateRequires(); err != nil {
		t.Fatalf("a Spec with no Requires must validate: %v", err)
	}
}

func TestKnownFormatsCoverWhatTheFamilyShips(t *testing.T) {
	// Every artifact kind the packaging census found must be nameable, or a
	// repo could not describe what it already produces.
	for _, f := range []Format{
		FormatDeb, FormatRPM, FormatAPK, FormatDMG,
		FormatAppImage, FormatTarball, FormatSelfExtract,
	} {
		if !f.Valid() {
			t.Errorf("format %q is not in KnownFormats", f)
		}
	}
	if Format("snap").Valid() {
		t.Error("an unknown format validated; a typo would silently drop a resolution")
	}
}
