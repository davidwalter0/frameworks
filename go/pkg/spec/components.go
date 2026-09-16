package spec

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"
)

// Role says what a component IS, so the layout can decide where it GOES.
//
// WHY ROLES RATHER THAN PATHS. Every repo in this family re-decided where each
// of its pieces belonged, and they disagreed: mountbridge is daemon + UI,
// cross-bridge is a cbctl UI plus eight cb-* tools, word-bank is GUI + CLI.
// Measured 2026-09-10, one machine's ~/.config/systemd/user held FOUR live
// conventions at once (~/go/bin, ~/.local/bin, ~/.local/share/<app>/…, %h/bin),
// and three repos disagreed with THEMSELVES depending on which entry point ran.
//
// A manifest that named directories would just relocate that argument. A
// manifest that names roles removes it: the role is a property of the component
// and never changes, while the destination is a property of the platform. So
// "which directory" stops being a per-repo decision, which is the only thing
// that makes a standard hold rather than erode.
//
// The cli/helper split is not ours — systemd's file-hierarchy(7) draws it,
// saying ~/.local/bin is for executables "useful for shell invocation" and that
// anything else belongs under the application's own tree. RoleHelper exists so
// a payload binary nobody types (waypipe, a signing shim) stops landing on PATH.
type Role string

const (
	// RoleCLI is a command a person types. It is the only role that lands in
	// the layout's BinDir.
	RoleCLI Role = "cli"

	// RoleDaemon is a long-running service. It lives in the app tree and a
	// service unit is GENERATED for it, with the unit's ExecStart taken from
	// the destination the installer computed — see [Layout.DestinationFor].
	RoleDaemon Role = "daemon"

	// RoleGUI is a windowed application. It lives in the app tree and gets a
	// desktop entry and icons.
	RoleGUI Role = "gui"

	// RoleHelper is an executable the payload invokes but a person does not.
	// It lives in the app tree and is deliberately NOT placed on PATH.
	RoleHelper Role = "helper"
)

// Valid reports whether r is a known role.
func (r Role) Valid() bool {
	switch r {
	case RoleCLI, RoleDaemon, RoleGUI, RoleHelper:
		return true
	}
	return false
}

// String implements fmt.Stringer.
func (r Role) String() string { return string(r) }

// OnPath reports whether this role is placed in the layout's BinDir.
//
// Exactly one role is, and expressing that here rather than at each call site
// keeps the file-hierarchy(7) rule in one place.
func (r Role) OnPath() bool { return r == RoleCLI }

// Component is one installable piece of an application.
//
// An application is a BUNDLE — its UI, its daemon, its CLI tools, its helpers —
// installed as one unit. Before this type, a repo's pieces were enumerated
// separately in the Makefile, the installer, the systemd unit and the desktop
// entry, and those four lists drifted. mountbridge's units named a binary its own
// installer had stopped writing, for 19 commits, with nothing reporting it.
type Component struct {
	// Name is the component's identity and the basename it is installed as.
	Name string `json:"name" yaml:"name"`

	// Role decides the destination. See [Role].
	Role Role `json:"role" yaml:"role"`

	// Rel is the path to this component WITHIN the payload, relative to the
	// app directory.
	//
	// MUST BE RELATIVE. This is the manifest's central portability invariant
	// and [ValidateComponents] enforces it: a manifest is the author's
	// declaration and travels between machines and operating systems, so it
	// may not contain a destination. Absolute paths belong in the RECEIPT,
	// which records what one install wrote on one machine and must be absolute
	// because you cannot uninstall a relative path.
	//
	// Empty means "the payload root joined with Name".
	Rel string `json:"rel,omitempty" yaml:"rel,omitempty"`

	// Blurb is an optional one-line description printed after a successful
	// install, e.g. "(try: vl --help)".
	Blurb string `json:"blurb,omitempty" yaml:"blurb,omitempty"`

	// Unit overrides the generated unit's basename for a daemon. Empty means
	// "<Name>.service". Only meaningful for [RoleDaemon].
	Unit string `json:"unit,omitempty" yaml:"unit,omitempty"`

	// Args are appended to the generated unit's ExecStart, after the computed
	// binary path. Only meaningful for [RoleDaemon].
	//
	// The binary path itself is never spelled here — that is the entire point
	// of generating the unit.
	Args []string `json:"args,omitempty" yaml:"args,omitempty"`

	// Instanced marks a templated unit ("<name>@.service"), for a daemon that
	// runs once per account or device. mountbridge runs five.
	Instanced bool `json:"instanced,omitempty" yaml:"instanced,omitempty"`
}

