package installer

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

// Options tune an install or uninstall. The zero value is correct for a normal
// run: install to the default prefix, report to stdout.
type Options struct {
	// Prefix is the install prefix. Empty uses [DefaultPrefix].
	Prefix string
	// Out receives progress and warnings. Nil uses os.Stdout.
	Out io.Writer
	// SelfName overrides the executable path printed in the uninstall hint.
	// Empty derives it from os.Executable().
	SelfName string
	// Manifest is the raw manifest.yaml the consumer embedded, written
	// verbatim into the installed tree so the install describes itself. Nil
	// is valid and yields a receipt only — see writeRecord.
	Manifest []byte

	// Platform selects the filesystem conventions to install under. Empty uses
	// the running platform. Set it explicitly when RENDERING for another host —
	// staging a macOS tree from a Linux builder, say.
	Platform spec.Platform

	// Env is the environment paths derive from. The zero value reads the real
	// environment via [spec.OSEnv]. Injectable so a test can describe any
	// machine without setenv.
	Env spec.Env

	// Overrides pin individual directories, for a staging DESTDIR, a distro
	// prefix, or a Homebrew tree. See [spec.Overrides].
	Overrides spec.Overrides
}

// layout resolves the install's directories once. Everything downstream takes
// paths from the returned Layout, so no second call site can derive a different
// answer — which is how a unit came to name a binary the installer never wrote.
//
// COMPATIBILITY NOTE. When the caller sets Prefix (which every current consumer
// does, because DefaultPrefix() is their flag's default), the prefix wins and
// the four historical directories resolve EXACTLY as Spec.LayoutFor produced
// them. XDG_DATA_HOME is honoured only when no prefix is pinned. That is
// deliberate: an explicit --prefix must not be quietly overridden by an
// environment variable, and a consumer that wants XDG behaviour opts in by
// leaving Prefix empty.
func (o Options) layout(s Spec) (Layout, error) {
	p := o.Platform
	if p == "" {
		p = spec.CurrentPlatform()
	}
	env := o.Env
	if env.Home == "" {
		env = spec.OSEnv()
	}
	ov := o.Overrides
	if ov.Prefix == "" && o.Prefix != "" {
		ov.Prefix = o.Prefix
	}
	return s.LayoutForPlatform(p, env, ov)
}

func (o Options) out() progress {
	if o.Out != nil {
		return progress{o.Out}
	}
	return progress{os.Stdout}
}

func (o Options) selfName() string {
	if o.SelfName != "" {
		return o.SelfName
	}
	if exe, err := os.Executable(); err == nil {
		return exe
	}
	return "installer"
}

// Install extracts payload into the prefix and wires up launchers, the desktop
// entry and the icon theme.
//
// version is stamped into the progress output only; it is not persisted.
func Install(s Spec, payload []byte, version string, opt Options) error {
	if err := s.ValidateDesktop(); err != nil {
		return err
	}
	// Components are validated separately rather than by calling s.Validate(),
	// which would also run ValidateRequires and so change what an existing
	// consumer's install rejects. Widening a validation is a behaviour change
	// and belongs to the consumer's own migration, not to this wiring.
	if err := spec.ValidateComponents(s.Components); err != nil {
		return err
	}
	if len(payload) == 0 {
		return fmt.Errorf("this installer has no embedded payload; build it with -tags withpayload")
	}
	lay, err := opt.layout(s)
	if err != nil {
		return err
	}
	out := opt.out()

	out.printf("Installing %s %s → %s\n", s.DisplayNameOrDefault(), version, lay.AppDir)

	if err := clean(s, lay); err != nil {
		return err
	}
	for _, d := range []string{lay.AppDir, lay.BinDir, lay.AppsDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return err
		}
	}

	if err := ExtractTarGz(payload, lay.AppDir); err != nil {
		return fmt.Errorf("extract payload: %w", err)
	}

	for _, l := range s.Launchers {
		if err := ForceSymlink(filepath.Join(lay.AppDir, l.Target), filepath.Join(lay.BinDir, l.Name)); err != nil {
			return err
		}
	}

	// Components are ADDITIVE to Launchers, not a replacement: a consumer that
	// has not declared components yet keeps working unchanged. Only a cli role
	// reaches BinDir — a daemon or helper on PATH is how eight cross-bridge
	// binaries came to shadow each other.
	//
	// ForceSymlink removes before it creates, which matters here beyond
	// idempotency: BinDir entries are symlinks INTO the app tree, and a writer
	// that opened the destination instead would follow the link and overwrite
	// the installed binary itself.
	for _, c := range s.Components {
		if !c.Role.OnPath() {
			continue
		}
		if err := ForceSymlink(lay.PayloadPathFor(c), lay.DestinationFor(c)); err != nil {
			return err
		}
	}

	tokens, err := installTokens(s, lay)
	if err != nil {
		return err
	}

	if err := writeDesktop(s, lay, tokens); err != nil {
		return err
	}

	if err := installUnits(s, lay, tokens, out); err != nil {
		return err
	}

	if err := installIcons(s, lay); err != nil {
		return err
	}
	refreshIconCache(lay.Theme, iconNamesFromRels(s.IconRelsOrDefault()), iconInstall, out)

	// Record what this install is and what it created, so the tree can be
	// audited, re-checked against a host, or packaged without the installer
	// binary that made it.
	if err := writeRecord(s, lay, version, opt.Manifest); err != nil {
		return err
	}

	report(s, lay, out, opt.selfName())
	return nil
}

