# gen-icon

One app-icon generator for the whole app family: an SVG plus any number of
PNGs, composed from a declarative JSON spec, **in pure Go**.

No rsvg, no Inkscape, no headless Chrome, no Python fontTools. Glyph outlines
are read with `golang.org/x/image/font/sfnt` and the composed SVG is rasterized
with `srwiley/oksvg`, so `make icon` needs nothing on the host but the Go
toolchain.

## Why it exists

Each app in the family had its own icon script — a different language and a
different set of host dependencies per repo, each drifting from the others.
This is that job done once. It is a **library plus a thin CLI**: everything real
lives in `pkg/iconspec`, so a packaging script, a test, or another app's build
can generate icons by importing it rather than shelling out.

## Quick start

```sh
# what presets exist, and what they look like
go run ./cmd/gen-icon --palettes

# what a spec may contain
go run ./cmd/gen-icon --schema

# one SVG + one 256px PNG
go run ./cmd/gen-icon --spec packaging/icon.json \
    --svg packaging/app.svg --png packaging/app.png

# a full macOS iconset
go run ./cmd/gen-icon --spec packaging/icon.json \
    --sizes 1024,512,256,128,64,32,16 \
    --png-dir macos/Runner/Assets.xcassets/AppIcon.appiconset \
    --png-pattern 'app_icon_%d.png'
```

`--help` carries the same synopsis and examples.

> Flags are **pflag long-form** and take a double dash. `-spec` parses as a
> cluster of shorthands and fails.

## Wiring it into a consuming repo

```make
GEN_ICON_DIR ?= $(HOME)/go/src/github.com/davidwalter0/frameworks/go

icon:
	go -C $(GEN_ICON_DIR) run ./cmd/gen-icon --spec $(CURDIR)/packaging/icon.json \
		--svg $(CURDIR)/packaging/app.svg --png $(CURDIR)/packaging/app.png --size 256
```

Note the `$(CURDIR)` on the spec: `go -C` runs the tool from the KIT's
directory, so a path relative to the shell's cwd would resolve in the wrong
tree. Font paths *inside* the spec are resolved relative to **the spec file**,
not the process cwd, precisely so this indirection cannot break them.

## The spec

`--schema` prints the full field reference. In brief:

| Field | Meaning |
|---|---|
| `palette.preset` | starting point (see `--palettes`); remaining fields override it |
| `palette.tileTop` / `tileBottom` / `border` | the rounded tile |
| `palette.heroStops` | ≥2 stops — the accent gradient, referenced as `"hero"` |
| `motif.svg` | raw SVG elements for the artwork |
| `motif.color` | `"hero"` for the gradient, or a `#hex` |
| `layers[]` | text runs, rendered as **outlines** |
| `layers[].font` | absolute, **or relative to the spec file** |
| `layers[].align` | `"top"` or `"bottom"`, paired with `y` |

`examples/` holds working specs.

### Text is converted to paths, never `<text>`

An SVG `<text>` icon renders differently — or not at all — on any machine
without that font installed, which for an app icon means every machine that is
not the build host.

### Motif SVG caveats (oksvg)

Both of these fail **silently** — no error, nothing drawn:

- a nested `<g transform>` is **ignored** → bake absolute coordinates;
- `rx` on `<rect>` is **ignored** → draw rounded corners as a path with arcs.

### Fonts

Prefer a font **vendored in the consuming repo** with a spec-relative path, so
the icon builds on any clone. An absolute `/usr/share/fonts/...` path ties the
build to one machine's font packages.

If you vendor a *subset*, note that fontTools drops name IDs 13/14 (the licence
and its URL) by default — a re-subset can silently ship an OFL font without its
licence. Keep all name records and gate it.

## Development

```sh
make check      # vet + lint + test
make cov        # coverage table
```

`pkg/iconspec` is the API; `cmd/gen-icon` must stay thin enough that anything
worth testing is testable without it.

## Provenance check

`examples/textloom.json` reproduces textloom's committed icon **bit-identically**
(max channel difference 0). That is the regression test for the whole pipeline:
if a change to composition, rasterization or glyph handling alters the output,
that comparison is what notices.