// RelPath returns the component's path within the app directory, defaulting to
// its name.
func (c Component) RelPath() string {
	if c.Rel != "" {
		return c.Rel
	}
	return c.Name
}

// HasUnit reports whether a service unit is materialized for this component.
//
// THIS IS SEPARATE FROM Role ON PURPOSE, and the separation was learned the
// hard way. The first consumer of this package is mountbridge, whose `mountbridge`
// binary is BOTH the daemon and the CLI — its own launcher blurb reads
// "(daemon + CLI; try: mountbridge doctor)". A single Role could not say that:
// RoleCLI put it on PATH but generated no unit, RoleDaemon generated the unit
// but kept it off PATH, and neither is true of that binary.
//
// So "is this a name a person types" ([Role.OnPath]) and "does this have a
// service unit" (here) are independent properties. RoleDaemon still implies a
// unit — that is what the role means — and any other role opts in by declaring
// Unit or Instanced.
func (c Component) HasUnit() bool {
	return c.Role == RoleDaemon || c.Unit != "" || c.Instanced
}

// UnitName returns the generated unit's basename for a unit-bearing component.
func (c Component) UnitName() string {
	base := c.Unit
	if base == "" {
		base = c.Name
	}
	if strings.HasSuffix(base, ".service") {
		return base
	}
	if c.Instanced {
		return base + "@.service"
	}
	return base + ".service"
}

// ValidateComponents checks the component list.
//
// The absolute-path rule is the load-bearing one and is checked for every
// component regardless of role: a manifest that can name a destination is a
// manifest that will, and then it is no longer portable.
func ValidateComponents(cs []Component) error {
	var probs []string
	seen := make(map[string]int, len(cs))

	for i, c := range cs {
		where := fmt.Sprintf("components[%d]", i)
		if c.Name != "" {
			where = fmt.Sprintf("%s (%s)", where, c.Name)
		}

		switch {
		case c.Name == "":
			probs = append(probs, where+": name is required")
		case strings.ContainsRune(c.Name, filepath.Separator):
			probs = append(probs, fmt.Sprintf(
				"%s: name must be a basename, not a path", where))
		default:
			if prev, dup := seen[c.Name]; dup {
				probs = append(probs, fmt.Sprintf(
					"%s: duplicate name, already declared at components[%d]", where, prev))
			}
			seen[c.Name] = i
		}

		if !c.Role.Valid() {
			probs = append(probs, fmt.Sprintf(
				"%s: unknown role %q (want %q, %q, %q or %q)",
				where, c.Role, RoleCLI, RoleDaemon, RoleGUI, RoleHelper))
		}

		// The portability invariant. Checked on the raw field, not RelPath(),
		// so the message points at what the author actually wrote.
		if filepath.IsAbs(c.Rel) {
			probs = append(probs, fmt.Sprintf(
				"%s: rel %q is absolute; a manifest declares paths RELATIVE to the "+
					"app directory so it stays portable — absolute paths belong in "+
					"the install receipt", where, c.Rel))
		}
		if c.Rel != "" && !filepath.IsLocal(filepath.Clean(c.Rel)) {
			probs = append(probs, fmt.Sprintf(
				"%s: rel %q escapes the app directory", where, c.Rel))
		}

		// Unit fields belong to anything that HAS a unit, which is not the same
		// as RoleDaemon — see [Component.HasUnit]. A cli may legitimately be a
		// service too (mountbridge is one binary serving both), so it opts in by
		// declaring Unit or Instanced.
		//
		// A gui or helper may not: a gui is launched by the desktop and a
		// helper by the payload, so a unit for either names something nothing
		// would start. Refused rather than ignored — a silently dropped Args is
		// a setting someone believed was in effect.
		switch c.Role {
		case RoleGUI, RoleHelper:
			if c.Unit != "" {
				probs = append(probs, fmt.Sprintf(
					"%s: %q components take no service unit; drop \"unit\"", where, c.Role))
			}
			if c.Instanced {
				probs = append(probs, fmt.Sprintf(
					"%s: %q components take no service unit; drop \"instanced\"", where, c.Role))
			}
		}
		if len(c.Args) > 0 && !c.HasUnit() {
			probs = append(probs, where+
				`: "args" are the generated unit's ExecStart arguments, and this `+
				`component has no unit — set "instanced" or "unit", or use role daemon`)
		}
	}

	if len(probs) == 0 {
		return nil
	}
	sort.Strings(probs)
	return fmt.Errorf("spec: invalid components:\n  %s", strings.Join(probs, "\n  "))
}
