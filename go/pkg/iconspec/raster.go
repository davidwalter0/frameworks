package iconspec

import (
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"strings"

	"github.com/srwiley/oksvg"
	"github.com/srwiley/rasterx"
	xdraw "golang.org/x/image/draw"
)

// Rasterize renders an SVG document to a square PNG of the given edge length.
//
// Ported from textloom, where this stage lived in TWO copies (tools/icongen and
// tools/gen-icon) — the duplication this package exists to end.
//
// Two things the SVG alone will not give you:
//
//   - oksvg does not apply a rect's `rx` when compositing, so the tile's
//     rounded, transparent corners are masked afterwards in Go, re-deriving the
//     geometry from the spec. That is why [Spec.TileInset] / [Spec.TileRadius]
//     are spec fields rather than SVG-only details.
//   - Rendering at size*Supersample and scaling down with Catmull-Rom
//     anti-aliases the artwork AND the mask edge in one pass; masking at final
//     size leaves visibly stair-stepped corners.
func (s *Spec) Rasterize(svg, outPath string, size int) error {
	if size <= 0 {
		return fmt.Errorf("size must be > 0, got %d", size)
	}
	hi := size * s.Supersample

	icon, err := oksvg.ReadIconStream(strings.NewReader(svg), oksvg.WarnErrorMode)
	if err != nil {
		return fmt.Errorf("parse svg: %w", err)
	}
	icon.SetTarget(0, 0, float64(hi), float64(hi))
	big := image.NewRGBA(image.Rect(0, 0, hi, hi))
	scanner := rasterx.NewScannerGV(hi, hi, big, big.Bounds())
	icon.Draw(rasterx.NewDasher(hi, hi, scanner), 1.0)
	s.applyRoundedMask(big, hi)

	out := image.NewRGBA(image.Rect(0, 0, size, size))
	xdraw.CatmullRom.Scale(out, out.Bounds(), big, big.Bounds(), xdraw.Over, nil)

	f, err := os.Create(outPath)
	if err != nil {
		return err
	}
	// Close is checked, not deferred-and-dropped: for a file being WRITTEN it
	// is where a short write, a full disk or a network filesystem reports
	// itself. Dropping it means png.Encode returns nil for a truncated icon.
	// The encode error wins when both fail — it is the more specific cause.
	if err := png.Encode(f, out); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

// applyRoundedMask clears every pixel outside the rounded tile.
func (s *Spec) applyRoundedMask(img *image.RGBA, n int) {
	scale := float64(n) / s.ViewBox
	inset := s.TileInset * scale
	r := s.TileRadius * scale
	lo, hiEdge := inset, float64(n)-inset
	for y := 0; y < n; y++ {
		fy := float64(y) + 0.5
		for x := 0; x < n; x++ {
			fx := float64(x) + 0.5
			if !insideRoundedRect(fx, fy, lo, lo, hiEdge, hiEdge, r) {
				img.SetRGBA(x, y, color.RGBA{})
			}
		}
	}
}

// insideRoundedRect reports whether (px,py) lies within the rounded rectangle
// [x0,y0]-[x1,y1] with corner radius r.
func insideRoundedRect(px, py, x0, y0, x1, y1, r float64) bool {
	if px < x0 || px > x1 || py < y0 || py > y1 {
		return false
	}
	// Only the four corner squares need the radius test; everything else is
	// inside by the bounds check above.
	var cx, cy float64
	switch {
	case px < x0+r && py < y0+r:
		cx, cy = x0+r, y0+r
	case px > x1-r && py < y0+r:
		cx, cy = x1-r, y0+r
	case px < x0+r && py > y1-r:
		cx, cy = x0+r, y1-r
	case px > x1-r && py > y1-r:
		cx, cy = x1-r, y1-r
	default:
		return true
	}
	dx, dy := px-cx, py-cy
	return dx*dx+dy*dy <= r*r
}

// Generate is the whole pipeline: compose the SVG, write it, then rasterize it
// to each requested size. sizes must be non-empty; outFor maps a size to its
// output path, which is what lets one call emit a macOS appiconset.
func (s *Spec) Generate(svgPath string, sizes []int, outFor func(int) string) (string, error) {
	svg, err := s.ComposeSVG()
	if err != nil {
		return "", err
	}
	if svgPath != "" {
		if err := os.WriteFile(svgPath, []byte(svg), 0o644); err != nil {
			return "", err
		}
	}
	for _, sz := range sizes {
		if err := s.Rasterize(svg, outFor(sz), sz); err != nil {
			return "", fmt.Errorf("rasterize %dpx: %w", sz, err)
		}
	}
	return svg, nil
}
