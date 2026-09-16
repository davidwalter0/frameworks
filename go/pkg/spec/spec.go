// Package spec is the declarative description an application hands the
// installer: who it is, what it ships, and where each piece belongs.
//
// A Spec carries no behaviour and touches no host. It is the input to
// target.Render, which turns it into a plan.Plan — so every decision the
// installer makes is a pure function of this struct and is table-testable
// without a filesystem, a systemd instance, or a cluster.
package spec

// Struct tags on this package's manifest types are GENERATED, not hand-written,
// by autocfg's taggen (the code-gen side of the autocfg contract; pkg/tagspec
// is the runtime side). Regenerate with:
//
//go:generate go run github.com/davidwalter0/autocfg/cmd/struct-tag-parser --yaml --json --doc=false --backup=false spec.go requires.go desktop.go
//
// Derivation gives the house kebab-case spelling (AppID -> "app-id",
// ShareSubdir -> "share-subdir") consistently, which hand-writing does not: a
// first pass here produced camelCase by hand and disagreed with every other
// generated struct in the family.
//
// Existing tags are PRESERVED, so the two things derivation cannot know are
// pinned by hand and survive regeneration:
//
//   - `yaml:"-"` on Prefix, Payload, Icons, SystemIndexTheme, RenderTo, Home,
//     ConfigHome and PathEnv. These are supplied at the CALL SITE — embedded
//     bytes, host reads, environment — so a manifest that appeared to declare
//     them would claim to fix values it cannot know.
//   - `yaml:"ships"` on Requires. Derivation would spell it "requires", which
//     is already the manifest's key for BUILD tools. Two different questions
//     must not share one key.

import (
	"fmt"
	"sort"
	"strings"
)

// Scope selects which systemd manager owns the units.
type Scope string

const (
	// ScopeUser installs into the per-user manager — no root, no sudo.
	// This is the family default (see ghk.service's "USER unit by design").
	ScopeUser Scope = "user"
	// ScopeSystem installs into the system manager. Required for a real
	// .mount unit and for anything that must run before login.
	ScopeSystem Scope = "system"
)

// UnitKind is a systemd unit type. These are not interchangeable suffixes:
// each carries activation rules the renderer enforces (see package target).
type UnitKind string

const (
	KindService UnitKind = "service"
	KindSocket  UnitKind = "socket"
	KindTimer   UnitKind = "timer"
	KindMount   UnitKind = "mount"
)

// AllUnitKinds is the accepted set, in the order help text lists them.
var AllUnitKinds = []UnitKind{KindService, KindSocket, KindMount, KindTimer}

// ParseUnitKind maps a flag value to a UnitKind, rejecting anything else by
// name so a typo cannot silently install zero units.
func ParseUnitKind(s string) (UnitKind, error) {
	for _, k := range AllUnitKinds {
		if string(k) == s {
			return k, nil
		}
	}
	return "", fmt.Errorf("unknown unit kind %q (want one of %s)", s, joinKinds(AllUnitKinds))
}

// ParseScope maps a flag value to a Scope.
func ParseScope(s string) (Scope, error) {
	switch Scope(s) {
	case ScopeUser:
		return ScopeUser, nil
	case ScopeSystem:
		return ScopeSystem, nil
	}
	return "", fmt.Errorf("unknown scope %q (want user or system)", s)
}

func joinKinds(ks []UnitKind) string {
	out := make([]string, 0, len(ks))
	for _, k := range ks {
		out = append(out, string(k))
	}
	return strings.Join(out, ", ")
}

// Unit is one systemd unit the payload ships.
//
// The unit's FILENAME is derived, never supplied: a .mount's name must equal
// the escaped mount point or systemd ignores the unit, and an instance unit's
// name must carry the escaped instance. Accepting a caller-provided name is
// how that invariant gets broken silently.
type Unit struct {
	Kind UnitKind `json:"kind,omitempty" yaml:"kind,omitempty"`
	// Stem is the unit's base name for service/socket/timer — "ghk" yields
	// ghk.service. Ignored for KindMount, whose name comes from Where.
	Stem string `json:"stem,omitempty" yaml:"stem,omitempty"`
	// Content is the raw unit text, including any __TOKEN__ placeholders.
	Content string `json:"content,omitempty" yaml:"content,omitempty"`
	// Instance, when non-empty, makes this a template instance:
	// stem@<escaped-instance>.kind (mountbridge@you\x40example.com.service).
	Instance string `json:"instance,omitempty" yaml:"instance,omitempty"`
	// Where is the mount point for KindMount. The unit filename is derived
	// from it by path escaping.
	Where string `json:"where,omitempty" yaml:"where,omitempty"`
	// DropIns are <name>.conf fragments installed into <unit>.d/.
	DropIns map[string]string `json:"drop-ins,omitempty" yaml:"drop-ins,omitempty"`
}

