// Package autoprint prints the program's build metadata to stderr at startup
// as an import side effect. Import it for effect — no symbols, no call sites:
//
//	import _ "github.com/davidwalter0/frameworks/go/pkg/buildinfo/autoprint"
//
// The print fires from init, so it runs before main. Set BUILDINFO_QUIET (any
// non-empty value) to suppress it. This is intentionally a separate package
// from buildinfo so that buildinfo itself stays import-silent and safe to embed
// in a CLI — go-version's own cmd/go-version calls buildinfo.Read directly
// rather than importing this package, which is the pattern to copy.
package autoprint

import (
	"os"

	"github.com/davidwalter0/frameworks/go/pkg/buildinfo"
)

func init() {
	if os.Getenv("BUILDINFO_QUIET") == "" {
		buildinfo.Print(os.Stderr)
	}
}
