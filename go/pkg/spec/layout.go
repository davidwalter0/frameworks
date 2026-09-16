package spec

import (
	"fmt"
	"os"
	"path/filepath"
)

// Env is the process environment a layout is derived FROM.
//
// It is a struct rather than direct os.Getenv calls so path derivation is
// testable without mutating the process environment — the same reason
// Spec.Home/ConfigHome already exist. [OSEnv] is the one place that reads the
// real environment, so every other function in this package stays pure.
//
// DERIVE, NEVER HARDCODE. Each field comes from its XDG variable with the
// specification's own default as fallback. Writing "~/.local/share" into the
// source is the identical defect to writing "~/go/bin" into a systemd unit,
// one directory later: a value someone typed, that nothing keeps true.
type Env struct {
	// Home is $HOME. Everything else falls back to a path under it.
	Home string

	// DataHome is $XDG_DATA_HOME, default ~/.local/share.
	DataHome string

	// ConfigHome is $XDG_CONFIG_HOME, default ~/.config.
	ConfigHome string

	// StateHome is $XDG_STATE_HOME, default ~/.local/state.
	StateHome string

	// CacheHome is $XDG_CACHE_HOME, default ~/.cache.
	CacheHome string

	// RuntimeDir is $XDG_RUNTIME_DIR. The specification gives it NO default and
	// requires applications to handle it being unset, so this may legitimately
	// be empty — callers that need a socket path must say what they do then.
	//
	// Not academic: a recorded failure had a daemon listening on
	// $XDG_RUNTIME_DIR/lspbridge/broker.sock while its client dialled
	// /tmp/lspbridge-<uid>/broker.sock. It presented as "the daemon is down"
	// and sent a session to inspect the wrong component entirely.
	RuntimeDir string
}

// OSEnv reads the environment.
//
// This is the ONLY function in this package that consults the process
// environment. Everything downstream takes an Env, so a test can describe any
// machine without setenv and without ordering hazards between parallel tests.
func OSEnv() Env {
	home, _ := os.UserHomeDir()
	return EnvForHome(home).withOverridesFromEnviron()
}

// EnvForHome returns the specification's DEFAULT paths for a given home, with
// no environment variables consulted.
//
// Useful for more than tests: rendering an install for another user, or staging
// a tree whose home is not the builder's. A test using this touches nothing on
// the host, which matters here because the alternative writes real systemd
// units into the developer's own ~/.config/systemd/user.
func EnvForHome(home string) Env {
	if home == "" {
		return Env{}
	}
	return Env{
		Home:       home,
		DataHome:   filepath.Join(home, ".local", "share"),
		ConfigHome: filepath.Join(home, ".config"),
		StateHome:  filepath.Join(home, ".local", "state"),
		CacheHome:  filepath.Join(home, ".cache"),
	}
}

// withOverridesFromEnviron lets a set XDG_* variable win over the default.
func (e Env) withOverridesFromEnviron() Env {
	for _, o := range []struct {
		name string
		dst  *string
	}{
		{"XDG_DATA_HOME", &e.DataHome},
		{"XDG_CONFIG_HOME", &e.ConfigHome},
		{"XDG_STATE_HOME", &e.StateHome},
		{"XDG_CACHE_HOME", &e.CacheHome},
		{"XDG_RUNTIME_DIR", &e.RuntimeDir},
	} {
		if v := os.Getenv(o.name); v != "" {
			*o.dst = v
		}
	}
	return e
}