// Chart describes a Helm chart the kubernetes target renders.
type Chart struct {
	// Path is the chart directory. Empty means this build embeds no chart,
	// which the kubernetes target reports as an unavailable target rather
	// than rendering nothing successfully.
	Path string `json:"path,omitempty" yaml:"path,omitempty"`
	// Release is the Helm release name used in the printed commands.
	Release string `json:"release,omitempty" yaml:"release,omitempty"`
	// Namespace the manifests are rendered for.
	Namespace string `json:"namespace,omitempty" yaml:"namespace,omitempty"`
	// Values files, in Helm precedence order.
	Values []string `json:"values,omitempty" yaml:"values,omitempty"`
}

// Kube carries cluster addressing. It is used to ADDRESS a render — it is
// interpolated into every printed command so the operator cannot apply to the
// wrong cluster by forgetting an environment variable — and it is never used
// to mutate a cluster from inside the installer.
type Kube struct {
	Kubeconfig string `json:"kubeconfig,omitempty" yaml:"kubeconfig,omitempty"`
	Context    string `json:"context,omitempty" yaml:"context,omitempty"`
	// Validate asks Helm to check rendered manifests against the cluster's
	// API server. This is the only path that contacts a cluster at all, it is
	// read-only, and it is off by default so the render works offline.
	Validate bool `json:"validate,omitempty" yaml:"validate,omitempty"`
}

// Binary is one executable the filesystem target links onto PATH.
type Binary struct {
	// Name is the symlink basename created in <prefix>/bin.
	Name string `json:"name" yaml:"name"`
	// Rel is the path to the real file, relative to the app directory.
	Rel string `json:"rel,omitempty" yaml:"rel,omitempty"`
}

