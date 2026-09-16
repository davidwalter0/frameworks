package iconspec

import (
	"fmt"
	"sort"
)

// Named palettes shared across the app family.
//
// A preset is a starting point, not a constraint: a spec may name one and then
// override individual fields. The point is that "the family look" has a name
// and one definition, instead of the same six hex values being retyped per app
// and drifting.
var palettes = map[string]Palette{
	// slate — the look textloom established (itself borrowed from gatehub-kit):
	// a dark slate tile with a sky→teal foreground gradient.
	"slate": {
		TileTop:    "#1e293b",
		TileBottom: "#0f172a",
		Border:     "#334155",
		HeroStops: []Stop{
			{Color: "#bae6fd"},
			{Color: "#7dd3fc"},
			{Color: "#2dd4bf"},
		},
	},
}

// MotifColor is the dim accent the slate palette's background artwork uses.
// Kept beside the palette so a motif never invents its own tone.
const MotifColor = "#0e7490"

// PaletteByName returns a named preset.
func PaletteByName(name string) (Palette, error) {
	p, ok := palettes[name]
	if !ok {
		return Palette{}, fmt.Errorf("unknown palette %q (have: %v)", name, PaletteNames())
	}
	return p, nil
}

// PaletteNames lists the available presets, sorted for stable help output.
func PaletteNames() []string {
	names := make([]string, 0, len(palettes))
	for n := range palettes {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// resolvedStops returns the hero stops with an offset on every one.
//
// Explicit offsets win; otherwise stops are spread evenly across 0..1. Mixing
// the two is allowed but not smart about it — an explicit offset is used as
// given, and the implicit ones still use their positional share, so a spec that
// mixes them gets exactly what it wrote rather than a re-flowed gradient.
func (p Palette) resolvedStops() []Stop {
	n := len(p.HeroStops)
	out := make([]Stop, n)
	for i, s := range p.HeroStops {
		if s.Offset == nil {
			off := 0.0
			if n > 1 {
				off = float64(i) / float64(n-1)
			}
			s.Offset = &off
		}
		out[i] = s
	}
	return out
}
