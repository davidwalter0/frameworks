package installer

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"

	"github.com/davidwalter0/frameworks/go/pkg/instruct"
)

// IconThemeMarker is the basename of a marker file recording that an installer
// wrote the hicolor theme's index.theme itself, as opposed to it having been
// copied from an existing system theme.
//
// Uninstall removes an index.theme only when this marker says we created it —
// a shared prefix may hold other applications' icons, and deleting a
// system-provided theme index would break all of them.
const IconThemeMarker = ".frameworks-wrote-index-theme"

// SystemHicolorIndexTheme is the canonical system-provided index.theme,
// preferred over the minimal fallback so distro theming metadata (fallback
// chains, translated names) survives. It is a var rather than a const so tests
// can point it at a temp path instead of the real system file.
var SystemHicolorIndexTheme = "/usr/share/icons/hicolor/index.theme"

// minimalHicolorIndexTheme is written when no system index.theme is found —
// just enough for gtk-update-icon-cache to accept the directory as a theme.
const minimalHicolorIndexTheme = `[Icon Theme]
Name=Hicolor
Comment=Fallback icon theme
Directories=256x256/apps,scalable/apps

[256x256/apps]
Size=256
Context=Applications
Type=Fixed

[scalable/apps]
Size=256
Context=Applications
Type=Scalable
MinSize=1
MaxSize=512
`

