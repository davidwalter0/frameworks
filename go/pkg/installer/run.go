package installer

import (
	"fmt"
	"os"

	"github.com/davidwalter0/autocfg/pkg/flags"
	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

// RunFlags is the standard installer flag surface, declared as a struct so
// autocfg can derive the flag set from it (see [flags.Parse]). autocfg uses
// pflag underneath — that is autocfg's business, not a licence for this
// module to depend on pflag directly.
//
// Distinct from [Options], which is the installer's runtime configuration:
// these are the CLI's inputs, that is what the install actually runs with.
// Keeping them apart means a consumer calling [Install] directly never has
// to know a flag surface exists.
type RunFlags struct {
	Prefix    string `doc:"install prefix"`
	Uninstall bool   `doc:"remove a previous install and exit"`
	Version   bool   `short:"V" doc:"print version and exit"`
}

// ParseRunFlags builds [RunFlags] from args. Prefix defaults to
// [DefaultPrefix] at parse time rather than via a `default:` tag because it
// is resolved from the environment.
func ParseRunFlags(args []string) (RunFlags, error) {
	rf := RunFlags{Prefix: DefaultPrefix()}
	if _, err := flags.Parse(nil, &rf, args); err != nil {
		return RunFlags{}, err
	}
	return rf, nil
}

// Run is the whole main() of a consuming installer: it parses the standard
// flags (--prefix, --uninstall, --version), dispatches, and exits non-zero on
// failure.
//
//	func main() { installer.Run(spec, payload, version) }
//
// Consumers that need extra flags should call [Install] / [Uninstall] directly
// rather than growing this function — the point of the shared package is that
// the common path is identical everywhere.
func Run(s Spec, payload []byte, version string) {
	rf, err := ParseRunFlags(os.Args[1:])
	if err != nil {
		fatal(err)
	}

	if rf.Version {
		fmt.Printf("%s installer %s\n", s.DisplayNameOrDefault(), version)
		return
	}

	opt := Options{Prefix: rf.Prefix}

	if rf.Uninstall {
		if err := Uninstall(s, opt); err != nil {
			fatal(err)
		}
		fmt.Printf("Removed %s from %s\n", s.DisplayNameOrDefault(), rf.Prefix)
		return
	}

	if err := Install(s, payload, version, opt); err != nil {
		fatal(err)
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}

// RunManifest is [Run] for a consumer whose declaration lives in a
// manifest.yaml rather than a Go literal:
//
//	//go:embed manifest.yaml
//	var manifest []byte
//
//	func main() { installer.RunManifest(manifest, payload, version) }
//
// The manifest is parsed for the Spec AND carried through to the installed
// tree verbatim, so the document that drove the install is the document the
// install records. That is the whole reason to prefer this over Run: a Spec
// compiled into a binary is invisible to the packager that needs its ships
// list, to a dependency check run against an installed tree, and to a reviewer
// reading a diff.
//
// A manifest that does not parse, or does not validate, is a hard failure
// before anything is written — the alternative is a half-installed tree
// described by a document nobody could read.
func RunManifest(manifest, payload []byte, version string) {
	m, err := spec.Load(manifest)
	if err != nil {
		fatal(err)
	}
	if err := m.Validate(); err != nil {
		fatal(err)
	}

	rf, err := ParseRunFlags(os.Args[1:])
	if err != nil {
		fatal(err)
	}

	s := m.Spec
	if rf.Version {
		fmt.Printf("%s installer %s\n", s.DisplayNameOrDefault(), version)
		return
	}

	opt := Options{Prefix: rf.Prefix, Manifest: manifest}

	if rf.Uninstall {
		if err := Uninstall(s, opt); err != nil {
			fatal(err)
		}
		fmt.Printf("Removed %s from %s\n", s.DisplayNameOrDefault(), rf.Prefix)
		return
	}

	if err := Install(s, payload, version, opt); err != nil {
		fatal(err)
	}
}
