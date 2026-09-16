package iconspec

import (
	"fmt"
	"os"
	"strings"

	"golang.org/x/image/font"
	"golang.org/x/image/font/sfnt"
	"golang.org/x/image/math/fixed"
)

// Glyph outline extraction, ported from textloom's tools/gen-icon (which in turn
// absorbed tools/glyphpath). Pure Go via sfnt — no fontconfig, no Python
// fonttools, no headless browser.
//
// Correctness notes, learned the hard way upstream and preserved here because
// both mistakes produce plausible-looking output rather than an error:
//
//   - Each CONTOUR is closed with `Z` before the next MoveTo, not one `Z` at
//     the very end. A glyph with more than one contour (any 'o', 'd', 'ξ')
//     otherwise renders as merged/unclosed subpaths with the wrong fill.
//   - Outlines are loaded at ppem == 1000 (the font's own design units) so the
//     returned control points carry no hint-grid rounding.
//   - sfnt reports Y-DOWN coordinates, which is ALSO SVG's convention, so no Y
//     flip is applied. Adding one "to fix" upside-down text is the classic
//     wrong turn here — if text looks flipped, the transform is at fault, not
//     the axis.

// bbox is a glyph run's bounds in design space.
type bbox struct{ minX, minY, maxX, maxY float64 }

func (b bbox) width() float64  { return b.maxX - b.minX }
func (b bbox) height() float64 { return b.maxY - b.minY }

// wordPath lays out text left-to-right by glyph advance width and returns one
// combined SVG path plus its bounds, in the font's Y-down design space.
func wordPath(fontPath, text string) (string, bbox, error) {
	raw, err := os.ReadFile(fontPath)
	if err != nil {
		return "", bbox{}, err
	}
	fnt, err := sfnt.Parse(raw)
	if err != nil {
		return "", bbox{}, fmt.Errorf("parse font %s: %w", fontPath, err)
	}
	var buf sfnt.Buffer
	var b strings.Builder
	bb := bbox{1e18, 1e18, -1e18, -1e18}
	penX := 0.0
	for _, r := range text {
		gi, err := fnt.GlyphIndex(&buf, r)
		if err != nil || gi == 0 {
			// A missing glyph is fatal rather than skipped: silently dropping
			// a character yields an icon that is subtly wrong (a wordmark
			// short one letter) instead of a build that fails.
			return "", bbox{}, fmt.Errorf("font %s has no glyph for %q",
				fontPath, string(r))
		}
		segs, err := fnt.LoadGlyph(&buf, gi, fixed.I(1000), nil)
		if err != nil {
			return "", bbox{}, err
		}
		d, gb := segmentsToPath(segs, penX)
		b.WriteString(d)
		b.WriteByte(' ')
		// A space has no contours, so its bbox stays at the sentinel — folding
		// it in would poison the run's bounds.
		if gb.maxX > gb.minX {
			bb.minX = min(bb.minX, gb.minX)
			bb.minY = min(bb.minY, gb.minY)
			bb.maxX = max(bb.maxX, gb.maxX)
			bb.maxY = max(bb.maxY, gb.maxY)
		}
		adv, err := fnt.GlyphAdvance(&buf, gi, fixed.I(1000), font.HintingNone)
		if err != nil {
			return "", bbox{}, err
		}
		penX += float64(adv) / 64.0
	}
	if bb.width() <= 0 || bb.height() <= 0 {
		return "", bbox{}, fmt.Errorf("%q in %s produced no outline", text, fontPath)
	}
	return b.String(), bb, nil
}

// segmentsToPath converts sfnt segments to an SVG path offset in X by dx, and
// returns the path plus its bounds.
func segmentsToPath(segs []sfnt.Segment, dx float64) (string, bbox) {
	bb := bbox{1e18, 1e18, -1e18, -1e18}
	var b strings.Builder
	started := false
	pt := func(p fixed.Point26_6) (float64, float64) {
		x := float64(p.X)/64.0 + dx
		y := float64(p.Y) / 64.0 // sfnt is already Y-down, like SVG
		bb.minX, bb.minY = min(bb.minX, x), min(bb.minY, y)
		bb.maxX, bb.maxY = max(bb.maxX, x), max(bb.maxY, y)
		return x, y
	}
	for _, s := range segs {
		switch s.Op {
		case sfnt.SegmentOpMoveTo:
			if started {
				b.WriteString("Z ")
			}
			started = true
			x, y := pt(s.Args[0])
			fmt.Fprintf(&b, "M%.1f %.1f ", x, y)
		case sfnt.SegmentOpLineTo:
			x, y := pt(s.Args[0])
			fmt.Fprintf(&b, "L%.1f %.1f ", x, y)
		case sfnt.SegmentOpQuadTo:
			x1, y1 := pt(s.Args[0])
			x, y := pt(s.Args[1])
			fmt.Fprintf(&b, "Q%.1f %.1f %.1f %.1f ", x1, y1, x, y)
		case sfnt.SegmentOpCubeTo:
			x1, y1 := pt(s.Args[0])
			x2, y2 := pt(s.Args[1])
			x, y := pt(s.Args[2])
			fmt.Fprintf(&b, "C%.1f %.1f %.1f %.1f %.1f %.1f ", x1, y1, x2, y2, x, y)
		}
	}
	if started {
		b.WriteString("Z")
	}
	return b.String(), bb
}

// transformFor returns the SVG transform mapping a design-space run into the
// viewBox: scaled to height h, horizontally centred on cx, with the edge named
// by align pinned at y.
//
// The scale is plain-positive — no flip — because design space is already
// Y-down (see the package note above).
func transformFor(bb bbox, h, cx, y float64, align Align) string {
	sc := h / bb.height()
	w := bb.width() * sc
	tx := cx - w/2 - bb.minX*sc
	var ty float64
	if align == AlignBottom {
		ty = y - bb.maxY*sc
	} else {
		ty = y - bb.minY*sc
	}
	return fmt.Sprintf("translate(%.3f,%.3f) scale(%.5f,%.5f)", tx, ty, sc, sc)
}
