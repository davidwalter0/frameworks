// Command gen-icon generates an app icon — SVG plus one or more PNGs — from a
// declarative spec, in pure Go.
//
// No rsvg, no Inkscape, no headless Chrome, no Python fonttools: glyph outlines
// are read with golang.org/x/image/font/sfnt and the composed SVG is rasterized
// with srwiley/oksvg.
//
// This is a THIN CLI. Everything real lives in pkg/iconspec so other tools (a
// packaging script, a test, another app's build) can generate icons without
// shelling out.
//
// Usage:
//
//	gen-icon --spec packaging/icon.json --svg packaging/app.svg --png packaging/app.png
//	gen-icon --spec packaging/icon.json --sizes 1024,512,256,128,64,32,16 \
//	         --png-dir macos/Runner/Assets.xcassets/AppIcon.appiconset \
//	         --png-pattern 'app_icon_%d.png'
//	gen-icon --palettes           # list the named presets
//
// Flags are pflag long-form, so they take a DOUBLE dash: `-spec` parses as a
// cluster of shorthands and fails.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/davidwalter0/autocfg/pkg/flags"

	"github.com/davidwalter0/frameworks/go/pkg/iconspec"
)

// usage prints real usage — a synopsis, worked examples and the discovery
// flags — instead of pflag's bare option dump. A generator driven by a JSON
// spec is unusable from the option list alone: the flags say WHERE output goes
// and nothing at all about what a spec must contain.
func usage(optionsText string) {
	// os.Stderr.WriteString, not fmt.Fprint: the usage text contains
	// `app_icon_%d.png`, which vet flags as a possible formatting directive in
	// a Fprint call. It is documentation, not a format string.
	// Ignored deliberately: this IS the error path's output channel, so a
	// failed write to stderr leaves nowhere to report a failed write to stderr.
	_, _ = os.Stderr.WriteString(`gen-icon — generate an app icon (SVG + PNGs) from a declarative spec, in pure Go.

USAGE
  gen-icon --spec <spec.json> [--svg <out.svg>] [--png <out.png> [--size N]]
  gen-icon --spec <spec.json> --png-dir <dir> --sizes 1024,512,256 [--png-pattern PAT]
  gen-icon --palettes          list palette presets with their colours
  gen-icon --schema            print the spec field reference

EXAMPLES
  # one SVG plus one 256px PNG
  gen-icon --spec packaging/icon.json \
           --svg packaging/app.svg --png packaging/app.png

  # a full macOS iconset
  gen-icon --spec packaging/icon.json \
           --sizes 1024,512,256,128,64,32,16 \
           --png-dir macos/Runner/Assets.xcassets/AppIcon.appiconset \
           --png-pattern 'app_icon_%d.png'

NOTES
  Flags are pflag long-form and take a DOUBLE dash: -spec parses as a cluster
  of shorthands and fails.

  Font paths inside a spec may be absolute or RELATIVE TO THE SPEC FILE, so a
  project that vendors its fonts can ship a spec that builds on any machine.

OPTIONS
`)
	_, _ = os.Stderr.WriteString(optionsText)
}

// specSchema is the --schema reference: the fields a spec may carry, which no
// list of CLI flags can convey.
const specSchema = `icon spec — JSON; all lengths are viewBox units on a 256x256 canvas.

{
  "name": "my-app",               // informational
  "palette": {                    // a preset, overridden field by field
    "preset":     "slate",        // optional starting point (see --palettes)
    "tileTop":    "#1e293b",      // rounded-tile gradient, top
    "tileBottom": "#0f172a",      // rounded-tile gradient, bottom
    "border":     "#334155",
    "heroStops": [                // >= 2 stops; the accent gradient
      {"color": "#bae6fd"}, {"color": "#7dd3fc"}, {"color": "#2dd4bf"}
    ]
  },
  "motif": {                      // optional artwork: raw SVG elements
    "svg":     "<path d=\"...\"/>",
    "color":   "hero",            // "hero" = the heroStops gradient, or #hex
    "opacity": 1.0
  },
  "layers": [                     // optional text runs, rendered as OUTLINES
    {
      "font":    "assets/fonts/Face.ttf",  // absolute, or relative to THIS file
      "text":    "abc",
      "height":  72,              // rendered height; the run scales to it
      "centerX": 128,             // horizontal centre
      "y":       226,             // edge given by "align"
      "align":   "bottom",        // "top" | "bottom"
      "fill":    "hero"           // "hero" or #hex
    }
  ]
}

Text becomes PATHS, never an SVG <text> element: a <text> icon renders
differently, or not at all, on any machine without that font installed.

Motif SVG caveats (the rasterizer is oksvg):
  - a nested <g transform> is IGNORED — bake absolute coordinates;
  - rx on <rect> is IGNORED — draw rounded corners as a path with arcs.
Both fail SILENTLY: no error, just nothing drawn.
`