// clean removes a previous install per the spec's [CleanMode].
func clean(s Spec, lay Layout) error {
	if s.CleanMode == CleanSubdirs {
		for _, sub := range s.CleanSubdirs {
			if err := os.RemoveAll(filepath.Join(lay.AppDir, sub)); err != nil {
				return err
			}
		}
		return nil
	}
	return os.RemoveAll(lay.AppDir)
}

// installTokens builds the substitution table once per install: the values the
// layout computed, with the author's own Spec.Tokens layered beneath.
//
// A collision between the two is refused rather than resolved by precedence —
// see [spec.MergeTokens]. That refusal is the point of the exercise: a
// hand-written __EXEC__ beside a computed one is either redundant, and will rot
// the first time the layout changes, or already wrong.
func installTokens(s Spec, lay Layout) (map[string]string, error) {
	derived, err := lay.Tokens(s)
	if err != nil {
		return nil, err
	}
	return spec.MergeTokens(derived, s.Tokens)
}

// substituteTokens replaces every __TOKEN__ the table defines.
//
// Unknown tokens are left ALONE rather than blanked. A placeholder that
// survives into an installed file is visible and reported by a test; an empty
// string substituted into an Exec= line produces a menu entry that launches
// nothing and looks fine in a diff.
func substituteTokens(content string, tokens map[string]string) string {
	// Longest-first, so __EXEC_FOO__ is not partially eaten by __EXEC__.
	names := make([]string, 0, len(tokens))
	for k := range tokens {
		names = append(names, k)
	}
	slices.SortFunc(names, func(a, b string) int { return len(b) - len(a) })
	for _, k := range names {
		content = strings.ReplaceAll(content, k, tokens[k])
	}
	return content
}

// writeDesktop copies the payload's .desktop template into the applications
// directory, substituting the layout's tokens.
//
// Previously this substituted __PREFIX__ alone. It now takes the whole table so
// an entry can name a component directly — Exec=__EXEC_DEMO_UI__ — instead of
// rebuilding the path out of __PREFIX__ and a hardcoded subdirectory, which is
// the same "spell the destination twice" defect one layer down.
//
// A payload with no template is not an error — the app simply gets no menu
// entry, which is the correct outcome for a CLI-only install.
func writeDesktop(s Spec, lay Layout, tokens map[string]string) error {
	if s.DesktopSource == "" {
		return nil
	}
	src := filepath.Join(lay.AppDir, s.DesktopSource)
	b, err := os.ReadFile(src)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	return os.WriteFile(
		filepath.Join(lay.AppsDir, s.DesktopTarget()),
		[]byte(substituteTokens(string(b), tokens)), 0o644)
}