// installIcons mirrors the staged hicolor icons (extracted under
// <appDir>/icons/hicolor by the payload) into the prefix's icon theme, so GTK
// and the desktop resolve them by name.
//
// A missing source file is skipped rather than failing the install: an older
// payload may not stage every size, and a missing icon degrades to the generic
// one rather than leaving the app uninstalled.
func installIcons(s Spec, lay Layout) error {
	for _, rel := range s.IconRelsOrDefault() {
		src := filepath.Join(lay.AppDir, "icons", "hicolor", rel)
		if _, err := os.Stat(src); err != nil {
			continue
		}
		dst := filepath.Join(lay.Theme, rel)
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		if err := CopyFile(src, dst, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// ensureIconTheme makes sure theme/index.theme exists before
// gtk-update-icon-cache is invoked against it.
//
// Without one, gtk-update-icon-cache refuses to run ("No theme index file"),
// and any stale icon-theme.cache left from a prior run then masks the newly
// installed icons from GTK entirely — the icon looks unchanged and the cause
// is invisible. Prefers copying the system hicolor index.theme; falls back to
// a minimal valid one. Either way it records authorship via [IconThemeMarker]
// so uninstall knows it may remove the file.
func ensureIconTheme(theme string) error {
	dst := filepath.Join(theme, "index.theme")
	if _, err := os.Stat(dst); err == nil {
		return nil // already present — never touch someone else's
	}
	if err := os.MkdirAll(theme, 0o755); err != nil {
		return err
	}
	// The marker must be written on BOTH paths, because we authored the file on
	// both. Writing it only after the synthesize fallback (as this did) strands
	// index.theme forever on every host that HAS a system hicolor theme — which
	// is every real desktop, i.e. the common case — while the tests, which point
	// SystemHicolorIndexTheme at an absent file, exercise only the rare one.
	if err := CopyFile(SystemHicolorIndexTheme, dst, 0o644); err != nil {
		if err := os.WriteFile(dst, []byte(minimalHicolorIndexTheme), 0o644); err != nil {
			return err
		}
	}
	return os.WriteFile(filepath.Join(theme, IconThemeMarker), nil, 0o644)
}

// removeWrittenIconTheme deletes the hicolor index.theme only if this family's
// installer wrote it (per [IconThemeMarker]) AND no other application's icons
// remain in the theme directory.
//
// It also removes icon-theme.cache, which is OUR litter: [refreshIconCache]
// runs gtk-update-icon-cache during install, and that tool writes the cache
// beside the index. Reaching this point means the theme is now empty of icons,
// so the cache describes nothing — leaving it strands a binary blob in the
// user's prefix forever, and a stale cache is precisely what masks icons from
// GTK later (see [ensureIconTheme]). Removing it is only safe HERE, under the
// same two conditions that authorize removing the index itself.
//
// (Found 2026-08-09 by the byte-identical gate on the voicelab migration: the
// pre-migration installer never wrote an index.theme, so its cache refresh
// always failed and no cache was ever produced to leak. Fixing one bug exposed
// the other.)
func removeWrittenIconTheme(theme string) {
	marker := filepath.Join(theme, IconThemeMarker)
	if _, err := os.Stat(marker); err != nil {
		return // not ours to remove
	}
	if hasRemainingIcons(theme) {
		return // another app still needs the theme index
	}
	_ = os.Remove(filepath.Join(theme, "index.theme"))
	_ = os.Remove(filepath.Join(theme, "icon-theme.cache"))
	_ = os.Remove(marker)
}

// hasRemainingIcons reports whether any .png/.svg file still exists under
// theme.
func hasRemainingIcons(theme string) bool {
	found := false
	_ = filepath.WalkDir(theme, func(path string, d os.DirEntry, err error) error {
		if err != nil || found || d.IsDir() {
			return nil
		}
		if ext := filepath.Ext(path); ext == ".png" || ext == ".svg" {
			found = true
		}
		return nil
	})
	return found
}

// iconPhase says which side of the install this cache advice is for. It
// replaces a bare ensureTheme bool because the two directions need OPPOSITE
// cache tests (see [iconCacheStale]), and a second bool beside the first
// invited callers to pass a coincidence rather than an intent.
type iconPhase int

const (
	iconInstall iconPhase = iota
	iconUninstall
)

// iconNamesFromRels returns the icon NAMES a theme lookup resolves, for
// hicolor-relative paths: the basename with its extension removed, deduplicated
// in first-seen order. "256x256/apps/com.example.App.png" yields
// "com.example.App".
//
// Derived from the rels rather than read off Spec.AppID because Spec.IconRels
// may be set to something other than the AppID-derived default, and the cache
// lists what was actually installed.
func iconNamesFromRels(rels []string) []string {
	var names []string
	seen := map[string]bool{}
	for _, rel := range rels {
		base := filepath.Base(rel)
		name := strings.TrimSuffix(base, filepath.Ext(base))
		if name == "" || name == "." || seen[name] {
			continue
		}
		seen[name] = true
		names = append(names, name)
	}
	return names
}

// iconCacheStale reports whether theme/icon-theme.cache disagrees with what is
// now on disk, and returns the cache's path for the message.
//
// GTK trusts icon-theme.cache whenever it is newer than the theme's TOP
// directory. Installing into an EXISTING size directory (256x256/apps,
// scalable/apps) does not touch the top directory, so a cache written before
// the install still wins, still does not list the new name, and the lookup
// fails at every size.
//
// Measured 2026-09-12 against GTK 3 Gtk.IconTheme.lookup_icon, on a copy of a
// real ~/.local/share/icons/hicolor: with the pre-existing cache in place both
// 48 px and 256 px returned None; rebuilding the cache resolved both, and so
// did DELETING it (with no cache GTK scans the directories). So the hazard
// exists only in the "cache present but stale" state.
//
// The two phases need opposite tests:
//
//   - [iconInstall]: a cache that does NOT list a name is stale — the icon the
//     install just wrote is invisible.
//   - [iconUninstall]: a cache that STILL lists a name is stale — the lookup
//     resolves to files that were just removed.
//
// Testing for the name as a byte substring is sufficient, not a heuristic: the
// cache is a binary hash table whose string section stores icon names verbatim.
// Measured on the same pair — `grep -aF` found 0 occurrences in the stale cache
// and 1 in the rebuilt one.
func iconCacheStale(theme string, names []string, phase iconPhase) (bool, string) {
	cache := filepath.Join(theme, "icon-theme.cache")
	blob, err := os.ReadFile(cache)
	if err != nil {
		// No cache (or unreadable): GTK scans the directories, so there is
		// nothing an operator needs to do in either phase.
		return false, cache
	}
	for _, name := range names {
		listed := bytes.Contains(blob, []byte(name))
		if (phase == iconInstall && !listed) || (phase == iconUninstall && listed) {
			return true, cache
		}
	}
	return false, cache
}

// refreshIconCache tells the operator whether the hicolor icon cache must be
// rebuilt, and with which command.
//
// Install creates a missing index.theme first — gtk-update-icon-cache will not
// run at all without one. Uninstall must not: [removeWrittenIconTheme] may have
// just deleted index.theme, and recreating it here would resurrect the very
// file uninstall removed, orphaning it permanently once the marker is gone.
//
// It PRINTS the command rather than running it. This package used to exec
// gtk-update-icon-cache here, which was its one violation of D-0004's
// invariant: an installer materializes artifacts and prints activation
// commands, it never activates. Absorbing installkit (D-0005) brought that
// invariant along with a test that enforces it mechanically
// ([TestExactlyOneExecPath] in pkg/target), so the exec had to go.
//
// # Why the message is conditional, and why it no longer says "optional"
//
// Until 2026-09-12 this printed, unconditionally, "to refresh the icon cache
// now (optional; otherwise it updates at next login)". BOTH halves were false
// whenever a cache already existed: the rebuild is required (see
// [iconCacheStale]), and nothing rebuilds a per-user cache at login — there is
// no autostart entry and no systemd user unit that runs gtk-update-icon-cache.
//
// That wording was correct only while this function EXEC'd the refresh
// best-effort. When the exec became a printed instruction at go/v0.1.2 the
// printed line became the ONLY mechanism, and it was telling the operator to
// skip the only thing that would work — so every family app installed into a
// theme with an existing cache showed no icon. Reported from zplay as "the icon
// isn't loaded" (mgmt todo 724536d3).
//
// The lesson is the one this package keeps re-learning: when a mechanism
// changes, the prose describing it does not follow by itself. Printing nothing
// when nothing is needed is deliberate — an unconditional notice trains the
// reader to ignore it, which is how the false "optional" survived.
func refreshIconCache(theme string, names []string, phase iconPhase, out progress) {
	if phase == iconInstall {
		if err := ensureIconTheme(theme); err != nil {
			out.printf("warning: could not prepare icon theme index for %s: %v\n", theme, err)
			return
		}
	} else if _, err := os.Stat(filepath.Join(theme, "index.theme")); err != nil {
		return // nothing to refresh; do not recreate what uninstall removed
	}

	stale, cache := iconCacheStale(theme, names, phase)
	if !stale {
		return
	}

	if phase == iconInstall {
		out.printf("REQUIRED: rebuild the icon cache — until you do, the icon will not appear.\n")
		out.printf("  %s predates this install and does not list the new icon. GTK trusts that\n", cache)
		out.printf("  cache while it is newer than %s, and writing into an existing size\n", theme)
		out.printf("  directory does not touch it. Nothing rebuilds a per-user cache at login.\n")
	} else {
		out.printf("REQUIRED: rebuild the icon cache — it still lists an icon that was removed.\n")
		out.printf("  %s would otherwise resolve the name to files that no longer exist.\n", cache)
	}
	out.printf("  %s\n", instruct.GtkUpdateIconCache(theme))
}