// Options is this command's whole configuration surface.
//
// Declared as a struct rather than a sequence of pflag.* calls because
// autocfg derives the flag set from it (see [flags.Parse]). autocfg uses
// pflag underneath — that is autocfg's business, not a licence for this
// module to depend on pflag directly.
//
// Field names map to kebab-case flags, so PngDir is --png-dir. The `doc:`
// tag is the help text and `default:` the default, both read by autocfg.
type Options struct {
	Spec       string `doc:"icon spec JSON (required unless --palettes)"`
	SVG        string `doc:"output SVG path (empty: skip the SVG)"`
	PNG        string `doc:"output PNG path for a single size"`
	Size       int    `doc:"PNG edge length when --png is used" default:"256"`
	Sizes      string `doc:"comma-separated sizes for --png-dir mode"`
	PngDir     string `doc:"directory for multi-size output"`
	PngPattern string `doc:"filename pattern for --png-dir mode" default:"app_icon_%d.png"`
	Palettes   bool   `doc:"list named palette presets and exit"`
	Schema     bool   `doc:"print the spec field reference and exit"`
}

// parseOptions builds [Options] from args — a pure function, so the flag
// surface is testable without running the command.
//
// The flag set is registered first so `usage` can render the option list
// through autocfg's [flags.FlagUsagesExt] (which annotates env/default
// provenance) rather than pflag's bare dump. The set's type is never named
// here, which is what keeps pflag out of this module's imports entirely.
func parseOptions(args []string) (Options, error) {
	var opts Options
	fs, err := flags.Register(nil, &opts)
	if err != nil {
		return Options{}, err
	}
	fs.Usage = func() { usage(flags.FlagUsagesExt(fs)) }
	if err := fs.Parse(args); err != nil {
		return Options{}, err
	}
	return opts, nil
}

func main() {
	opts, err := parseOptions(os.Args[1:])
	if err != nil {
		fmt.Fprintf(os.Stderr, "gen-icon: %v\n", err)
		os.Exit(2)
	}

	specPath, svgOut, pngDir := &opts.Spec, &opts.SVG, &opts.PngDir
	listPals, showSchema := &opts.Palettes, &opts.Schema

	if *listPals {
		// Names alone are not usable: a preset is chosen by how it LOOKS, and
		// making the caller open the source to find out is the kind of help
		// that is technically present and practically absent.
		for _, n := range iconspec.PaletteNames() {
			p, err := iconspec.PaletteByName(n)
			if err != nil {
				fatal(err)
			}
			fmt.Printf("%-10s tile %s -> %s   border %s   hero", n, p.TileTop,
				p.TileBottom, p.Border)
			for _, st := range p.HeroStops {
				fmt.Printf(" %s", st.Color)
			}
			fmt.Println()
		}
		return
	}
	if *showSchema {
		fmt.Print(specSchema)
		return
	}
	if *specPath == "" {
		fatal(fmt.Errorf("--spec is required (see --help)"))
	}

	spec, err := iconspec.Load(*specPath)
	if err != nil {
		fatal(err)
	}

	wanted, outFor, err := resolveOutputs(opts)
	if err != nil {
		fatal(err)
	}
	if *pngDir != "" {
		if err := os.MkdirAll(*pngDir, 0o755); err != nil {
			fatal(err)
		}
	}

	if _, err := spec.Generate(*svgOut, wanted, outFor); err != nil {
		fatal(err)
	}

	var wrote []string
	if *svgOut != "" {
		wrote = append(wrote, *svgOut)
	}
	for _, n := range wanted {
		wrote = append(wrote, outFor(n))
	}
	fmt.Printf("gen-icon: %s -> %s\n", spec.Name, strings.Join(wrote, ", "))
}

// resolveOutputs decides which PNG sizes to emit and where each one goes.
//
// Extracted from main so it can be tested: it is the only real logic the CLI
// itself owns (everything else delegates to pkg/iconspec), and it carries the
// precedence rule and three distinct error cases. It performs no IO —
// creating the output directory stays in main — so a test needs no
// filesystem.
//
// Precedence: --png-dir wins over --png when both are given, because
// --png-dir is the appiconset case and --png is its single-size shorthand.
func resolveOutputs(o Options) (sizes []int, outFor func(int) string, err error) {
	switch {
	case o.PngDir != "":
		for _, tok := range strings.Split(o.Sizes, ",") {
			tok = strings.TrimSpace(tok)
			if tok == "" {
				continue
			}
			n, convErr := strconv.Atoi(tok)
			if convErr != nil {
				return nil, nil, fmt.Errorf("--sizes: %q is not a number", tok)
			}
			sizes = append(sizes, n)
		}
		if len(sizes) == 0 {
			return nil, nil, fmt.Errorf("--png-dir needs --sizes")
		}
		return sizes, func(n int) string {
			return filepath.Join(o.PngDir, fmt.Sprintf(o.PngPattern, n))
		}, nil

	case o.PNG != "":
		return []int{o.Size}, func(int) string { return o.PNG }, nil

	default:
		if o.SVG == "" {
			return nil, nil, fmt.Errorf("nothing to do: pass --svg, --png, or --png-dir")
		}
		return nil, nil, nil
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "gen-icon:", err)
	os.Exit(1)
}