// installUnits materializes a service unit for each daemon component, taking
// its template from the payload and its paths from the layout.
//
// IT DOES NOT ENABLE OR START ANYTHING (D-0004). Generating a unit is not
// activating one; the activation command is printed by report(). That boundary
// is why this can run unattended.
//
// A daemon whose template is missing is an ERROR, not a skip. The component
// declared a daemon role, so a silent skip produces an install that looks
// complete and has no service — precisely the class of failure this whole
// change exists to remove. Contrast writeDesktop, where absence legitimately
// means "CLI-only install".
func installUnits(s Spec, lay Layout, tokens map[string]string, out progress) error {
	var unitful []Component
	for _, c := range s.Components {
		if c.HasUnit() {
			unitful = append(unitful, c)
		}
	}
	if len(unitful) == 0 {
		return nil
	}
	if lay.UnitDir == "" {
		return fmt.Errorf(
			"%d component(s) declare a service unit but the layout resolved no unit directory",
			len(unitful))
	}
	if err := os.MkdirAll(lay.UnitDir, 0o755); err != nil {
		return err
	}

	for _, c := range unitful {
		src := filepath.Join(lay.AppDir, s.UnitSourceDirOrDefault(), c.UnitName())
		b, err := os.ReadFile(src)
		if err != nil {
			if os.IsNotExist(err) {
				return fmt.Errorf(
					"component %q declares a service unit but its template is missing: %s",
					c.Name, src)
			}
			return err
		}
		dst := lay.UnitPathFor(c)
		if err := os.WriteFile(dst, []byte(substituteTokens(string(b), tokens)), 0o644); err != nil {
			return err
		}
		out.printf("  unit %s → %s\n", c.UnitName(), dst)
	}
	return nil
}

// Uninstall removes everything Install created for this spec.
//
// It keeps going after a failure and returns the FIRST error: a partially
// removed install is worse than a fully removed one, so an unreadable
// directory must not strand the launchers and desktop entry.
func Uninstall(s Spec, opt Options) error {
	if err := s.ValidateDesktop(); err != nil {
		return err
	}
	lay, err := opt.layout(s)
	if err != nil {
		return err
	}

	var firstErr error
	rm := func(p string) {
		if err := os.RemoveAll(p); err != nil && firstErr == nil {
			firstErr = err
		}
	}

	rm(lay.AppDir)
	for _, l := range s.Launchers {
		rm(filepath.Join(lay.BinDir, l.Name))
	}
	// Whatever Install put on PATH, Uninstall takes off it. A bin entry left
	// behind is worse than a missed file: it is a dangling symlink on PATH,
	// which reports "No such file or directory" against a name the user still
	// sees, rather than "command not found".
	for _, c := range s.Components {
		if c.Role.OnPath() {
			rm(lay.DestinationFor(c))
		}
	}
	// Units are REMOVED but never stopped or disabled — the same boundary
	// Install respects (D-0004). report/uninstall output names the command; a
	// library that stops services on the user's behalf is doing something they
	// did not ask for, to a machine it cannot see the rest of.
	for _, c := range s.Components {
		if c.HasUnit() && lay.UnitDir != "" {
			rm(lay.UnitPathFor(c))
		}
	}
	if s.DesktopSource != "" {
		rm(filepath.Join(lay.AppsDir, s.DesktopTarget()))
	}
	for _, rel := range s.IconRelsOrDefault() {
		rm(filepath.Join(lay.Theme, rel))
	}
	removeWrittenIconTheme(lay.Theme)
	// iconUninstall — see refreshIconCache: recreating index.theme here would
	// resurrect the file removeWrittenIconTheme just deleted, and the cache test
	// inverts (a cache that STILL lists a removed icon is the stale one).
	refreshIconCache(lay.Theme, iconNamesFromRels(s.IconRelsOrDefault()), iconUninstall, opt.out())
	return firstErr
}

// report prints the post-install summary.
func report(s Spec, lay Layout, out progress, self string) {
	out.println()
	out.println("Installed:")
	width := 0
	for _, l := range s.Launchers {
		if n := len(l.Name); n > width {
			width = n
		}
	}
	for _, l := range s.Launchers {
		line := fmt.Sprintf("  %-*s : %s", width, l.Name, filepath.Join(lay.BinDir, l.Name))
		if l.Blurb != "" {
			line += "   " + l.Blurb
		}
		out.println(line)
	}
	if !OnPath(lay.BinDir) {
		out.printf("\nNOTE: %s is not on your PATH. Add to your shell rc:\n      export PATH=%q\n",
			lay.BinDir, lay.BinDir+":$PATH")
	}
	for _, n := range s.Notes {
		out.println(n)
	}
	out.printf("\nUninstall later:  %s --uninstall --prefix %s\n", self, lay.Prefix)
}

// DefaultPrefix is ~/.local, falling back to /usr/local when the home
// directory cannot be determined.
func DefaultPrefix() string {
	if h, err := os.UserHomeDir(); err == nil && h != "" {
		return filepath.Join(h, ".local")
	}
	return "/usr/local"
}

// OnPath reports whether dir appears in $PATH.
func OnPath(dir string) bool {
	return slices.Contains(filepath.SplitList(os.Getenv("PATH")), dir)
}
