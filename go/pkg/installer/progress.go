package installer

import (
	"fmt"
	"io"
)

// progress is the installer's status/warning stream.
//
// Write errors on this stream are DELIBERATELY discarded, and this type exists
// so that decision is stated once rather than repeated at every call site. The
// destination is the user's terminal: a failure writing a status line is not
// actionable, and aborting an otherwise-successful install because a progress
// message could not be printed would be strictly worse than the message being
// lost. This is the package's single documented exception to the
// no-silent-error-discard rule.
//
// Anything that actually affects the installed result reports a real error
// instead — see [Install] and [Uninstall].
type progress struct{ w io.Writer }

func (p progress) printf(format string, a ...any) { _, _ = fmt.Fprintf(p.w, format, a...) }

func (p progress) println(a ...any) { _, _ = fmt.Fprintln(p.w, a...) }
