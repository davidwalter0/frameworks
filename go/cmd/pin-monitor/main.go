// pin-monitor audits how the desktop_kit consumer repos pin the shared
// package and reports drift against the latest released semver tag.
//
// Exit codes: 0 = every consumer converged on the latest tag; 1 = drift
// (lagging tag, raw SHA, mutable ref, path dep, or missing); 2 = usage or
// environment error.
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/davidwalter0/autocfg/pkg/flags"

	"github.com/davidwalter0/frameworks/go/pkg/pins"
)

// Options is this command's whole configuration surface.
//
// Declared as a struct rather than a sequence of pflag.*Var calls because
// autocfg derives the flag set from it (see [flags.Parse]). autocfg still
// uses pflag underneath — that is autocfg's business, not a licence for this
// module to depend on pflag directly.
//
// The practical gain beyond convention: parsing becomes a pure function of
// args, so `run` is testable without spawning a process.
type Options struct {
	Config  string `doc:"path to consumers.yaml"`
	Offline bool   `doc:"skip the git fetch --tags refresh (use local tags)"`
}

func main() {
	os.Exit(run(os.Args[1:]))
}

// parseOptions builds [Options] from args. `config` takes its default from
// [defaultConfigPath] at parse time rather than from a `default:` tag,
// because it is resolved relative to the executable.
func parseOptions(args []string) (Options, error) {
	opts := Options{Config: defaultConfigPath()}
	if _, err := flags.Parse(nil, &opts, args); err != nil {
		return Options{}, err
	}
	return opts, nil
}

func run(args []string) int {
	opts, err := parseOptions(args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "pin-monitor: %v\n", err)
		return 2
	}
	configPath, offline := opts.Config, opts.Offline

	data, err := os.ReadFile(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "pin-monitor: read config: %v\n", err)
		return 2
	}
	cfg, err := pins.ParseConfig(data)
	if err != nil {
		fmt.Fprintf(os.Stderr, "pin-monitor: %v\n", err)
		return 2
	}

	if !offline {
		if err := pins.FetchTags(cfg.DepRepo); err != nil {
			// Offline is survivable — local tags are usually current enough.
			fmt.Fprintf(os.Stderr, "pin-monitor: warning: %v (continuing with local tags)\n", err)
		}
	}
	tags, err := pins.RepoTags(cfg.DepRepo)
	if err != nil {
		fmt.Fprintf(os.Stderr, "pin-monitor: %v\n", err)
		return 2
	}
	latest := pins.LatestSemverTag(tags)

	rows := make([]pins.Row, 0, len(cfg.Consumers))
	for _, c := range cfg.Consumers {
		row := pins.Row{Consumer: c.Name}
		body, err := os.ReadFile(c.Pubspec)
		if err != nil {
			fmt.Fprintf(os.Stderr, "pin-monitor: %s: %v\n", c.Name, err)
			row.Pin = pins.Pin{Kind: pins.KindMissing}
			row.Status = pins.StatusMissing
			rows = append(rows, row)
			continue
		}
		pin, err := pins.ParsePubspecDep(body, cfg.Dep)
		if err != nil {
			fmt.Fprintf(os.Stderr, "pin-monitor: %s: %v\n", c.Name, err)
			pin = pins.Pin{Kind: pins.KindMissing}
		}
		row.Pin = pin
		row.Status = pins.Classify(pin, latest)
		rows = append(rows, row)
	}

	fmt.Print(pins.RenderTable(rows, cfg.Dep, latest))
	if pins.Drifted(rows) {
		fmt.Println("\nDRIFT detected — see rows above (non-converged).")
		return 1
	}
	fmt.Println("\nAll consumers converged.")
	return 0
}

// defaultConfigPath resolves consumers.yaml beside the binary's source layout:
// the tool dir when run via `go run`/Makefile, falling back to CWD.
func defaultConfigPath() string {
	if exe, err := os.Executable(); err == nil {
		// bin/pin-monitor → ../consumers.yaml (tool root)
		p := filepath.Join(filepath.Dir(exe), "..", "consumers.yaml")
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return "consumers.yaml"
}
