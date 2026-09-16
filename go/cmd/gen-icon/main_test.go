package main

import "testing"

// The flag surface is the whole contract of this command — everything else
// lives in pkg/iconspec and is tested there. These pin the mapping autocfg
// derives from the Options struct, which is exactly the part a rename or a
// tag typo breaks silently: a flag that stops being recognised does not fail
// loudly, it takes the zero value and generates the wrong icon.

func TestParseOptionsDefaults(t *testing.T) {
	opts, err := parseOptions(nil)
	if err != nil {
		t.Fatal(err)
	}
	if opts.Size != 256 {
		t.Errorf("Size default: got %d, want 256", opts.Size)
	}
	if opts.PngPattern != "app_icon_%d.png" {
		t.Errorf("PngPattern default: got %q", opts.PngPattern)
	}
	if opts.Spec != "" || opts.SVG != "" || opts.PNG != "" {
		t.Errorf("path flags should default empty: %+v", opts)
	}
	if opts.Palettes || opts.Schema {
		t.Errorf("discovery flags should default false: %+v", opts)
	}
}

func TestParseOptionsLongForm(t *testing.T) {
	opts, err := parseOptions([]string{
		"--spec", "icon.json",
		"--svg", "out.svg",
		"--png", "out.png",
		"--size", "512",
	})
	if err != nil {
		t.Fatal(err)
	}
	if opts.Spec != "icon.json" || opts.SVG != "out.svg" || opts.PNG != "out.png" {
		t.Errorf("paths not parsed: %+v", opts)
	}
	if opts.Size != 512 {
		t.Errorf("Size: got %d, want 512", opts.Size)
	}
}

// A multi-word field must reach the CLI kebab-cased. This is the assertion
// that would have caught PngDir arriving as --pngdir.
func TestParseOptionsKebabCasesMultiWordFields(t *testing.T) {
	opts, err := parseOptions([]string{
		"--png-dir", "iconset",
		"--png-pattern", "app_%d.png",
		"--sizes", "1024,512",
	})
	if err != nil {
		t.Fatal(err)
	}
	if opts.PngDir != "iconset" {
		t.Errorf("--png-dir: got %q", opts.PngDir)
	}
	if opts.PngPattern != "app_%d.png" {
		t.Errorf("--png-pattern: got %q", opts.PngPattern)
	}
	if opts.Sizes != "1024,512" {
		t.Errorf("--sizes: got %q", opts.Sizes)
	}
}

func TestParseOptionsRejectsUnknownFlag(t *testing.T) {
	if _, err := parseOptions([]string{"--nope"}); err == nil {
		t.Fatal("an unknown flag must be an error, not silently ignored")
	}
}

// Documented in this command's own header: flags are long-form, so a single
// dash parses as a shorthand cluster and fails. Pinned so the claim in the
// docs stays true.
func TestParseOptionsSingleDashIsNotLongForm(t *testing.T) {
	if _, err := parseOptions([]string{"-spec", "icon.json"}); err == nil {
		t.Fatal("-spec should parse as a shorthand cluster and fail")
	}
}

// resolveOutputs owns the CLI's only real logic — the precedence rule and
// three error cases. Pure, so these need no filesystem.

func TestResolveOutputsPngDirBeatsPng(t *testing.T) {
	sizes, outFor, err := resolveOutputs(Options{
		PngDir: "iconset", Sizes: "1024,512", PngPattern: "app_%d.png",
		PNG: "single.png", Size: 256,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(sizes) != 2 || sizes[0] != 1024 || sizes[1] != 512 {
		t.Errorf("sizes: got %v, want [1024 512]", sizes)
	}
	if got := outFor(512); got != "iconset/app_512.png" {
		t.Errorf("outFor(512): got %q", got)
	}
}

func TestResolveOutputsSinglePng(t *testing.T) {
	sizes, outFor, err := resolveOutputs(Options{PNG: "out.png", Size: 128})
	if err != nil {
		t.Fatal(err)
	}
	if len(sizes) != 1 || sizes[0] != 128 {
		t.Errorf("sizes: got %v, want [128]", sizes)
	}
	if got := outFor(128); got != "out.png" {
		t.Errorf("outFor: got %q", got)
	}
}

func TestResolveOutputsSvgOnly(t *testing.T) {
	sizes, _, err := resolveOutputs(Options{SVG: "out.svg"})
	if err != nil {
		t.Fatal(err)
	}
	if len(sizes) != 0 {
		t.Errorf("SVG-only should request no PNG sizes, got %v", sizes)
	}
}

func TestResolveOutputsSizesTolerateWhitespaceAndEmpties(t *testing.T) {
	sizes, _, err := resolveOutputs(Options{
		PngDir: "d", PngPattern: "%d.png", Sizes: " 64 , ,32,",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(sizes) != 2 || sizes[0] != 64 || sizes[1] != 32 {
		t.Errorf("sizes: got %v, want [64 32]", sizes)
	}
}

func TestResolveOutputsErrors(t *testing.T) {
	for _, tc := range []struct {
		name string
		o    Options
	}{
		{"non-numeric size", Options{PngDir: "d", Sizes: "big"}},
		{"png-dir without sizes", Options{PngDir: "d"}},
		{"nothing requested", Options{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, _, err := resolveOutputs(tc.o); err == nil {
				t.Fatal("expected an error")
			}
		})
	}
}