// Overrides are explicit destinations that win over the platform's defaults.
//
// A FIRST-CLASS INPUT, NOT AN ESCAPE HATCH. Cross-platform packaging and
// distro packaging both need to place files somewhere the platform default does
// not name — a staging DESTDIR, /usr/local, a Homebrew prefix — and a library
// that can only produce its own opinion forces every such caller to bypass it.
// Bypassing is how the fleet ended up with three disagreeing prefix defaults.
//
// Any field left empty keeps the platform default.
type Overrides struct {
	// Prefix relocates the INSTALL TREE: AppDir, BinDir, AppsDir and Theme.
	//
	// It deliberately does NOT move ConfigDir, StateDir or CacheDir. Those are
	// not under the install prefix in any layout this package supports —
	// XDG puts config in ~/.config while data goes to ~/.local/share, and macOS
	// separates Preferences from Application Support. A Prefix that silently
	// relocated config would produce an app that installs correctly and then
	// cannot find its own settings.
	Prefix string

	// The remaining fields override exactly one directory each.
	BinDir    string
	AppDir    string
	AppsDir   string
	Theme     string
	ConfigDir string
	StateDir  string
	CacheDir  string
	UnitDir   string
}

// LayoutForPlatform resolves every directory an install touches, for a target
// platform, from an environment, with explicit overrides applied last.
//
// An UNKNOWN PLATFORM IS AN ERROR. Falling back to the Linux layout would not
// fail at install time — it would succeed, put files where nothing on that
// system looks for them, and surface weeks later as "the app doesn't start".
func (s Spec) LayoutForPlatform(p Platform, env Env, ov Overrides) (Layout, error) {
	var lay Layout
	switch p {
	case PlatformLinux:
		lay = s.linuxLayout(env)
	case PlatformDarwin:
		lay = s.darwinLayout(env)
	default:
		return Layout{}, fmt.Errorf(
			"spec: cannot resolve a layout for platform %q (supported: %q, %q)",
			p, PlatformLinux, PlatformDarwin)
	}

	if ov.Prefix != "" {
		lay.Prefix = ov.Prefix
		lay.AppDir = filepath.Join(ov.Prefix, "share", s.ShareSubdir)
		lay.BinDir = filepath.Join(ov.Prefix, "bin")
		lay.AppsDir = filepath.Join(ov.Prefix, "share", "applications")
		lay.Theme = filepath.Join(ov.Prefix, "share", "icons", "hicolor")
	}

	for _, o := range []struct {
		val string
		dst *string
	}{
		{ov.BinDir, &lay.BinDir},
		{ov.AppDir, &lay.AppDir},
		{ov.AppsDir, &lay.AppsDir},
		{ov.Theme, &lay.Theme},
		{ov.ConfigDir, &lay.ConfigDir},
		{ov.StateDir, &lay.StateDir},
		{ov.CacheDir, &lay.CacheDir},
		{ov.UnitDir, &lay.UnitDir},
	} {
		if o.val != "" {
			*o.dst = o.val
		}
	}

	lay.Platform = p
	return lay, nil
}

// linuxLayout is the XDG Base Directory layout.
//
// Note the prefix is ~/.local while CONFIG is ~/.config — outside it. That is
// the specification's shape, not an inconsistency to tidy, and it is why
// [Overrides.Prefix] does not move ConfigDir.
func (s Spec) linuxLayout(env Env) Layout {
	prefix := filepath.Join(env.Home, ".local")
	return Layout{
		Prefix: prefix,
		// Derived from DataHome rather than <prefix>/share so an explicitly set
		// XDG_DATA_HOME is honoured instead of silently ignored.
		AppDir:  filepath.Join(env.DataHome, s.ShareSubdir),
		AppsDir: filepath.Join(env.DataHome, "applications"),
		Theme:   filepath.Join(env.DataHome, "icons", "hicolor"),
		// The XDG specification defines no variable for user binaries. It names
		// the PATH directly: "User-specific executable files may be stored in
		// $HOME/.local/bin", and systemd's file-hierarchy(7) documents it for
		// executables "useful for shell invocation". So this is the one entry
		// derived from Home rather than from a variable.
		BinDir:    filepath.Join(env.Home, ".local", "bin"),
		ConfigDir: filepath.Join(env.ConfigHome, s.ConfigSubdirOrDefault()),
		StateDir:  filepath.Join(env.StateHome, s.ConfigSubdirOrDefault()),
		CacheDir:  filepath.Join(env.CacheHome, s.ConfigSubdirOrDefault()),
		UnitDir:   filepath.Join(env.ConfigHome, "systemd", "user"),
	}
}