// Spec is the whole installation description.
type Spec struct {
	App     string `json:"app" yaml:"app"` // "ghk", "netroute"
	Version string `json:"version,omitempty" yaml:"version,omitempty"`

	// Prefix is the filesystem install prefix (default ~/.local).
	Prefix string `json:"-" yaml:"-"`

	// Payload is a tar.gz tree extracted under <prefix>/share/<app>.
	// Empty means this build embeds no payload.
	Payload []byte `json:"-" yaml:"-"`
	// Binaries are symlinked from <prefix>/bin into the extracted tree.
	Binaries []Binary `json:"binaries,omitempty" yaml:"binaries,omitempty"`

	// AppID is the reverse-DNS application identifier, e.g.
	// "com.davidwalter0.exampleUi". When set, the desktop entry is installed
	// as "<AppID>.desktop" — and that is not cosmetic: on Wayland the window
	// icon is resolved from the .desktop file whose FILENAME equals the
	// application's app-id, so any other name silently loses the window icon.
	// Empty falls back to "<App>.desktop", which is fine for daemons with no
	// desktop presence. (Finding carried over from frameworks/go/pkg/installer,
	// whose DesktopByAppID default exists for exactly this.)
	AppID string `json:"app-id,omitempty" yaml:"app-id,omitempty"`
	// DesktopName, when set, overrides the installed entry's basename
	// entirely. Escape hatch for an application whose GTK application-id
	// cannot yet match its app-id; prefer fixing the app-id.
	DesktopName string `json:"desktop-name,omitempty" yaml:"desktop-name,omitempty"`
	// DesktopEntry, when non-empty, is the desktop entry content, written
	// under DesktopFileName with __PREFIX__ and Tokens substituted.
	DesktopEntry string `json:"desktop-entry,omitempty" yaml:"desktop-entry,omitempty"`
	// DesktopSource is a payload-relative path to a .desktop template inside
	// the archive, resolved during render with the same substitution. A
	// named-but-absent member is not an error — the app simply gets no menu
	// entry, the correct outcome for a CLI-only payload. DesktopEntry wins
	// when both are set.
	DesktopSource string `json:"desktop-source,omitempty" yaml:"desktop-source,omitempty"`
	// IconName is the canonical icon basename; it must match the .desktop
	// Icon= key and the runner's application id.
	IconName string `json:"icon-name,omitempty" yaml:"icon-name,omitempty"`
	// Icons maps "<size>x<size>" (or "scalable") to image bytes.
	Icons map[string][]byte `json:"-" yaml:"-"`
	// IconRels are icon paths relative to BOTH the payload's "icons/hicolor"
	// directory and the prefix's hicolor theme, e.g.
	// "256x256/apps/<app-id>.png". Each is mirrored out of the payload into
	// the theme; an absent member degrades to the generic icon rather than
	// failing the install. Icons (inline bytes) install alongside.
	IconRels []string `json:"icon-rels,omitempty" yaml:"icon-rels,omitempty"`
	// SystemIndexTheme is the content of the host's canonical hicolor
	// index.theme (/usr/share/icons/hicolor/index.theme), read at the CALL
	// SITE like the environment fields below — the render itself never
	// touches the host. Empty means none was found; a minimal valid theme
	// index is synthesized instead, so gtk-update-icon-cache accepts the
	// directory (without an index a stale icon-theme.cache silently masks
	// every newly installed icon).
	SystemIndexTheme []byte `json:"-" yaml:"-"`
	// LegacyIconThemeMarkers are authorship-marker basenames written by the
	// installers this module replaces (".ghk-wrote-index-theme",
	// ".frameworks-wrote-index-theme"). Uninstall honours them so an install
	// laid down BEFORE the migration can still clean up its index.theme;
	// install never writes them.
	LegacyIconThemeMarkers []string `json:"legacy-icon-theme-markers,omitempty" yaml:"legacy-icon-theme-markers,omitempty"`

	// Requires is the dependency axis: what the app needs, and how that need is
	// met per output format. See requires.go — this is the dimension neither
	// Spec had, and the reason merging them was necessary but not sufficient.
	Requires []Dependency `json:"ships,omitempty" yaml:"ships,omitempty"`

	// --- desktop-application half, merged in from pkg/installer.Spec ---
	//
	// See desktop.go for the types and the findings each default encodes.

	// DisplayName is the human name used in install/uninstall MESSAGES, e.g.
	// "voicelab". Distinct from DesktopName, which is the .desktop Name= key
	// the desktop environment shows in its menu: one is operator-facing
	// output, the other is a rendered file's content, and an app can
	// legitimately want them different. Defaults to ShareSubdir, then App.
	DisplayName string `json:"display-name,omitempty" yaml:"display-name,omitempty"`

	// ShareSubdir is the directory under <prefix>/share holding the extracted
	// tree, e.g. "voicelab" or "word-bank-ui".
	ShareSubdir string `json:"share-subdir,omitempty" yaml:"share-subdir,omitempty"`

	// ConfigSubdir is the per-application directory name under the config,
	// state and cache homes. Defaults to ShareSubdir, so an app has ONE name
	// across every tree rather than one for its payload and another for its
	// settings. Set it only when they must genuinely differ.
	ConfigSubdir string `json:"config-subdir,omitempty" yaml:"config-subdir,omitempty"`

	// UnitSourceDir is the directory WITHIN the payload holding service unit
	// templates, one per daemon component, named by [Component.UnitName].
	// Defaults to "units".
	//
	// The templates are the repo's own files and keep their own Restart=,
	// After=, Environment= and the rest. Only the __TOKEN__ values are supplied
	// by the install, which is the whole design: generating unit text from
	// scratch would have discarded everything a repo tuned by hand.
	UnitSourceDir string `json:"unit-source-dir,omitempty" yaml:"unit-source-dir,omitempty"`

	// Components are the installable pieces of this application: its UI, its
	// daemon, its CLI tools, its helpers. Each declares a ROLE, and the role
	// plus the platform decide the destination — the manifest never names a
	// directory. See [Component] and [Role].
	//
	// Empty is valid and means "a payload with no per-component handling",
	// which is every consumer written before this field existed. Adding
	// components is opt-in; nothing breaks by omitting them.
	Components []Component `json:"components,omitempty" yaml:"components,omitempty"`

	// DesktopNaming selects the installed entry's basename. The zero value
	// (DesktopByAppID) is correct for Wayland — see its documentation, because
	// the wrong value loses the window icon silently rather than erroring.
	DesktopNaming DesktopNaming `json:"desktop-naming,omitempty" yaml:"desktop-naming,omitempty"`

	// Launchers are the bin/ symlinks to create. At least one is required for
	// a desktop install: an install with no entry point is unreachable.
	Launchers []Launcher `json:"launchers,omitempty" yaml:"launchers,omitempty"`

	// CleanMode selects how much of a prior install is removed. The zero value
	// (CleanAppDir) removes everything, which is what you want unless you can
	// NAME what must survive.
	CleanMode CleanMode `json:"clean-mode,omitempty" yaml:"clean-mode,omitempty"`

	// CleanSubdirs names the subdirectories removed when CleanMode is
	// CleanSubdirs. Ignored otherwise.
	CleanSubdirs []string `json:"clean-subdirs,omitempty" yaml:"clean-subdirs,omitempty"`

	// Notes are extra lines printed after a successful install — runtime
	// requirements, first-run hints. Optional.
	Notes []string `json:"notes,omitempty" yaml:"notes,omitempty"`

	// Scope selects the systemd manager for Units.
	Scope Scope `json:"scope,omitempty" yaml:"scope,omitempty"`
	// UnitDir overrides the scope-derived unit directory.
	UnitDir string `json:"unit-dir,omitempty" yaml:"unit-dir,omitempty"`
	// Units are the systemd units this payload ships.
	Units []Unit `json:"units,omitempty" yaml:"units,omitempty"`
	// Tokens substituted into unit Content. A __TOKEN__ appearing in a unit
	// but absent here is a hard error, not an empty string.
	Tokens map[string]string `json:"tokens,omitempty" yaml:"tokens,omitempty"`

	// Chart and Kube drive the kubernetes target.
	Chart *Chart `json:"chart,omitempty" yaml:"chart,omitempty"`
	Kube  Kube   `json:"kube,omitempty" yaml:"kube,omitempty"`
	// RenderTo is the directory rendered manifests are written to.
	RenderTo string `json:"-" yaml:"-"`

	// Home, ConfigHome and PathEnv are injected so path derivation is
	// testable without touching the real environment. Empty values are
	// resolved from the process environment at the CALL SITE (see
	// cmd/installkit), never inside the pure render.
	Home       string `json:"-" yaml:"-"`
	ConfigHome string `json:"-" yaml:"-"`
	PathEnv    string `json:"-" yaml:"-"`
}

