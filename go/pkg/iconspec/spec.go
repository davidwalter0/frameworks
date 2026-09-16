// Package iconspec describes an app icon declaratively, so one generator can
// serve every app in the family.
//
// The design came out of textloom's tools/gen-icon, which produced a good icon
// through hardcoded constants — font paths, the wordmark string, the palette,
// and the motif geometry were all compile-time values in one main.go. That is
// fine for one app and useless for five. Here everything an app varies lives in
// a [Spec] (JSON on disk), and the code that consumes it is app-agnostic.
//
// The split is deliberate: this package and its siblings are a LIBRARY, and
// cmd/gen-icon is a thin CLI over it. textloom currently carries three overlapping
// tools — glyphpath (glyph -> SVG path), icongen (SVG -> PNG + corner mask,
// now uninvoked), and gen-icon (which absorbed both) — so its rounded-mask
// rasterizer exists in two copies. A library gives the family one
// implementation to collapse onto rather than a fourth.
package iconspec

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Spec is the complete description of one app icon.
//
// Zero values are filled by [Spec.ApplyDefaults] with the geometry textloom
// established (a 256 viewBox, an 8-unit transparent inset, a 52-unit corner
// radius), so a minimal spec need only name a palette and its layers.
type Spec struct {
	// Name is used only in generator output messages.
	Name string `json:"name"`

	// ViewBox is the SVG coordinate space edge length. Everything else in the
	// spec — insets, radii, layer positions — is expressed in these units, so
	// the icon is resolution-independent and the PNG size is a render-time
	// choice rather than a spec-time one.
	ViewBox float64 `json:"viewBox,omitempty"`

	// TileInset is the transparent margin between the viewBox edge and the
	// rounded tile. TileRadius is that tile's corner radius.
	//
	// Both are ALSO consumed by the rasterizer's corner mask: oksvg does not
	// apply a rect's `rx` when masking, so the generator re-derives the corner
	// geometry in Go. Keeping the two in one struct is what stops the SVG and
	// the mask from disagreeing — the failure mode being a PNG with square
	// corners bleeding past the drawn tile.
	TileInset  float64 `json:"tileInset,omitempty"`
	TileRadius float64 `json:"tileRadius,omitempty"`

	// Supersample is the render-time multiplier: the icon is rasterized at
	// size*Supersample and scaled down with a high-quality kernel, which
	// anti-aliases the artwork AND the corner-mask edge in one pass.
	Supersample int `json:"supersample,omitempty"`

	// Palette carries every colour. Named presets are available via
	// [PaletteByName] so an app can adopt a family look without copying hexes.
	Palette Palette `json:"palette"`

	// Motif is the optional dim background artwork behind the layers.
	Motif *Motif `json:"motif,omitempty"`

	// Layers are the foreground glyph runs, painted in order (last on top).
	Layers []Layer `json:"layers"`
}

// Palette is an icon's full colour set.
//
// Hero is a gradient rather than a flat fill because the family look depends on
// it; two or more stops are required, and they are distributed evenly unless a
// stop supplies its own offset.
type Palette struct {
	// Preset names a shared family palette (see PaletteNames) to start from.
	// Any field set alongside it OVERRIDES that preset's value, so an app can
	// take the family look and change one colour without restating the rest.
	//
	// This is what makes the presets usable from a spec at all: without it,
	// PaletteByName is reachable only from Go, `--palettes` is decorative, and
	// every app retypes the same six hex values — which is the drift the
	// presets exist to stop.
	Preset string `json:"preset,omitempty"`

	// TileTop / TileBottom are the vertical gradient behind everything.
	TileTop    string `json:"tileTop"`
	TileBottom string `json:"tileBottom"`

	// Border is the hairline stroke just inside the tile edge. Empty omits it.
	Border string `json:"border,omitempty"`

	// HeroStops are the foreground gradient stops, in order.
	HeroStops []Stop `json:"heroStops"`
}

// applyPreset fills empty fields from the named preset, leaving anything the
// spec set alone.
//
// An unknown name is left for Validate to report as a missing-colour error
// rather than failing here: ApplyDefaults has no error channel, and a silent
// fallback to the family default would hide a typo'd preset behind an icon
// that renders in the wrong colours.
func (p *Palette) applyPreset() {
	if p.Preset == "" {
		return
	}
	base, err := PaletteByName(p.Preset)
	if err != nil {
		return
	}
	if p.TileTop == "" {
		p.TileTop = base.TileTop
	}
	if p.TileBottom == "" {
		p.TileBottom = base.TileBottom
	}
	if p.Border == "" {
		p.Border = base.Border
	}
	if len(p.HeroStops) == 0 {
		p.HeroStops = base.HeroStops
	}
}

// Stop is one gradient stop. Offset is optional: when every stop omits it they
// are spread evenly from 0 to 1.
type Stop struct {
	Color  string   `json:"color"`
	Offset *float64 `json:"offset,omitempty"`
}

// Motif is background artwork given as a raw SVG fragment.
//
// This is deliberately an escape hatch rather than a modelled shape language.
// The motifs in this family are one-off illustrations (textloom's folding outline
// tree; voicelab' speech bubble and sound waves), and a bespoke DSL for them
// would be more code than the drawings it replaced — while a fragment is
// exactly as expressive as SVG. The generator supplies the group's opacity and
// colour so the motif still tracks the palette instead of hardcoding its own.
type Motif struct {
	// SVG is the fragment placed inside a <g>. It must not carry its own
	// fill/stroke colour — Color drives both, so a palette change moves it.
	SVG string `json:"svg"`

	// Opacity of the whole group. 0 means "unset" and defaults to 0.30, the
	// value textloom's tree uses to sit behind the wordmark without competing.
	Opacity float64 `json:"opacity,omitempty"`

	// Color is applied as both fill and stroke on the group.
	Color string `json:"color"`
}

