package spec

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
)

// This file is the desktop-application half of [Spec], merged in from
// pkg/installer.Spec.
//
// WHY THE MERGE. frameworks briefly carried TWO Spec types: this one (absorbed
// from installkit, carrying Units/Chart/Kube/Scope/Tokens and the deployment
// targets) and pkg/installer.Spec (carrying DesktopNaming/CleanMode/Launchers
// and three live consumers). Neither was a superset. D-0005 had already
// rejected that state by name — "two Specs, two prefix defaults, two uninstall
// models in every adopting repo, permanently" — and it arose anyway when
// installkit's packages were copied in without reconciling them against the
// existing extraction.
//
// The direction is this package because it is the leaf type that pkg/instruct
// and pkg/target already build on, so the alternative would have inverted the
// dependency graph to serve the smaller stack.
//
// Everything below encodes a FINDING rather than a preference. The defaults are
// what they are because someone lost time to the alternative.

// Launcher is one bin/ symlink the install creates.
//
// Apps differ here more than they look: voicelab has two ("bin/vl" and
// "voicelab-ui"), word-bank points at "AppRun" — an AppDir launcher that
// sources bundled GTK hooks — plus "usr/bin/word-bank", and ghk has a single
// "ghk-dashboard".
type Launcher struct {
	// Target is the path within the app directory to link to.
	Target string `json:"target" yaml:"target"`
	// Name is the basename created in <prefix>/bin.
	Name string `json:"name" yaml:"name"`
	// Blurb is an optional one-line description printed after a successful
	// install, e.g. "(try: vl --help)". Empty prints the path alone.
	Blurb string `json:"blurb,omitempty" yaml:"blurb,omitempty"`
}

// CleanMode selects how much of a previous install is removed before extracting
// a new payload.
type CleanMode int

const (
	// CleanAppDir removes the entire app directory. This is the DEFAULT and the
	// safest choice: word-bank adopted it after a layout change left stale
	// top-level entries (data/, lib/, gui/, an old binary) stranded by the
	// subtree-only clean, and a stranded file from an older layout is invisible
	// until it misbehaves.
	CleanAppDir CleanMode = iota

	// CleanSubdirs removes only the subdirectories named in Spec.CleanSubdirs,
	// preserving anything else already there. Use only when something in that
	// directory must survive an upgrade — and say what, at the call site.
	CleanSubdirs
)

// DesktopNaming selects the basename of the installed .desktop file.
type DesktopNaming int

const (
	// DesktopByAppID names the installed entry "<AppID>.desktop". This is the
	// DEFAULT, and it is not cosmetic: on Wayland the window icon is resolved
	// from the .desktop file whose FILENAME equals the application's app-id, so
	// any other name silently loses the window icon.
	DesktopByAppID DesktopNaming = iota

	// DesktopByBasename keeps the payload's own .desktop basename. For consumers
	// whose GTK application-id does not match their app-id and which cannot
	// change it yet. Prefer fixing the app-id.
	DesktopByBasename
)

// DefaultIconRels returns the icon paths every app in this family stages: a
// 256x256 PNG and a scalable SVG, both named for the app-id.
//
// The names matter more than they look: the Linux window/taskbar icon resolves
// BY NAME from the installed XDG theme, never from the application bundle, so
// an icon whose basename differs from the app-id is simply never found.
func DefaultIconRels(appID string) []string {
	return []string{
		fmt.Sprintf("256x256/apps/%s.png", appID),
		ScalableIconRel(appID),
	}
}

// IconRels returns PNG rels for the given sizes plus the scalable SVG.
func IconRels(appID string, sizes ...int) []string {
	rels := PNGIconRels(appID, sizes...)
	return append(rels, ScalableIconRel(appID))
}

// PNGIconRels returns only the PNG rels for the given sizes, for a consumer
// that ships no SVG.
func PNGIconRels(appID string, sizes ...int) []string {
	rels := make([]string, 0, len(sizes))
	for _, s := range sizes {
		rels = append(rels, fmt.Sprintf("%dx%d/apps/%s.png", s, s, appID))
	}
	return rels
}

// ScalableIconRel returns the scalable SVG rel for appID.
func ScalableIconRel(appID string) string {
	return fmt.Sprintf("scalable/apps/%s.svg", appID)
}