// darwinLayout is the macOS layout.
//
// TWO HONEST APPROXIMATIONS, stated rather than buried:
//
//   - StateDir is ~/Library/Logs/<app>. macOS has no state directory in the XDG
//     sense; Logs is the closest platform convention for "survives, but is not
//     configuration". A consumer storing non-log state should override it.
//   - Theme is EMPTY. macOS has no hicolor icon theme — an application's icon
//     lives inside its bundle. Callers must treat an empty Theme as "this
//     platform installs no icon theme", not as a missing value to fill in.
//
// BINDIR IS ~/go/bin ON DARWIN, DELIBERATELY, AND IS A KNOWN DEBT.
// One consumer's macOS-side scripts (its cross-platform bridge agent and its
// code-signing helper) hardcode ~/go/bin, and the Screen-Recording/Accessibility
// TCC grant persists against the signed binary at that path. Moving it without
// fixing those scripts first would break the signing flow, so the debt is
// recorded here and filed rather than silently paid. See the follow-up filed
// against that consumer.
func (s Spec) darwinLayout(env Env) Layout {
	lib := filepath.Join(env.Home, "Library")
	return Layout{
		Prefix:    filepath.Join(env.Home, ".local"),
		AppDir:    filepath.Join(lib, "Application Support", s.ShareSubdir),
		BinDir:    filepath.Join(env.Home, "go", "bin"),
		AppsDir:   filepath.Join(env.Home, "Applications"),
		Theme:     "",
		ConfigDir: filepath.Join(lib, "Preferences", s.ConfigSubdirOrDefault()),
		StateDir:  filepath.Join(lib, "Logs", s.ConfigSubdirOrDefault()),
		CacheDir:  filepath.Join(lib, "Caches", s.ConfigSubdirOrDefault()),
		UnitDir:   filepath.Join(lib, "LaunchAgents"),
	}
}

// UnitSourceDirOrDefault is the payload subdirectory holding unit templates.
func (s Spec) UnitSourceDirOrDefault() string {
	if s.UnitSourceDir != "" {
		return s.UnitSourceDir
	}
	return "units"
}

// ConfigSubdirOrDefault is the per-application directory name used under the
// config, state and cache homes.
//
// It defaults to ShareSubdir so an app has ONE name across every tree rather
// than one name for its payload and another for its settings.
func (s Spec) ConfigSubdirOrDefault() string {
	if s.ConfigSubdir != "" {
		return s.ConfigSubdir
	}
	return s.ShareSubdir
}

// DestinationFor returns the absolute path a component is installed to.
//
// THIS IS THE SINGLE PRODUCER. Every generated artifact — a systemd unit's
// ExecStart, a desktop entry's Exec, a receipt entry — takes its path from
// here, so none of them can disagree with where the installer actually wrote.
//
// That is the whole mechanism. Two measured failures came from a destination
// being written down more than once: one daemon's units named ~/go/bin while
// its installer wrote to a per-app share directory instead (the unit
// definitions had drifted 19 commits stale of the installer), and another
// consumer shipped eight binaries duplicated between ~/.local/bin and
// ~/go/bin where PATH order decided which ran.
//
// Note a CLI's destination is its BinDir path — the symlink NAME. The symlink
// target is [Layout.PayloadPathFor]. Keeping them distinct matters: the unit
// and desktop entry must name the stable BinDir path, not the payload path,
// so a re-layout of the payload does not invalidate them.
func (l Layout) DestinationFor(c Component) string {
	if c.Role.OnPath() {
		return filepath.Join(l.BinDir, c.Name)
	}
	return l.PayloadPathFor(c)
}

// PayloadPathFor returns the component's path inside the app directory.
func (l Layout) PayloadPathFor(c Component) string {
	return filepath.Join(l.AppDir, c.RelPath())
}

// UnitPathFor returns the absolute path of a daemon component's generated unit.
func (l Layout) UnitPathFor(c Component) string {
	return filepath.Join(l.UnitDir, c.UnitName())
}