// Align selects which edge of a layer's bounding box [Layer.Y] pins.
type Align string

const (
	// AlignTop pins the glyph run's TOP (minY) at Y.
	AlignTop Align = "top"
	// AlignBottom pins its BOTTOM (maxY) at Y — the descender, not the
	// baseline, so a wordmark with a descending glyph still clears the tile
	// edge by the amount the spec asked for.
	AlignBottom Align = "bottom"
)

// Layer is one run of text rendered from a font's glyph outlines.
//
// Text is converted to PATHS, never to an SVG <text> element: a <text> icon
// renders differently (or not at all) wherever the font is absent, which for an
// app icon means every machine that is not the build host.
type Layer struct {
	// Font is a path to a .ttf/.otf — absolute, or RELATIVE TO THE SPEC FILE.
	//
	// A path, never a family name: resolving by family would make the output
	// depend on the host's font configuration, so the same spec would render
	// differently (or not at all) on another machine. A spec-relative path is
	// just as deterministic and, unlike an absolute one, survives being cloned
	// somewhere else — so a repo that vendors its own fonts can ship a spec
	// that builds anywhere. [Load] resolves relative paths; a caller building a
	// [Spec] by hand should resolve them itself or use absolute paths.
	Font string `json:"font"`

	// Text is the run to lay out. Laid out by glyph advance width — no
	// kerning or shaping, which is adequate for the short wordmarks icons use
	// and keeps the pipeline dependency-free.
	Text string `json:"text"`

	// Height is the run's rendered height in viewBox units; the run scales
	// uniformly to it.
	Height float64 `json:"height"`

	// CenterX is where the run is horizontally centred.
	CenterX float64 `json:"centerX"`

	// Y is the pinned edge's coordinate; Align selects which edge.
	Y     float64 `json:"y"`
	Align Align   `json:"align,omitempty"`

	// Fill is a palette reference — "hero" for the hero gradient — or a
	// literal colour. Defaults to "hero".
	Fill string `json:"fill,omitempty"`
}

// Defaults, matching the geometry textloom's icon established.
const (
	DefaultViewBox     = 256.0
	DefaultTileInset   = 8.0
	DefaultTileRadius  = 52.0
	DefaultSupersample = 4
	DefaultMotifAlpha  = 0.30
)

// ApplyDefaults fills unset geometry. It does NOT invent colours or layers —
// an icon with no palette or no layers is a spec error, not a defaultable one.
func (s *Spec) ApplyDefaults() {
	s.Palette.applyPreset()
	if s.ViewBox == 0 {
		s.ViewBox = DefaultViewBox
	}
	if s.TileInset == 0 {
		s.TileInset = DefaultTileInset
	}
	if s.TileRadius == 0 {
		s.TileRadius = DefaultTileRadius
	}
	if s.Supersample == 0 {
		s.Supersample = DefaultSupersample
	}
	if s.Motif != nil && s.Motif.Opacity == 0 {
		s.Motif.Opacity = DefaultMotifAlpha
	}
	for i := range s.Layers {
		if s.Layers[i].Align == "" {
			s.Layers[i].Align = AlignTop
		}
		if s.Layers[i].Fill == "" {
			s.Layers[i].Fill = "hero"
		}
	}
}

// Validate reports the first problem that would produce a broken or silently
// empty icon. It is deliberately strict about fonts: a missing font file is the
// most common spec error and produces the least obvious failure.
func (s *Spec) Validate() error {
	if s.Palette.TileTop == "" || s.Palette.TileBottom == "" {
		return fmt.Errorf("palette: tileTop and tileBottom are required")
	}
	if len(s.Palette.HeroStops) < 2 {
		return fmt.Errorf("palette: heroStops needs at least 2 stops, got %d",
			len(s.Palette.HeroStops))
	}
	if len(s.Layers) == 0 && s.Motif == nil {
		return fmt.Errorf("spec draws nothing: no layers and no motif")
	}
	for i, l := range s.Layers {
		switch {
		case l.Font == "":
			return fmt.Errorf("layer %d (%q): font is required", i, l.Text)
		case l.Text == "":
			return fmt.Errorf("layer %d: text is empty", i)
		case l.Height <= 0:
			return fmt.Errorf("layer %d (%q): height must be > 0", i, l.Text)
		case l.Align != AlignTop && l.Align != AlignBottom:
			return fmt.Errorf("layer %d (%q): align must be %q or %q, got %q",
				i, l.Text, AlignTop, AlignBottom, l.Align)
		}
		if _, err := os.Stat(l.Font); err != nil {
			return fmt.Errorf("layer %d (%q): font %s: %w", i, l.Text, l.Font, err)
		}
	}
	return nil
}

// resolvePaths rewrites relative layer font paths against baseDir.
func (s *Spec) resolvePaths(baseDir string) {
	for i, l := range s.Layers {
		if l.Font != "" && !filepath.IsAbs(l.Font) {
			s.Layers[i].Font = filepath.Join(baseDir, l.Font)
		}
	}
}

// Load reads, defaults, resolves and validates a spec file.
//
// Layer font paths are resolved relative to the SPEC's directory, not to the
// process working directory. That distinction matters in practice: build
// systems invoke this tool from elsewhere (`go -C <tool> run ...`), so a path
// relative to the CWD would resolve against the tool's own directory rather
// than the project that owns the spec.
func Load(path string) (*Spec, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s Spec
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	s.ApplyDefaults()
	s.resolvePaths(filepath.Dir(path))
	if err := s.Validate(); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &s, nil
}
