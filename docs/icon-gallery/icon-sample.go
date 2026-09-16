// icon-sample reports an icon PNG's dimensions, its corner alpha (a rounded
// tile must be transparent at the very corner), and how much distinct ink it
// carries — enough to tell "the glyph drew" from "the glyph is missing and the
// tile rendered anyway", which is the failure a spec review cannot catch.
//
// go run icon-sample.go <png>...
package main

import (
	"fmt"
	"image"
	_ "image/png"
	"os"
)

func main() {
	for _, p := range os.Args[1:] {
		f, err := os.Open(p)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		im, _, err := image.Decode(f)
		_ = f.Close()
		if err != nil {
			fmt.Fprintln(os.Stderr, p+":", err)
			os.Exit(1)
		}
		b := im.Bounds()

		// Distinct opaque colours, and the fraction of pixels that are not the
		// tile background. A tile with no artwork lands near zero.
		// Background is the MODE of the opaque pixels, not a sampled point.
		// Sampling a fixed point (top-centre) is wrong for any icon whose
		// artwork reaches it — netroute-manager's ingress box, cross-bridge's
		// screen and voicelab's speech bubble all do, and the mistake inverts
		// the reading: the true tile then counts as ink and the figure lands
		// above 80%. The tile is by construction the largest flat region, so
		// the mode is the robust estimator.
		colors := map[uint32]int{}
		var opaque int
		cx, cy := b.Min.X+b.Dx()/2, b.Min.Y+b.Dy()/2
		for y := b.Min.Y; y < b.Max.Y; y++ {
			for x := b.Min.X; x < b.Max.X; x++ {
				_, _, _, a := im.At(x, y).RGBA()
				if a>>8 < 128 {
					continue
				}
				opaque++
				r, g, bl, _ := im.At(x, y).RGBA()
				colors[(r>>8)<<16|(g>>8)<<8|(bl>>8)]++
			}
		}
		var bgKey uint32
		var bgCount int
		for k, n := range colors {
			if n > bgCount {
				bgKey, bgCount = k, n
			}
		}
		bgR, bgG, bgB := int(bgKey>>16&0xff), int(bgKey>>8&0xff), int(bgKey&0xff)
		var ink int
		for y := b.Min.Y; y < b.Max.Y; y++ {
			for x := b.Min.X; x < b.Max.X; x++ {
				r, g, bl, a := im.At(x, y).RGBA()
				if a>>8 < 128 {
					continue
				}
				dr, dg, db := int(r>>8)-bgR, int(g>>8)-bgG, int(bl>>8)-bgB
				if dr*dr+dg*dg+db*db > 900 { // >30 per-channel euclidean
					ink++
				}
			}
		}
		at := func(x, y int) string {
			r, g, bl, a := im.At(x, y).RGBA()
			return fmt.Sprintf("#%02x%02x%02x/a%d", r>>8, g>>8, bl>>8, a>>8)
		}

		fmt.Printf("%-46s %4dx%-4d corner %-14s centre %-14s colors %-5d ink %5.1f%%\n",
			shorten(p), b.Dx(), b.Dy(), at(b.Min.X, b.Min.Y), at(cx, cy),
			len(colors), 100*float64(ink)/float64(opaque))
	}
}

func shorten(p string) string {
	if len(p) <= 46 {
		return p
	}
	return "..." + p[len(p)-43:]
}
