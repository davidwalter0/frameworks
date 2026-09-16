// Command deps verifies a repo's declared environment prerequisites.
//
// It replaces hand-rolled `command -v` checks — a census found ~100 across 38
// repos — and, more importantly, replaces the four incompatible policies those
// checks had drifted into. See pkg/deps for that measurement.
//
// Usage from a Makefile, the same way gen-icon is already invoked:
//
//	DEPS ?= go run github.com/davidwalter0/frameworks/go/cmd/deps@go/vX.Y.Z
//	check: ; @$(DEPS) verify --profile check
//
// Exit codes are distinct and are the contract:
//
//	0  every prerequisite satisfied or acceptably absent
//	1  a required prerequisite is missing
//	2  the manifest could not be read or is invalid — the check never RAN,
//	   which is not the same as the check failing
//
// BOOTSTRAP LIMIT: a Go program cannot check whether Go is installed, and `go`
// is among the most-checked tools in the census. `go` and `make` stay inline
// shell checks in each Makefile; everything downstream of a working toolchain
// comes here. Stated plainly so nobody rediscovers it as a bug.
package main

import (
	"fmt"
	"os"

	"github.com/davidwalter0/autocfg/pkg/flags"
	"github.com/davidwalter0/frameworks/go/pkg/deps"
)

// Options is this command's whole configuration surface. Declared as a struct
// because autocfg derives the flag set from it; field names map to kebab-case
// flags, `doc:` is the help text and `default:` the default.
type Options struct {
	Profile  string `doc:"only verify prerequisites in this profile (empty: all)"`
	Dir      string `doc:"directory to search upward from for deps.yaml" default:"."`
	File     string `doc:"explicit manifest path (overrides --dir)"`
	Verbose  bool   `doc:"also list satisfied prerequisites"`
	Explain  bool   `doc:"print declared policies and exit without probing the host"`
	Nonfatal bool   `doc:"report but always exit 0; for inspecting a host, never for a gate"`
}

func parseOptions(args []string) (Options, error) {
	var opts Options
	fs, err := flags.Register(nil, &opts)
	if err != nil {
		return Options{}, err
	}
	fs.Usage = func() {
		fmt.Fprint(os.Stderr, "deps — verify declared environment prerequisites\n\n")
		fmt.Fprint(os.Stderr, flags.FlagUsagesExt(fs))
	}
	if err := fs.Parse(args); err != nil {
		return Options{}, err
	}
	return opts, nil
}

func main() {
	opts, err := parseOptions(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "deps:", err)
		os.Exit(deps.ExitManifest)
	}

	path := opts.File
	if path == "" {
		p, err := deps.Find(opts.Dir)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(deps.ExitManifest)
		}
		path = p
	}

	m, err := deps.Load(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(deps.ExitManifest)
	}

	if opts.Explain {
		explain(m, opts.Profile)
		return
	}

	rep := deps.Verify(m, opts.Profile, deps.LookPath)
	rep.Write(os.Stdout, opts.Verbose)

	// --nonfatal exists for inspecting a host, and is deliberately NOT the
	// default: a prerequisite checker that cannot fail is the same vacuous
	// gate this package was written to remove.
	if opts.Nonfatal {
		return
	}
	os.Exit(rep.ExitCode())
}

// explain prints what the manifest DECLARES without probing. The policy is the
// interesting content — "what does this repo consider fatal?" should be
// answerable on a machine that has none of the tools installed.
func explain(m deps.Manifest, profile string) {
	for _, t := range m.Requires {
		if !t.InProfile(profile) {
			continue
		}
		fmt.Printf("%-24s %-17s %s\n", t.Name, t.Policy, t.Why)
		if t.Policy == deps.OptionalDegrade {
			fmt.Printf("%-24s %-17s falls back to %s\n", "", "", t.DegradeTo)
		}
	}
}
