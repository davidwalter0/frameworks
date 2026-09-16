package iconspec

import (
	"image"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A font every host in this family has; the icon specs use it too.
const testFont = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

func requireFont(t *testing.T) {
	t.Helper()
	if _, err := os.Stat(testFont); err != nil {
		t.Skipf("font %s unavailable: %v", testFont, err)
	}
}

func minimalSpec() *Spec {
	p, _ := PaletteByName("slate")
	s := &Spec{
		Name:    "test",
		Palette: p,
		Layers:  []Layer{{Font: testFont, Text: "tts", Height: 60, CenterX: 128, Y: 200, Align: AlignBottom}},
	}
	s.ApplyDefaults()
	return s
}

func TestApplyDefaults(t *testing.T) {
	tests := []struct {
		name string
		in   Spec
		want Spec
	}{
		{
			name: "empty geometry gets the textloom defaults",
			in:   Spec{},
			want: Spec{ViewBox: 256, TileInset: 8, TileRadius: 52, Supersample: 4},
		},
		{
			name: "explicit values are preserved",
			in:   Spec{ViewBox: 512, TileInset: 16, TileRadius: 104, Supersample: 2},
			want: Spec{ViewBox: 512, TileInset: 16, TileRadius: 104, Supersample: 2},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.in
			got.ApplyDefaults()
			if got.ViewBox != tt.want.ViewBox || got.TileInset != tt.want.TileInset ||
				got.TileRadius != tt.want.TileRadius || got.Supersample != tt.want.Supersample {
				t.Errorf("got %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestApplyDefaultsPerLayer(t *testing.T) {
	s := Spec{Layers: []Layer{{}, {Align: AlignBottom, Fill: "#fff"}}}
	s.ApplyDefaults()
	if s.Layers[0].Align != AlignTop || s.Layers[0].Fill != "hero" {
		t.Errorf("layer 0 defaults: got align=%q fill=%q", s.Layers[0].Align, s.Layers[0].Fill)
	}
	if s.Layers[1].Align != AlignBottom || s.Layers[1].Fill != "#fff" {
		t.Error("explicit layer values must survive defaulting")
	}
}

func TestValidate(t *testing.T) {
	requireFont(t)
	ok := minimalSpec()
	tests := []struct {
		name    string
		mutate  func(*Spec)
		wantErr string
	}{
		{"valid", func(*Spec) {}, ""},
		{"no tile colours", func(s *Spec) { s.Palette.TileTop = "" }, "tileTop and tileBottom"},
		{"one hero stop", func(s *Spec) { s.Palette.HeroStops = s.Palette.HeroStops[:1] }, "at least 2 stops"},
		{"draws nothing", func(s *Spec) { s.Layers = nil; s.Motif = nil }, "draws nothing"},
		{"missing font path", func(s *Spec) { s.Layers[0].Font = "" }, "font is required"},
		{"font does not exist", func(s *Spec) { s.Layers[0].Font = "/nope/none.ttf" }, "no such file"},
		{"empty text", func(s *Spec) { s.Layers[0].Text = "" }, "text is empty"},
		{"zero height", func(s *Spec) { s.Layers[0].Height = 0 }, "height must be > 0"},
		{"bad align", func(s *Spec) { s.Layers[0].Align = "middle" }, "align must be"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := *ok
			s.Layers = append([]Layer(nil), ok.Layers...)
			tt.mutate(&s)
			err := s.Validate()
			switch {
			case tt.wantErr == "" && err != nil:
				t.Fatalf("unexpected error: %v", err)
			case tt.wantErr != "" && err == nil:
				t.Fatalf("want error containing %q, got nil", tt.wantErr)
			case tt.wantErr != "" && !strings.Contains(err.Error(), tt.wantErr):
				t.Fatalf("want error containing %q, got %v", tt.wantErr, err)
			}
		})
	}
}

func TestResolvedStopsSpreadEvenly(t *testing.T) {
	p, err := PaletteByName("slate")
	if err != nil {
		t.Fatal(err)
	}
	got := p.resolvedStops()
	want := []float64{0, 0.5, 1}
	if len(got) != len(want) {
		t.Fatalf("got %d stops, want %d", len(got), len(want))
	}
	for i, w := range want {
		if math.Abs(*got[i].Offset-w) > 1e-9 {
			t.Errorf("stop %d offset = %g, want %g", i, *got[i].Offset, w)
		}
	}
}

func TestResolvedStopsHonourExplicitOffset(t *testing.T) {
	off := 0.25
	p := Palette{HeroStops: []Stop{{Color: "#000", Offset: &off}, {Color: "#fff"}}}
	got := p.resolvedStops()
	if *got[0].Offset != 0.25 {
		t.Errorf("explicit offset overwritten: got %g", *got[0].Offset)
	}
}

func TestPaletteByNameUnknown(t *testing.T) {
	if _, err := PaletteByName("nope"); err == nil {
		t.Fatal("want an error for an unknown palette")
	}
}

func TestInsideRoundedRect(t *testing.T) {
	// A 100x100 rect at (0,0) with r=20.
	tests := []struct {
		name string
		x, y float64
		want bool
	}{
		{"centre", 50, 50, true},
		{"left edge midway", 0.5, 50, true},
		{"outside left", -1, 50, false},
		{"outside below", 50, 101, false},
		{"corner cut away", 1, 1, false},
		{"corner arc inside", 20, 20, true},
		{"top-right cut", 99, 1, false},
		{"bottom-left cut", 1, 99, false},
		{"bottom-right cut", 99, 99, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := insideRoundedRect(tt.x, tt.y, 0, 0, 100, 100, 20); got != tt.want {
				t.Errorf("insideRoundedRect(%g,%g) = %v, want %v", tt.x, tt.y, got, tt.want)
			}
		})
	}
}

func TestTransformForAlignment(t *testing.T) {
	// A 100-wide, 50-tall run in design space.
	bb := bbox{minX: 0, minY: 0, maxX: 100, maxY: 50}
	// Scaled to height 100 => scale 2 => width 200 => centred on 128 => tx=28.
	top := transformFor(bb, 100, 128, 10, AlignTop)
	if !strings.Contains(top, "translate(28.000,10.000)") || !strings.Contains(top, "scale(2.00000,2.00000)") {
		t.Errorf("AlignTop transform = %q", top)
	}
	// Bottom-aligned pins maxY (50*2=100) at y=200 => ty = 100.
	bot := transformFor(bb, 100, 128, 200, AlignBottom)
	if !strings.Contains(bot, "translate(28.000,100.000)") {
		t.Errorf("AlignBottom transform = %q", bot)
	}
}

func TestComposeSVGStructure(t *testing.T) {
	requireFont(t)
	s := minimalSpec()
	s.Motif = &Motif{SVG: `<circle cx="10" cy="10" r="5"/>`, Color: MotifColor}
	s.ApplyDefaults()

	svg, err := s.ComposeSVG()
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`viewBox="0 0 256 256"`,
		`id="tile"`, `id="hero"`,
		s.Palette.TileTop, s.Palette.TileBottom, s.Palette.Border,
		`opacity="0.3"`, MotifColor, `<circle`,
		`fill="url(#hero)"`,
		`<path d="M`, // the wordmark became PATHS, not a <text> element
	} {
		if !strings.Contains(svg, want) {
			t.Errorf("composed SVG missing %q", want)
		}
	}
	if strings.Contains(svg, "<text") {
		t.Error("text must be emitted as paths, never as <text> (font-dependent)")
	}
}

func TestComposeSVGMissingGlyphIsFatal(t *testing.T) {
	requireFont(t)
	s := minimalSpec()
	// A rune DejaVuSans has no glyph for — a CJK ideograph. (Emoji code points
	// are a bad probe here: DejaVu maps several of them.) Must fail loudly
	// rather than silently drop the character.
	s.Layers[0].Text = "漢"
	if _, err := s.ComposeSVG(); err == nil {
		t.Fatal("want an error for a missing glyph, got nil")
	}
}

func TestRasterizeWritesSquarePNGWithTransparentCorners(t *testing.T) {
	requireFont(t)
	s := minimalSpec()
	s.Supersample = 1 // keep the test fast
	svg, err := s.ComposeSVG()
	if err != nil {
		t.Fatal(err)
	}
	out := t.TempDir() + "/icon.png"
	if err := s.Rasterize(svg, out, 64); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(out)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = f.Close() }()
	img, err := decodePNG(f)
	if err != nil {
		t.Fatal(err)
	}
	b := img.Bounds()
	if b.Dx() != 64 || b.Dy() != 64 {
		t.Fatalf("got %dx%d, want 64x64", b.Dx(), b.Dy())
	}
	// The corner must be masked transparent — the whole reason the mask is
	// re-derived in Go rather than left to the SVG's rx.
	if _, _, _, a := img.At(0, 0).RGBA(); a != 0 {
		t.Errorf("corner pixel alpha = %d, want 0 (rounded mask not applied)", a)
	}
	// The centre must be painted.
	if _, _, _, a := img.At(32, 32).RGBA(); a == 0 {
		t.Error("centre pixel is transparent — nothing was drawn")
	}
}

func TestRasterizeRejectsBadSize(t *testing.T) {
	s := minimalSpec()
	if err := s.Rasterize("<svg/>", t.TempDir()+"/x.png", 0); err == nil {
		t.Fatal("want an error for size 0")
	}
}

// decodePNG keeps the image/png import out of the non-test build.
func decodePNG(f *os.File) (image.Image, error) { return png.Decode(f) }

// TestLoadResolvesFontRelativeToSpec pins the path rule that makes a spec
// portable between machines.
//
// The failure it guards is not hypothetical: consuming repos invoke this tool
// as `go -C <kit>/tools/gen-icon run ./cmd/gen-icon --spec <project>/icon.json`,
// so the process cwd is the KIT's directory, not the project's. A font path
// resolved against the cwd would be looked up inside the tool's own tree. Only
// resolution against the SPEC's directory lets a project vendor its fonts and
// still build anywhere.
func TestLoadResolvesFontRelativeToSpec(t *testing.T) {
	dir := t.TempDir()
	fontDir := filepath.Join(dir, "assets", "fonts")
	if err := os.MkdirAll(fontDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Validate() only stats the font, so an empty file is enough to prove the
	// path resolved; rendering is covered elsewhere.
	fontPath := filepath.Join(fontDir, "face.ttf")
	if err := os.WriteFile(fontPath, []byte{0}, 0o644); err != nil {
		t.Fatal(err)
	}

	specPath := filepath.Join(dir, "icon.json")
	spec := `{
	  "name": "rel",
	  "palette": {"preset": "slate"},
	  "layers": [{
	    "font": "assets/fonts/face.ttf",
	    "text": "ab", "height": 40, "centerX": 128, "y": 200, "align": "bottom"
	  }]
	}`
	if err := os.WriteFile(specPath, []byte(spec), 0o644); err != nil {
		t.Fatal(err)
	}

	// Run from somewhere that is NOT the spec's directory — the whole point.
	t.Chdir(t.TempDir())

	got, err := Load(specPath)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.Layers[0].Font != fontPath {
		t.Errorf("font path = %q, want %q", got.Layers[0].Font, fontPath)
	}
}

// TestLoadLeavesAbsoluteFontPathAlone — an absolute path must survive
// untouched, or every existing spec breaks.
func TestLoadLeavesAbsoluteFontPathAlone(t *testing.T) {
	dir := t.TempDir()
	fontPath := filepath.Join(dir, "abs.ttf")
	if err := os.WriteFile(fontPath, []byte{0}, 0o644); err != nil {
		t.Fatal(err)
	}
	specPath := filepath.Join(dir, "icon.json")
	spec := `{
	  "name": "abs",
	  "palette": {"preset": "slate"},
	  "layers": [{
	    "font": "` + fontPath + `",
	    "text": "ab", "height": 40, "centerX": 128, "y": 200, "align": "bottom"
	  }]
	}`
	if err := os.WriteFile(specPath, []byte(spec), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := Load(specPath)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.Layers[0].Font != fontPath {
		t.Errorf("font path = %q, want it unchanged (%q)", got.Layers[0].Font, fontPath)
	}
}

// TestPalettePresetIsUsableFromASpec — the presets exist so an app can say
// "the family look" by name instead of retyping six hex values. Until the
// spec could NAME one, PaletteByName was reachable only from Go and
// `--palettes` listed colours a spec had no way to ask for.
func TestPalettePresetIsUsableFromASpec(t *testing.T) {
	var s Spec
	s.Palette.Preset = "slate"
	s.ApplyDefaults()

	want, err := PaletteByName("slate")
	if err != nil {
		t.Fatal(err)
	}
	if s.Palette.TileTop != want.TileTop || s.Palette.TileBottom != want.TileBottom {
		t.Errorf("tile = %s/%s, want %s/%s", s.Palette.TileTop,
			s.Palette.TileBottom, want.TileTop, want.TileBottom)
	}
	if len(s.Palette.HeroStops) != len(want.HeroStops) {
		t.Fatalf("heroStops = %d, want %d", len(s.Palette.HeroStops), len(want.HeroStops))
	}
}

// TestPalettePresetFieldsAreOverridable — a preset is a starting point, not a
// constraint: an app takes the family look and changes one colour.
func TestPalettePresetFieldsAreOverridable(t *testing.T) {
	var s Spec
	s.Palette.Preset = "slate"
	s.Palette.TileTop = "#123456"
	s.ApplyDefaults()

	if s.Palette.TileTop != "#123456" {
		t.Errorf("explicit tileTop was overwritten by the preset: %s", s.Palette.TileTop)
	}
	base, _ := PaletteByName("slate")
	if s.Palette.TileBottom != base.TileBottom {
		t.Errorf("unset tileBottom = %s, want the preset's %s",
			s.Palette.TileBottom, base.TileBottom)
	}
}

// TestUnknownPresetSurfacesAsAValidationError — a typo must not silently
// render the family default; it must be reported.
func TestUnknownPresetSurfacesAsAValidationError(t *testing.T) {
	var s Spec
	s.Palette.Preset = "sl8te"
	s.ApplyDefaults()
	if err := s.Validate(); err == nil {
		t.Fatal("a misspelled preset validated; expected a missing-colour error")
	}
}