// IconRelsOrDefault is IconRels with [DefaultIconRels] applied when unset.
//
// Exported because pkg/installer renders from it; an unexported helper would
// have forced that package to re-derive the default and the two could then
// disagree about what an unset Spec installs.
func (s Spec) IconRelsOrDefault() []string {
	if len(s.IconRels) > 0 {
		return s.IconRels
	}
	return DefaultIconRels(s.AppID)
}

// DisplayNameOrDefault falls back to ShareSubdir, then App, so
// operator-facing output is never empty.
func (s Spec) DisplayNameOrDefault() string {
	switch {
	case s.DisplayName != "":
		return s.DisplayName
	case s.ShareSubdir != "":
		return s.ShareSubdir
	default:
		return s.App
	}
}

// DesktopTarget is the basename of the installed .desktop file, honouring
// DesktopNaming. Exported because packaging scripts need to agree with it — a
// disagreement is the silent Wayland icon loss described on DesktopByAppID.
func (s Spec) DesktopTarget() string {
	if s.DesktopNaming == DesktopByBasename && s.DesktopSource != "" {
		return filepath.Base(s.DesktopSource)
	}
	if s.AppID != "" {
		return s.AppID + ".desktop"
	}
	return filepath.Base(s.DesktopSource)
}

// Layout resolves every directory an install touches.
//
// It began as four prefix-derived directories and grew the config/state/cache/
// unit entries when the package acquired a concept of platform — see
// [Spec.LayoutForPlatform], which is the constructor to prefer. Resolve it ONCE
// per install and pass it down: it is the single producer every generated
// artifact takes its paths from, and re-deriving a path at a second call site
// is exactly how a unit comes to name a binary the installer never wrote.
type Layout struct {
	Prefix  string `json:"prefix,omitempty" yaml:"prefix,omitempty"`
	AppDir  string `json:"app-dir,omitempty" yaml:"app-dir,omitempty"`   // payload root
	BinDir  string `json:"bin-dir,omitempty" yaml:"bin-dir,omitempty"`   // things a person types
	AppsDir string `json:"apps-dir,omitempty" yaml:"apps-dir,omitempty"` // .desktop entries
	Theme   string `json:"theme,omitempty" yaml:"theme,omitempty"`       // hicolor root; EMPTY on macOS

	// ConfigDir is the per-app configuration directory. It is NOT under Prefix
	// in any supported layout — see [Overrides.Prefix].
	ConfigDir string `json:"config-dir,omitempty" yaml:"config-dir,omitempty"`

	// StateDir holds what survives but is not configuration: logs, history,
	// receipts.
	StateDir string `json:"state-dir,omitempty" yaml:"state-dir,omitempty"`

	// CacheDir holds what may be deleted and regenerated.
	CacheDir string `json:"cache-dir,omitempty" yaml:"cache-dir,omitempty"`

	// UnitDir is where generated service units are written: systemd user units
	// on Linux, LaunchAgents on macOS.
	UnitDir string `json:"unit-dir,omitempty" yaml:"unit-dir,omitempty"`

	// Platform records which layout produced this, so a consumer can branch on
	// it without re-deriving — and so a receipt can say what shape it wrote.
	Platform Platform `json:"platform,omitempty" yaml:"platform,omitempty"`
}

// LayoutFor resolves the Spec against a prefix, in the historical prefix-only
// form: every directory hangs off <prefix>.
//
// PREFER [Spec.LayoutForPlatform]. This form cannot express a platform and
// cannot honour XDG_CONFIG_HOME, so it leaves ConfigDir/StateDir/CacheDir/
// UnitDir empty. It is kept because it is the shape existing consumers call and
// changing it silently would relocate their installs.
func (s Spec) LayoutFor(prefix string) Layout {
	return Layout{
		Prefix:   prefix,
		AppDir:   filepath.Join(prefix, "share", s.ShareSubdir),
		BinDir:   filepath.Join(prefix, "bin"),
		AppsDir:  filepath.Join(prefix, "share", "applications"),
		Theme:    filepath.Join(prefix, "share", "icons", "hicolor"),
		Platform: PlatformLinux,
	}
}

