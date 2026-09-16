package spec

import (
	"fmt"
	"sort"
	"strings"
)

// Derived token names. A unit file or desktop entry writes these literally and
// the installer replaces them with the paths it actually used.
const (
	TokenPrefix    = "__PREFIX__"
	TokenBinDir    = "__BINDIR__"
	TokenAppDir    = "__APPDIR__"
	TokenAppsDir   = "__APPSDIR__"
	TokenTheme     = "__THEME__"
	TokenConfigDir = "__CONFIGDIR__"
	TokenStateDir  = "__STATEDIR__"
	TokenCacheDir  = "__CACHEDIR__"
	TokenUnitDir   = "__UNITDIR__"

	// TokenExec is the sole daemon's installed path. Present only when the
	// spec declares exactly one daemon component — see [Layout.Tokens].
	TokenExec = "__EXEC__"
)

// Tokens returns the substitution values DERIVED from this resolved layout.
//
// THIS IS THE FIX, and it is worth stating plainly because the mechanism it
// replaces also looked correct.
//
// Unit files and desktop entries in this family are shipped by each repo with
// __TOKEN__ placeholders and substituted at install time. That part was always
// fine. What was wrong is where the VALUES came from:
//
//   - hand-written into Spec.Tokens, or into the unit itself — one consumer's
//     five units named $HOME/go/bin/<app> while its installer wrote to a
//     per-app share directory instead, so reinstalling never changed what ran
//     and the daemon sat 19 commits stale with nothing reporting it;
//   - or derived from the WRONG SOURCE. That same consumer's generator did
//     derive the path — from os.Executable() + EvalSymlinks, i.e. from
//     whichever binary happened to run the command. Run the installed binary's
//     own install-unit command once and the unit is pinned to that path
//     permanently.
//
// So "it is derived" was never sufficient; the SOURCE of the derivation is the
// thing that has to be right. Here every value comes from the Layout the
// installer is writing with, so a unit cannot name a path the install did not
// create.
//
// Per-component tokens are __EXEC_<NAME>__ with the name upper-cased and any
// non-alphanumeric run collapsed to a single underscore: a component named
// "mountbridge-ui" yields __EXEC_MOUNTBRIDGE_UI__.
func (l Layout) Tokens(s Spec) (map[string]string, error) {
	t := map[string]string{
		TokenPrefix:    l.Prefix,
		TokenBinDir:    l.BinDir,
		TokenAppDir:    l.AppDir,
		TokenAppsDir:   l.AppsDir,
		TokenConfigDir: l.ConfigDir,
		TokenStateDir:  l.StateDir,
		TokenCacheDir:  l.CacheDir,
		TokenUnitDir:   l.UnitDir,
	}
	// Theme is legitimately empty on macOS, which installs no icon theme.
	// Omitting the token there means a unit referencing it fails loudly as an
	// unknown token rather than substituting an empty string into a path.
	if l.Theme != "" {
		t[TokenTheme] = l.Theme
	}

	var daemons []Component
	owner := make(map[string]string, len(s.Components))
	for _, c := range s.Components {
		name := ExecToken(c.Name)
		if prev, dup := owner[name]; dup {
			return nil, fmt.Errorf(
				"spec: components %q and %q both map to token %s; rename one",
				prev, c.Name, name)
		}
		owner[name] = c.Name
		t[name] = l.DestinationFor(c)
		if c.Role == RoleDaemon {
			daemons = append(daemons, c)
		}
	}

	// __EXEC__ is the shape units in this family already use, and it is
	// unambiguous only with a single daemon. With several, requiring the
	// explicit per-component token is the point: ghk, mountbridge and
	// alert-log each ship more than one unit, and a bare __EXEC__
	// silently resolving to whichever came first is the class of defect this
	// file exists to remove.
	if len(daemons) == 1 {
		t[TokenExec] = l.DestinationFor(daemons[0])
	}
	return t, nil
}

// ExecToken returns the per-component substitution token for a component name.
func ExecToken(name string) string {
	var b strings.Builder
	b.WriteString("__EXEC_")
	prevUnderscore := false
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z':
			b.WriteRune(r - 32)
			prevUnderscore = false
		case (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9'):
			b.WriteRune(r)
			prevUnderscore = false
		default:
			if !prevUnderscore {
				b.WriteByte('_')
				prevUnderscore = true
			}
		}
	}
	b.WriteString("__")
	return b.String()
}

// MergeTokens layers the author's Spec.Tokens beneath the derived ones.
//
// A COLLISION IS AN ERROR, not a silent win for either side. If an author
// hand-writes __EXEC__ and the layout also derives it, exactly one of two
// things is true: they agree, in which case the hand-written copy is redundant
// and will rot the first time the layout changes; or they disagree, which is
// the same class of defect described above, written down again. Both deserve to be said out loud at install
// time rather than resolved by precedence rules nobody remembers.
func MergeTokens(derived, authored map[string]string) (map[string]string, error) {
	out := make(map[string]string, len(derived)+len(authored))
	for k, v := range authored {
		out[k] = v
	}

	var clashes []string
	for k, v := range derived {
		if _, exists := authored[k]; exists {
			clashes = append(clashes, k)
			continue
		}
		out[k] = v
	}
	if len(clashes) > 0 {
		sort.Strings(clashes)
		return nil, fmt.Errorf(
			"spec: token(s) %s are computed from the install layout and must not "+
				"also be set in tokens: — remove them from the manifest so the "+
				"value cannot disagree with where the installer actually writes",
			strings.Join(clashes, ", "))
	}
	return out, nil
}
