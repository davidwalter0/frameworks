package spec_test

import (
	"reflect"
	"strings"
	"testing"

	"github.com/davidwalter0/frameworks/go/pkg/deps"
	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

// textloomManifest mirrors textloom's real declaration — the first consumer to move
// off a Go literal. Kept here as the round-trip fixture because it exercises
// both non-default enums at once (by-basename and subdirs), which are exactly
// the values a numeric serialization would corrupt silently.
func textloomManifest() spec.Manifest {
	return spec.Manifest{
		Spec: spec.Spec{
			App:           "textloom",
			AppID:         "com.davidwalter0.textloom",
			DisplayName:   "Textloom",
			ShareSubdir:   "textloom",
			DesktopSource: "textloom.desktop",
			DesktopNaming: spec.DesktopByBasename,
			Launchers: []spec.Launcher{
				{Target: "textloom", Name: "textloom", Blurb: "(or launch 'textloom' from your menu)"},
			},
			CleanMode:    spec.CleanSubdirs,
			CleanSubdirs: []string{"gui"},
			Requires: []spec.Dependency{{
				Name: "libgtk-3-0",
				Why:  "the Flutter Linux embedder links GTK3; absent, the app cannot start",
				Resolve: map[spec.Format]spec.Strategy{
					spec.FormatDeb:      spec.StrategyDeclare,
					spec.FormatAppImage: spec.StrategyBundle,
					spec.FormatTarball:  spec.StrategyRequirePresent,
				},
				NameFor: map[spec.Format]string{spec.FormatRPM: "gtk3"},
				Policy:  deps.Required,
			}},
		},
		Requires: []deps.Tool{{
			Name: "flutter", Policy: deps.Required,
			Why: "analyze/fmt-check/test/test-web all ARE this tool", Profiles: []string{"check"},
		}},
	}
}

// TestManifestRoundTrip is the load-bearing property: a manifest must
// reproduce the Spec it came from. Without it, moving a declaration out of Go
// and into YAML would be a lossy migration that still compiles.
func TestManifestRoundTrip(t *testing.T) {
	want := textloomManifest()
	b, err := want.Marshal()
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	got, err := spec.Load(b)
	if err != nil {
		t.Fatalf("Load: %v\n---\n%s", err, b)
	}
	if !reflect.DeepEqual(want, got) {
		t.Fatalf("round trip lost data:\n want %+v\n got  %+v\n---\n%s", want, got, b)
	}
}

// TestEnumsSerializeAsNamesNotIntegers pins the wire format. An iota
// serialized as a number is unreadable AND silently wrong if the constant
// order changes — and both of these enums have a non-zero value that carries a
// deliberate, documented behaviour difference.
func TestEnumsSerializeAsNamesNotIntegers(t *testing.T) {
	b, err := textloomManifest().Marshal()
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	s := string(b)
	for _, want := range []string{"desktop-naming: by-basename", "clean-mode: subdirs"} {
		if !strings.Contains(s, want) {
			t.Errorf("manifest does not contain %q:\n%s", want, s)
		}
	}
	if strings.Contains(s, "desktop-naming: 1") || strings.Contains(s, "clean-mode: 1") {
		t.Errorf("enum serialized as an integer:\n%s", s)
	}
}

// TestLoadRejectsUnknownField: a typo in a key must fail, not silently leave
// the field at its zero value — which for DesktopNaming would mean a
// DIFFERENT installed filename and, on Wayland, a lost window icon.
func TestLoadRejectsUnknownField(t *testing.T) {
	_, err := spec.Load([]byte("spec:\n  app: x\n  desktopnaming: by-basename\n"))
	if err == nil {
		t.Fatal("Load accepted an unknown field; a mistyped key must be an error")
	}
}

// TestShipsAndRequiresAreDifferentKeys guards the one naming decision that is
// pinned by hand rather than derived: Spec.Requires is keyed "ships" so it
// cannot collide with the manifest's build-tool "requires".
func TestShipsAndRequiresAreDifferentKeys(t *testing.T) {
	b, err := textloomManifest().Marshal()
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	s := string(b)
	if !strings.Contains(s, "ships:") {
		t.Errorf("Spec.Requires did not serialize as `ships:`:\n%s", s)
	}
	m, err := spec.Load(b)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(m.Ships()) != 1 || m.Ships()[0].Name != "libgtk-3-0" {
		t.Errorf("Ships() = %+v, want the libgtk-3-0 dependency", m.Ships())
	}
	if len(m.Requires) != 1 || m.Requires[0].Name != "flutter" {
		t.Errorf("Requires = %+v, want the flutter build tool", m.Requires)
	}
}
