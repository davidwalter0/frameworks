package target

import (
	"fmt"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/davidwalter0/frameworks/go/pkg/instruct"
	"github.com/davidwalter0/frameworks/go/pkg/plan"
	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

// tokenPattern matches the __UPPER_SNAKE__ placeholders the family's unit
// templates already use (__EXEC__, __CONFIG__, __CONFIG_DIR__, __PREFIX__,
// __HTTP_ADDR__).
var tokenPattern = regexp.MustCompile(`__[A-Z][A-Z0-9_]*__`)

// SystemdUnitDir resolves where units are written.
//
// The user path is derived from the injected ConfigHome so it is testable
// without touching $XDG_CONFIG_HOME, and so `make install-service
// XDG_CONFIG_HOME=/tmp/x/config`-style staging keeps working after adoption.
func SystemdUnitDir(s spec.Spec) (string, error) {
	if s.UnitDir != "" {
		return s.UnitDir, nil
	}
	switch s.Scope {
	case spec.ScopeSystem:
		return "/etc/systemd/system", nil
	case spec.ScopeUser, "":
		if s.ConfigHome != "" {
			return filepath.Join(s.ConfigHome, "systemd", "user"), nil
		}
		if s.Home != "" {
			return filepath.Join(s.Home, ".config", "systemd", "user"), nil
		}
		return "", fmt.Errorf("cannot derive the user unit directory: set Spec.ConfigHome, Spec.Home, or --unit-dir")
	}
	return "", fmt.Errorf("unknown scope %q", s.Scope)
}

// UnitFileName derives a unit's filename. It is derived and never supplied:
// a .mount whose name is not the escaped mount point is a unit systemd
// ignores, and an instance unit that loses its escaping addresses a different
// instance than the operator asked for.
func UnitFileName(u spec.Unit) (string, error) {
	switch u.Kind {
	case spec.KindMount:
		if strings.TrimSpace(u.Where) == "" {
			return "", fmt.Errorf("mount unit needs Where (the mount point); the unit name is derived from it")
		}
		if !strings.HasPrefix(u.Where, "/") {
			return "", fmt.Errorf("mount point %q must be absolute", u.Where)
		}
		return EscapePath(u.Where) + ".mount", nil

	case spec.KindService, spec.KindSocket, spec.KindTimer:
		if strings.TrimSpace(u.Stem) == "" {
			return "", fmt.Errorf("%s unit needs a Stem", u.Kind)
		}
		name := u.Stem
		if u.Instance != "" {
			name += "@" + EscapeUnitName(u.Instance)
		}
		return name + "." + string(u.Kind), nil
	}
	return "", fmt.Errorf("unknown unit kind %q", u.Kind)
}

// substitute replaces every __TOKEN__ with its Spec value.
//
// A token present in the unit but absent from the Spec is a HARD ERROR. The
// whole-file `sed` this replaces could not detect that case: an unsubstituted
// placeholder shipped as literal text (systemd then fails to start something
// called "__EXEC__"), and a token substituted with an empty value shipped a
// unit that looked fine and did nothing.
func substitute(content string, tokens map[string]string, unitName string) (string, error) {
	var missing []string
	out := tokenPattern.ReplaceAllStringFunc(content, func(m string) string {
		name := strings.Trim(m, "_")
		if v, ok := tokens[name]; ok {
			return v
		}
		if v, ok := tokens[m]; ok { // tolerate callers keying with the underscores
			return v
		}
		missing = append(missing, m)
		return m
	})
	if len(missing) > 0 {
		sort.Strings(missing)
		missing = dedupe(missing)
		return "", fmt.Errorf("unit %s references %s, which the Spec does not define (defined: %s)",
			unitName, strings.Join(missing, ", "), strings.Join(quoteAll(available(tokens)), ", "))
	}
	return out, nil
}

func available(tokens map[string]string) []string {
	out := make([]string, 0, len(tokens))
	for k := range tokens {
		out = append(out, "__"+strings.Trim(k, "_")+"__")
	}
	sort.Strings(out)
	if len(out) == 0 {
		return []string{"(none)"}
	}
	return out
}

func quoteAll(in []string) []string { return in }

func dedupe(in []string) []string {
	out := in[:0]
	var last string
	for i, s := range in {
		if i == 0 || s != last {
			out = append(out, s)
		}
		last = s
	}
	return out
}

// Systemd renders unit files, drop-ins and the activation commands.
//
// It writes files and produces command STRINGS. It never runs systemctl —
// that is the module invariant (decision D-0004), and it is also what every
// Makefile target this replaces already promised in its comments.
func Systemd(s spec.Spec, kinds []spec.UnitKind) (plan.Plan, error) {
	p := plan.Plan{Target: "systemd"}

	scope := s.Scope
	if scope == "" {
		scope = spec.ScopeUser
	}

	units := s.UnitsOfKinds(kinds)
	if len(units) == 0 {
		if len(s.Units) == 0 {
			return p, fmt.Errorf("target unavailable: this build embeds no systemd units")
		}
		return p, fmt.Errorf("no units of kind %s in this payload (it ships: %s)",
			kindList(kinds), kindList(shippedKinds(s.Units)))
	}

	dir, err := SystemdUnitDir(spec.Spec{
		UnitDir: s.UnitDir, Scope: scope, ConfigHome: s.ConfigHome, Home: s.Home,
	})
	if err != nil {
		return p, err
	}

	// Refuse the combination that cannot work, and say what to do instead.
	// A user manager cannot perform a real mount; installing the unit anyway
	// would leave a file that looks installed and never mounts anything.
	for _, u := range units {
		if u.Kind == spec.KindMount && scope == spec.ScopeUser {
			return p, fmt.Errorf(
				"a .mount unit cannot run in the user manager (systemd --user cannot mount %s).\n"+
					"  Either install it system-wide:   --scope=system\n"+
					"  or use a FUSE instance service:  %s@<systemd-escape %s>.service\n"+
					"  (the pattern a FUSE mount daemon already uses for per-user mounts)",
				u.Where, s.App, u.Where)
		}
	}

	p.Mkdir(dir, "systemd "+string(scope)+" unit directory")

	rendered := make([]instruct.UnitPlan, 0, len(units))
	for _, u := range units {
		name, err := UnitFileName(u)
		if err != nil {
			return p, err
		}
		body, err := substitute(u.Content, s.Tokens, name)
		if err != nil {
			return p, err
		}
		p.Write(filepath.Join(dir, name), []byte(body), 0o644,
			fmt.Sprintf("%s unit for %s", u.Kind, s.App))

		dropNames := make([]string, 0, len(u.DropIns))
		for n := range u.DropIns {
			dropNames = append(dropNames, n)
		}
		sort.Strings(dropNames)
		for _, n := range dropNames {
			dropBody, err := substitute(u.DropIns[n], s.Tokens, name+".d/"+n)
			if err != nil {
				return p, err
			}
			p.Write(filepath.Join(dir, name+".d", n), []byte(dropBody), 0o644,
				"drop-in override for "+name)
		}

		rendered = append(rendered, instruct.UnitPlan{Name: name, Kind: u.Kind, Stem: u.Stem})
	}

	// A timer needs a service of the same stem. It may be shipped by the app
	// or already present on the host, so this is advisory — but silence here
	// would mean a timer that fires into nothing.
	noteOrphanTimers(&p, units)

	p.Instruct(instruct.Activation(scope, rendered)...)
	return p, nil
}

// SystemdUninstall removes the units and prints the disable commands. It
// disables nothing itself, symmetrically with Systemd.
func SystemdUninstall(s spec.Spec, kinds []spec.UnitKind) (plan.Plan, error) {
	p := plan.Plan{Target: "systemd"}
	scope := s.Scope
	if scope == "" {
		scope = spec.ScopeUser
	}
	dir, err := SystemdUnitDir(spec.Spec{
		UnitDir: s.UnitDir, Scope: scope, ConfigHome: s.ConfigHome, Home: s.Home,
	})
	if err != nil {
		return p, err
	}
	units := s.UnitsOfKinds(kinds)
	rendered := make([]instruct.UnitPlan, 0, len(units))
	for _, u := range units {
		name, err := UnitFileName(u)
		if err != nil {
			return p, err
		}
		rendered = append(rendered, instruct.UnitPlan{Name: name, Kind: u.Kind, Stem: u.Stem})
	}
	// Disable BEFORE the files disappear — a unit systemd cannot read is a
	// unit it cannot cleanly disable, which leaves dangling symlinks in
	// .wants directories.
	p.Instruct(instruct.Deactivation(scope, rendered)...)
	for _, u := range rendered {
		p.Remove(filepath.Join(dir, u.Name), "remove "+string(u.Kind)+" unit")
		p.Remove(filepath.Join(dir, u.Name+".d"), "remove drop-in directory")
	}
	return p, nil
}

func noteOrphanTimers(p *plan.Plan, units []spec.Unit) {
	services := map[string]bool{}
	for _, u := range units {
		if u.Kind == spec.KindService {
			services[u.Stem] = true
		}
	}
	for _, u := range units {
		if u.Kind == spec.KindTimer && !services[u.Stem] {
			p.Note("%s.timer ships without a %s.service in this payload — the timer will fire "+
				"into a missing unit unless that service is installed separately.", u.Stem, u.Stem)
		}
	}
}

func shippedKinds(units []spec.Unit) []spec.UnitKind {
	seen := map[spec.UnitKind]bool{}
	var out []spec.UnitKind
	for _, u := range units {
		if !seen[u.Kind] {
			seen[u.Kind] = true
			out = append(out, u.Kind)
		}
	}
	return out
}

func kindList(kinds []spec.UnitKind) string {
	if len(kinds) == 0 {
		return "(none)"
	}
	out := make([]string, 0, len(kinds))
	for _, k := range kinds {
		out = append(out, string(k))
	}
	return strings.Join(out, ", ")
}