// DesktopFileName is the basename the desktop entry is installed under:
// DesktopName when set, else "<AppID>.desktop", else "<App>.desktop".
func (s Spec) DesktopFileName() string {
	if s.DesktopName != "" {
		return s.DesktopName
	}
	if s.AppID != "" {
		return s.AppID + ".desktop"
	}
	return s.App + ".desktop"
}

// UnitsOfKinds filters Units to the requested kinds, preserving Spec order.
// An empty kinds slice means "whatever the payload ships".
func (s Spec) UnitsOfKinds(kinds []UnitKind) []Unit {
	if len(kinds) == 0 {
		return s.Units
	}
	want := make(map[UnitKind]bool, len(kinds))
	for _, k := range kinds {
		want[k] = true
	}
	out := make([]Unit, 0, len(s.Units))
	for _, u := range s.Units {
		if want[u.Kind] {
			out = append(out, u)
		}
	}
	return out
}

// TokenNames returns the Spec's token names, sorted — used in error messages
// so a missing token reports what WAS available.
func (s Spec) TokenNames() []string {
	out := make([]string, 0, len(s.Tokens))
	for k := range s.Tokens {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// Validate checks the whole Spec: the desktop half ([Spec.ValidateDesktop])
// and the dependency axis ([Spec.ValidateRequires]). Errors from both are
// returned together, so one call reports every problem rather than the first.
//
// THIS NAME IS THE PUBLISHED CONTRACT. `Validate` is what pkg/installer.Spec
// has exported since go/v0.1.0, and consumers call it directly — mountbridge'
// cmd/installer suite opens with `spec.Validate()`. When the desktop half
// merged into this package its method arrived as ValidateDesktop, which
// silently removed `Validate` from the aliased type: production code still
// compiled (nothing internal called it) and only a CONSUMER'S TEST failed.
// That is why this method exists rather than a rename — and why the
// regression test for it lives in pkg/installer, where the alias is, instead
// of here.
//
// Behaviour is unchanged for any Spec written before the merge: those declare
// no Requires, and ValidateRequires over an empty slice returns nil, so
// Validate reduces exactly to the desktop validation it used to be.
func (s Spec) Validate() error {
	var errs []string
	if err := s.ValidateDesktop(); err != nil {
		errs = append(errs, err.Error())
	}
	if err := s.ValidateRequires(); err != nil {
		errs = append(errs, err.Error())
	}
	if err := ValidateComponents(s.Components); err != nil {
		errs = append(errs, err.Error())
	}
	if len(errs) == 0 {
		return nil
	}
	return fmt.Errorf("%s", strings.Join(errs, "\n"))
}