// ValidateDesktop checks the desktop-application half of the Spec. It runs
// BEFORE any write, so a malformed Spec cannot half-install.
//
// This is pkg/installer.Spec.Validate moved VERBATIM, only the message prefix
// changed. An earlier revision of this merge paraphrased it and lost three
// things — the bare-basename rule entirely, the exact stem comparison (weakened
// to a substring match, so "<appid>-extra.png" would have passed), and the
// distinction between validating the raw IconRels field versus the defaulted
// list. Moving validated code is a move, not a rewrite; the paraphrase is
// recorded here so the temptation is not repeated.
//
// Every rule exists because its absence caused a real failure. None is merely
// defensive.
func (s Spec) ValidateDesktop() error {
	var errs []error
	if s.AppID == "" {
		errs = append(errs, errors.New("spec: Spec.AppID is required"))
	}
	if s.ShareSubdir == "" {
		errs = append(errs, errors.New("spec: Spec.ShareSubdir is required"))
	}
	// filepath.Clean("../evil") is "../evil" — unchanged — so a Clean
	// round-trip alone does NOT catch traversal. The escape check has to be
	// explicit, or ShareSubdir becomes a way to write outside the prefix.
	if s.ShareSubdir != "" && !isSafeRelPath(s.ShareSubdir) {
		errs = append(errs, fmt.Errorf("spec: Spec.ShareSubdir must be a clean relative path that stays inside the prefix, got %q", s.ShareSubdir))
	}
	// The rule is "this install must put SOMETHING where a user can reach it",
	// and Components now satisfy it too: a cli component produces exactly the
	// bin/ entry a Launcher does, and a gui component produces a menu entry.
	// An install that extracts a payload and exposes nothing is still refused —
	// that is the failure the original check existed to prevent, and it is
	// unchanged. What is relaxed is only the assumption that Launchers is the
	// single way to express it.
	if len(s.Launchers) == 0 && len(s.Components) == 0 {
		errs = append(errs, errors.New(
			"spec: declare at least one entry in Spec.Launchers or Spec.Components — "+
				"an install that exposes nothing to the user has nothing to install"))
	}
	for i, l := range s.Launchers {
		if l.Target == "" || l.Name == "" {
			errs = append(errs, fmt.Errorf("spec: Spec.Launchers[%d] needs both Target and Name", i))
		}
		// A Name carrying a separator would symlink outside <prefix>/bin.
		if filepath.Base(l.Name) != l.Name {
			errs = append(errs, fmt.Errorf("spec: Spec.Launchers[%d].Name must be a bare basename, got %q", i, l.Name))
		}
	}
	if s.CleanMode == CleanSubdirs && len(s.CleanSubdirs) == 0 {
		errs = append(errs, errors.New("spec: CleanSubdirs mode selected but Spec.CleanSubdirs is empty"))
	}
	// An icon is resolved from the installed theme by DIRECTORY and BASENAME.
	// A basename that is not the app-id is never found — and nothing errors,
	// the app just shows a generic icon, which is why this is worth refusing
	// up front rather than leaving a user to notice.
	if s.AppID != "" {
		for i, rel := range s.IconRels {
			if !isSafeRelPath(rel) {
				errs = append(errs, fmt.Errorf("spec: Spec.IconRels[%d] must be a clean relative path inside the theme, got %q", i, rel))
				continue
			}
			base := filepath.Base(rel)
			if stem := strings.TrimSuffix(base, filepath.Ext(base)); stem != s.AppID {
				errs = append(errs, fmt.Errorf(
					"spec: Spec.IconRels[%d] is %q, whose basename %q is not the app-id %q — "+
						"the theme resolves icons by name, so this file would install and never be found",
					i, rel, stem, s.AppID))
			}
		}
	}
	return errors.Join(errs...)
}

// isSafeRelPath refuses anything that could escape the directory it is joined
// to.
//
// A filepath.Clean round-trip does NOT catch this on its own: Clean("../evil")
// is "../evil", which round-trips unchanged and looks fine. The explicit
// traversal check is the load-bearing part.
func isSafeRelPath(p string) bool {
	if p == "" || filepath.IsAbs(p) {
		return false
	}
	clean := filepath.Clean(p)
	if clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return false
	}
	for _, seg := range strings.Split(clean, string(filepath.Separator)) {
		if seg == ".." {
			return false
		}
	}
	return true
}
