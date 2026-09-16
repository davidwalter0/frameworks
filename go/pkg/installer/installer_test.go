package installer

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// --- helpers ---------------------------------------------------------------

type entry struct {
	name     string
	body     string
	mode     int64
	typeflag byte
	linkname string
}

// makeTarGz builds a gzip-compressed tar from entries, for use as a payload.
func makeTarGz(t *testing.T, entries []entry) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, e := range entries {
		tf := e.typeflag
		if tf == 0 {
			tf = tar.TypeReg
		}
		mode := e.mode
		if mode == 0 {
			mode = 0o644
		}
		hdr := &tar.Header{
			Name:     e.name,
			Mode:     mode,
			Size:     int64(len(e.body)),
			Typeflag: tf,
			Linkname: e.linkname,
		}
		if tf == tar.TypeDir || tf == tar.TypeSymlink {
			hdr.Size = 0
		}
		if err := tw.WriteHeader(hdr); err != nil {
			t.Fatalf("write header %q: %v", e.name, err)
		}
		if hdr.Typeflag == tar.TypeReg {
			if _, err := tw.Write([]byte(e.body)); err != nil {
				t.Fatalf("write body %q: %v", e.name, err)
			}
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	if err := gz.Close(); err != nil {
		t.Fatalf("close gzip: %v", err)
	}
	return buf.Bytes()
}

// testSpec is a two-launcher app resembling voicelab (CLI + GUI).
func testSpec() Spec {
	return Spec{
		AppID:         "com.example.testApp",
		DisplayName:   "test-app",
		ShareSubdir:   "test-app",
		DesktopSource: "test-app.desktop",
		Launchers: []Launcher{
			{Target: "bin/tcli", Name: "tcli", Blurb: "(try: tcli --help)"},
			{Target: "test-app-ui", Name: "test-app-ui"},
		},
	}
}

// testPayload stages the tree a real packaging run would produce.
func testPayload(t *testing.T) []byte {
	t.Helper()
	return makeTarGz(t, []entry{
		{name: "bin/", typeflag: tar.TypeDir, mode: 0o755},
		{name: "bin/tcli", body: "#!/bin/sh\necho cli\n", mode: 0o755},
		{name: "test-app-ui", body: "#!/bin/sh\necho gui\n", mode: 0o755},
		{name: "test-app.desktop", body: "[Desktop Entry]\nExec=__PREFIX__/bin/test-app-ui\nIcon=com.example.testApp\n"},
		{name: "icons/", typeflag: tar.TypeDir, mode: 0o755},
		{name: "icons/hicolor/256x256/apps/com.example.testApp.png", body: "PNGDATA"},
		{name: "icons/hicolor/scalable/apps/com.example.testApp.svg", body: "<svg/>"},
	})
}

// isolatedPrefix returns a temp prefix and points the system index.theme at a
// non-existent path, so tests exercise the minimal-fallback branch and never
// read the real /usr/share file.
func isolatedPrefix(t *testing.T) string {
	t.Helper()
	prefix := t.TempDir()
	orig := SystemHicolorIndexTheme
	SystemHicolorIndexTheme = filepath.Join(t.TempDir(), "absent", "index.theme")
	t.Cleanup(func() { SystemHicolorIndexTheme = orig })
	return prefix
}

func mustNotExist(t *testing.T, p string) {
	t.Helper()
	if _, err := os.Lstat(p); err == nil {
		t.Errorf("expected %s to be gone, it still exists", p)
	}
}

func mustExist(t *testing.T, p string) {
	t.Helper()
	if _, err := os.Lstat(p); err != nil {
		t.Errorf("expected %s to exist: %v", p, err)
	}
}

// --- Spec.Validate ---------------------------------------------------------

func TestSpecValidate(t *testing.T) {
	ok := testSpec()
	tests := []struct {
		name    string
		mutate  func(*Spec)
		wantErr string
	}{
		{"valid", func(*Spec) {}, ""},
		{"missing AppID", func(s *Spec) { s.AppID = "" }, "AppID is required"},
		{"missing ShareSubdir", func(s *Spec) { s.ShareSubdir = "" }, "ShareSubdir is required"},
		{"absolute ShareSubdir", func(s *Spec) { s.ShareSubdir = "/etc" }, "clean relative path"},
		{"traversal ShareSubdir", func(s *Spec) { s.ShareSubdir = "../evil" }, "clean relative path"},
		{"no launchers", func(s *Spec) { s.Launchers = nil }, "at least one entry"},
		{"launcher missing name", func(s *Spec) { s.Launchers = []Launcher{{Target: "x"}} }, "needs both Target and Name"},
		{"launcher name with path", func(s *Spec) {
			s.Launchers = []Launcher{{Target: "x", Name: "a/b"}}
		}, "bare basename"},
		{"clean subdirs mode without list", func(s *Spec) { s.CleanMode = CleanSubdirs }, "CleanSubdirs is empty"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := ok
			s.Launchers = append([]Launcher(nil), ok.Launchers...)
			tc.mutate(&s)
			err := s.ValidateDesktop()
			switch {
			case tc.wantErr == "" && err != nil:
				t.Fatalf("unexpected error: %v", err)
			case tc.wantErr != "" && err == nil:
				t.Fatalf("expected error containing %q, got nil", tc.wantErr)
			case tc.wantErr != "" && !strings.Contains(err.Error(), tc.wantErr):
				t.Fatalf("expected error containing %q, got %v", tc.wantErr, err)
			}
		})
	}
}

// A malformed spec must fail BEFORE anything is written into the user's
// prefix — a half-installed tree from a bad spec is the worst outcome.
func TestInstallRejectsBadSpecBeforeWriting(t *testing.T) {
	prefix := isolatedPrefix(t)
	s := testSpec()
	s.AppID = ""
	if err := Install(s, testPayload(t), "v0", Options{Prefix: prefix, Out: io_Discard{}}); err == nil {
		t.Fatal("expected validation error")
	}
	mustNotExist(t, filepath.Join(prefix, "share"))
	mustNotExist(t, filepath.Join(prefix, "bin"))
}

func TestInstallRejectsEmptyPayload(t *testing.T) {
	prefix := isolatedPrefix(t)
	err := Install(testSpec(), nil, "v0", Options{Prefix: prefix, Out: io_Discard{}})
	if err == nil || !strings.Contains(err.Error(), "no embedded payload") {
		t.Fatalf("expected empty-payload error, got %v", err)
	}
}

// --- desktop naming --------------------------------------------------------

// The .desktop file must be named for the app-id by default: on Wayland the
// window icon is resolved from the .desktop FILENAME, so any other name
// silently loses the icon.
func TestDesktopTargetNaming(t *testing.T) {
	s := testSpec()
	if got, want := s.DesktopTarget(), "com.example.testApp.desktop"; got != want {
		t.Errorf("default naming = %q, want %q", got, want)
	}
	s.DesktopNaming = DesktopByBasename
	if got, want := s.DesktopTarget(), "test-app.desktop"; got != want {
		t.Errorf("basename naming = %q, want %q", got, want)
	}
}

// --- extraction guards -----------------------------------------------------

func TestExtractRejectsPathTraversal(t *testing.T) {
	dst := t.TempDir()
	payload := makeTarGz(t, []entry{{name: "../escaped.txt", body: "nope"}})
	err := ExtractTarGz(payload, dst)
	if err == nil || !strings.Contains(err.Error(), "unsafe path") {
		t.Fatalf("expected unsafe-path error, got %v", err)
	}
	mustNotExist(t, filepath.Join(filepath.Dir(dst), "escaped.txt"))
}

// A payload that is not gzip at all must error rather than extract nothing
// successfully — a truncated or mis-staged payload.tar.gz would otherwise
// produce an "install" that placed no files and reported no problem.
//
// Carried over from voicelab' cmd/installer test suite (TestExtractTarGzBadGzip)
// when that installer migrated onto this package; it was the one claim its
// tests made that had no equivalent here.
func TestExtractRejectsNonGzipPayload(t *testing.T) {
	if err := ExtractTarGz([]byte("not gzip"), t.TempDir()); err == nil {
		t.Fatal("ExtractTarGz(garbage) = nil, want an error")
	}
}

func TestExtractRejectsAbsoluteSymlinkTarget(t *testing.T) {
	dst := t.TempDir()
	payload := makeTarGz(t, []entry{
		{name: "link", typeflag: tar.TypeSymlink, linkname: "/etc/passwd"},
	})
	err := ExtractTarGz(payload, dst)
	if err == nil || !strings.Contains(err.Error(), "unsafe absolute symlink") {
		t.Fatalf("expected absolute-symlink error, got %v", err)
	}
}

func TestExtractRejectsEscapingRelativeSymlink(t *testing.T) {
	dst := t.TempDir()
	payload := makeTarGz(t, []entry{
		{name: "sub/link", typeflag: tar.TypeSymlink, linkname: "../../outside"},
	})
	err := ExtractTarGz(payload, dst)
	if err == nil || !strings.Contains(err.Error(), "unsafe symlink target") {
		t.Fatalf("expected escaping-symlink error, got %v", err)
	}
}

func TestExtractAllowsInternalSymlink(t *testing.T) {
	dst := t.TempDir()
	payload := makeTarGz(t, []entry{
		{name: "real", body: "hello"},
		{name: "sub/link", typeflag: tar.TypeSymlink, linkname: "../real"},
	})
	if err := ExtractTarGz(payload, dst); err != nil {
		t.Fatalf("internal symlink should be allowed: %v", err)
	}
	mustExist(t, filepath.Join(dst, "sub", "link"))
}

// Modes must survive extraction or the launchers are not executable.
func TestExtractPreservesExecutableMode(t *testing.T) {
	dst := t.TempDir()
	payload := makeTarGz(t, []entry{{name: "bin/run", body: "#!/bin/sh\n", mode: 0o755}})
	if err := ExtractTarGz(payload, dst); err != nil {
		t.Fatalf("extract: %v", err)
	}
	fi, err := os.Stat(filepath.Join(dst, "bin", "run"))
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if fi.Mode().Perm()&0o111 == 0 {
		t.Errorf("mode = %v, want executable", fi.Mode().Perm())
	}
}

// --- round trip ------------------------------------------------------------

// The round-trip the migration plan requires: install into a temp prefix,
// assert every artifact, uninstall, assert the tree is clean.
func TestInstallUninstallRoundTrip(t *testing.T) {
	prefix := isolatedPrefix(t)
	s := testSpec()
	opt := Options{Prefix: prefix, Out: io_Discard{}, SelfName: "test-installer"}

	if err := Install(s, testPayload(t), "v1.2.3", opt); err != nil {
		t.Fatalf("install: %v", err)
	}

	lay := s.LayoutFor(prefix)
	desktop := filepath.Join(lay.AppsDir, "com.example.testApp.desktop")
	png := filepath.Join(lay.Theme, "256x256", "apps", "com.example.testApp.png")
	svg := filepath.Join(lay.Theme, "scalable", "apps", "com.example.testApp.svg")

	mustExist(t, filepath.Join(lay.AppDir, "bin", "tcli"))
	mustExist(t, filepath.Join(lay.BinDir, "tcli"))
	mustExist(t, filepath.Join(lay.BinDir, "test-app-ui"))
	mustExist(t, desktop)
	mustExist(t, png)
	mustExist(t, svg)

	// __PREFIX__ must have been substituted, or the menu entry launches nothing.
	b, err := os.ReadFile(desktop)
	if err != nil {
		t.Fatalf("read desktop: %v", err)
	}
	if strings.Contains(string(b), "__PREFIX__") {
		t.Error("desktop entry still contains __PREFIX__ placeholder")
	}
	if !strings.Contains(string(b), prefix) {
		t.Errorf("desktop entry does not reference the prefix %q:\n%s", prefix, b)
	}

	// The launchers must be symlinks resolving into the app dir.
	target, err := os.Readlink(filepath.Join(lay.BinDir, "tcli"))
	if err != nil {
		t.Fatalf("readlink: %v", err)
	}
	if want := filepath.Join(lay.AppDir, "bin", "tcli"); target != want {
		t.Errorf("tcli link = %q, want %q", target, want)
	}

	if err := Uninstall(s, opt); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	mustNotExist(t, lay.AppDir)
	mustNotExist(t, filepath.Join(lay.BinDir, "tcli"))
	mustNotExist(t, filepath.Join(lay.BinDir, "test-app-ui"))
	mustNotExist(t, desktop)
	mustNotExist(t, png)
	mustNotExist(t, svg)
}

// Re-running an install over an existing one must succeed and must not strand
// files from the older layout — the reason CleanAppDir is the default.
func TestReinstallRemovesStaleLayout(t *testing.T) {
	prefix := isolatedPrefix(t)
	s := testSpec()
	opt := Options{Prefix: prefix, Out: io_Discard{}}

	if err := Install(s, testPayload(t), "v1", opt); err != nil {
		t.Fatalf("first install: %v", err)
	}
	lay := s.LayoutFor(prefix)
	stale := filepath.Join(lay.AppDir, "old-layout-file")
	if err := os.WriteFile(stale, []byte("stale"), 0o644); err != nil {
		t.Fatalf("seed stale file: %v", err)
	}

	if err := Install(s, testPayload(t), "v2", opt); err != nil {
		t.Fatalf("second install: %v", err)
	}
	mustNotExist(t, stale)
	mustExist(t, filepath.Join(lay.BinDir, "tcli"))
}

// CleanSubdirs must preserve everything it does not name.
func TestCleanSubdirsPreservesOtherFiles(t *testing.T) {
	prefix := isolatedPrefix(t)
	s := testSpec()
	s.CleanMode = CleanSubdirs
	s.CleanSubdirs = []string{"bin"}
	opt := Options{Prefix: prefix, Out: io_Discard{}}

	if err := Install(s, testPayload(t), "v1", opt); err != nil {
		t.Fatalf("first install: %v", err)
	}
	lay := s.LayoutFor(prefix)
	keep := filepath.Join(lay.AppDir, "user-data.json")
	if err := os.WriteFile(keep, []byte("{}"), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := Install(s, testPayload(t), "v2", opt); err != nil {
		t.Fatalf("second install: %v", err)
	}
	mustExist(t, keep)
}

// --- icon theme ownership --------------------------------------------------

// Uninstall must remove an index.theme it wrote itself.
func TestUninstallRemovesOwnIconTheme(t *testing.T) {
	prefix := isolatedPrefix(t)
	s := testSpec()
	opt := Options{Prefix: prefix, Out: io_Discard{}}

	if err := Install(s, testPayload(t), "v1", opt); err != nil {
		t.Fatalf("install: %v", err)
	}
	lay := s.LayoutFor(prefix)
	mustExist(t, filepath.Join(lay.Theme, "index.theme"))
	mustExist(t, filepath.Join(lay.Theme, IconThemeMarker))

	if err := Uninstall(s, opt); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	mustNotExist(t, filepath.Join(lay.Theme, "index.theme"))
	mustNotExist(t, filepath.Join(lay.Theme, IconThemeMarker))
}

// The COPY-SUCCESS path: when the host has a real system hicolor index.theme,
// install copies it — and uninstall must still remove the copy.
//
// This is the common case on any real desktop and had no coverage: every other
// test leaves SystemHicolorIndexTheme pointing at an absent file, so only the
// synthesize fallback was ever exercised. The bug that hid there stranded
// index.theme permanently, because the authorship marker was written on the
// fallback path only.
func TestUninstallRemovesCopiedSystemIconTheme(t *testing.T) {
	prefix := isolatedPrefix(t)
	s := testSpec()
	opt := Options{Prefix: prefix, Out: io_Discard{}}

	// Stand in for /usr/share/icons/hicolor/index.theme with content distinct
	// from the synthesized fallback, so the assertion below proves which path ran.
	sysTheme := filepath.Join(t.TempDir(), "index.theme")
	const sysBody = "[Icon Theme]\nName=SystemHicolorUnderTest\nDirectories=48x48/apps\n"
	if err := os.WriteFile(sysTheme, []byte(sysBody), 0o644); err != nil {
		t.Fatalf("seed system theme: %v", err)
	}
	prev := SystemHicolorIndexTheme
	SystemHicolorIndexTheme = sysTheme
	t.Cleanup(func() { SystemHicolorIndexTheme = prev })

	if err := Install(s, testPayload(t), "v1", opt); err != nil {
		t.Fatalf("install: %v", err)
	}
	lay := s.LayoutFor(prefix)
	installed := filepath.Join(lay.Theme, "index.theme")

	b, err := os.ReadFile(installed)
	if err != nil {
		t.Fatalf("read installed theme: %v", err)
	}
	if string(b) != sysBody {
		t.Fatalf("copy-success path did not run: installed index.theme is the fallback, not the system copy\ngot:\n%s", b)
	}
	// The marker is what authorizes removal; its absence was the defect.
	mustExist(t, filepath.Join(lay.Theme, IconThemeMarker))

	if err := Uninstall(s, opt); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	mustNotExist(t, installed)
	mustNotExist(t, filepath.Join(lay.Theme, IconThemeMarker))
}

// icon-theme.cache is written by gtk-update-icon-cache, which THIS package
// invokes during install — so it is our litter, and uninstall must take it
// with the index it authored. A leftover cache is both a stranded binary blob
// and the thing that masks icons from GTK on a later install.
//
// The tool may not be installed on the test host, so the cache is seeded
// directly: the assertion is about uninstall's cleanup, not about GTK.
func TestUninstallRemovesOwnIconThemeCache(t *testing.T) {
	prefix := isolatedPrefix(t)
	s := testSpec()
	opt := Options{Prefix: prefix, Out: io_Discard{}}

	if err := Install(s, testPayload(t), "v1", opt); err != nil {
		t.Fatalf("install: %v", err)
	}
	lay := s.LayoutFor(prefix)
	cache := filepath.Join(lay.Theme, "icon-theme.cache")
	if err := os.WriteFile(cache, []byte("CACHE"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := Uninstall(s, opt); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	mustNotExist(t, cache)
}

// ...but a cache belonging to a theme another app still populates is NOT ours
// to delete: the same two conditions that protect index.theme protect it.
func TestUninstallKeepsIconThemeCacheWhenOtherIconsRemain(t *testing.T) {
	prefix := isolatedPrefix(t)
	s := testSpec()
	opt := Options{Prefix: prefix, Out: io_Discard{}}

	if err := Install(s, testPayload(t), "v1", opt); err != nil {
		t.Fatalf("install: %v", err)
	}
	lay := s.LayoutFor(prefix)
	cache := filepath.Join(lay.Theme, "icon-theme.cache")
	if err := os.WriteFile(cache, []byte("CACHE"), 0o644); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(lay.Theme, "256x256", "apps", "com.example.otherApp.png")
	if err := os.WriteFile(other, []byte("PNG"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := Uninstall(s, opt); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	mustExist(t, cache)
	mustExist(t, filepath.Join(lay.Theme, "index.theme"))
}

// A pre-existing (system or other-app) index.theme must survive both install
// and uninstall — a shared prefix may host other applications' icons.
func TestUninstallKeepsForeignIconTheme(t *testing.T) {
	prefix := isolatedPrefix(t)
	s := testSpec()
	lay := s.LayoutFor(prefix)
	if err := os.MkdirAll(lay.Theme, 0o755); err != nil {
		t.Fatalf("mkdir theme: %v", err)
	}
	foreign := filepath.Join(lay.Theme, "index.theme")
	if err := os.WriteFile(foreign, []byte("[Icon Theme]\nName=Foreign\n"), 0o644); err != nil {
		t.Fatalf("seed foreign theme: %v", err)
	}
	opt := Options{Prefix: prefix, Out: io_Discard{}}

	if err := Install(s, testPayload(t), "v1", opt); err != nil {
		t.Fatalf("install: %v", err)
	}
	if err := Uninstall(s, opt); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	mustExist(t, foreign)
	b, err := os.ReadFile(foreign)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !strings.Contains(string(b), "Foreign") {
		t.Errorf("foreign index.theme was overwritten: %s", b)
	}
}

// Our index.theme must NOT be removed while another app's icons remain.
func TestUninstallKeepsIconThemeWhenOtherIconsRemain(t *testing.T) {
	prefix := isolatedPrefix(t)
	s := testSpec()
	opt := Options{Prefix: prefix, Out: io_Discard{}}

	if err := Install(s, testPayload(t), "v1", opt); err != nil {
		t.Fatalf("install: %v", err)
	}
	lay := s.LayoutFor(prefix)
	other := filepath.Join(lay.Theme, "256x256", "apps", "com.example.otherApp.png")
	if err := os.WriteFile(other, []byte("PNG"), 0o644); err != nil {
		t.Fatalf("seed other icon: %v", err)
	}

	if err := Uninstall(s, opt); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	mustExist(t, filepath.Join(lay.Theme, "index.theme"))
	mustExist(t, other)
}

// --- misc ------------------------------------------------------------------

// A payload with no .desktop template is a CLI-only install, not an error.
func TestInstallWithoutDesktopTemplate(t *testing.T) {
	prefix := isolatedPrefix(t)
	s := testSpec()
	s.DesktopSource = ""
	s.Launchers = []Launcher{{Target: "bin/tcli", Name: "tcli"}}
	payload := makeTarGz(t, []entry{
		{name: "bin/tcli", body: "#!/bin/sh\n", mode: 0o755},
	})
	if err := Install(s, payload, "v1", Options{Prefix: prefix, Out: io_Discard{}}); err != nil {
		t.Fatalf("install: %v", err)
	}
	mustExist(t, filepath.Join(s.LayoutFor(prefix).BinDir, "tcli"))
}

// A payload missing an icon must degrade, not fail: older payloads did not
// stage every size.
func TestInstallToleratesMissingIcons(t *testing.T) {
	prefix := isolatedPrefix(t)
	s := testSpec()
	s.Launchers = []Launcher{{Target: "bin/tcli", Name: "tcli"}}
	payload := makeTarGz(t, []entry{
		{name: "bin/tcli", body: "#!/bin/sh\n", mode: 0o755},
		{name: "test-app.desktop", body: "[Desktop Entry]\n"},
	})
	if err := Install(s, payload, "v1", Options{Prefix: prefix, Out: io_Discard{}}); err != nil {
		t.Fatalf("install should tolerate absent icons: %v", err)
	}
}

// A member named exactly ".." is a DIFFERENT code path from "../x": Clean("..")
// is "..", with no separator for a prefix check to catch. Both must be refused.
//
// Carried over from word-bank's cmd/installer suite
// (TestExtractTarGz_RejectsExactParentEscape) during its migration onto this
// package — one of four claims it made that had no equivalent here.
func TestExtractRejectsExactParentEscape(t *testing.T) {
	// "../" is deliberately absent: archive/tar refuses to ENCODE a trailing
	// slash on a regular-file header, so that member cannot reach an extractor
	// in the first place.
	for _, name := range []string{"..", "bin/.."} {
		t.Run(name, func(t *testing.T) {
			dst := t.TempDir()
			if err := ExtractTarGz(makeTarGz(t, []entry{{name: name, body: "x"}}), dst); err == nil {
				t.Fatalf("member %q must be refused", name)
			}
		})
	}
}

// A Spec may name MORE icons than DefaultIconRels: word-bank stages three
// (512 PNG for the desktop entry, 256 PNG so window lists get a crisp render
// instead of a downscale, and the scalable SVG). Every named size must land —
// asserting the default pair only would silently drop the 512.
func TestInstallPlacesAllCustomIconRels(t *testing.T) {
	prefix := isolatedPrefix(t)
	s := testSpec()
	s.IconRels = []string{
		filepath.Join("512x512", "apps", s.AppID+".png"),
		filepath.Join("256x256", "apps", s.AppID+".png"),
		filepath.Join("scalable", "apps", s.AppID+".svg"),
	}
	entries := []entry{
		{name: "bin/tcli", body: "#!/bin/sh\n", mode: 0o755},
		{name: "test-app-ui", body: "#!/bin/sh\n", mode: 0o755},
	}
	for _, rel := range s.IconRels {
		entries = append(entries, entry{name: filepath.Join("icons", "hicolor", rel), body: "IMG:" + rel})
	}
	if err := Install(s, makeTarGz(t, entries), "v1", Options{Prefix: prefix, Out: io_Discard{}}); err != nil {
		t.Fatalf("install: %v", err)
	}
	lay := s.LayoutFor(prefix)
	for _, rel := range s.IconRels {
		mustExist(t, filepath.Join(lay.Theme, rel))
	}

	// ...and uninstall must take all three back, not just the default pair.
	if err := Uninstall(s, Options{Prefix: prefix, Out: io_Discard{}}); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	for _, rel := range s.IconRels {
		mustNotExist(t, filepath.Join(lay.Theme, rel))
	}
}

// A partially staged icon set must install what IS there. TestInstallTolerates-
// MissingIcons covers the all-absent case; the dangerous one is mixed, where an
// early skip could abort the sizes that follow it.
func TestInstallPartialIconStagingSkipsOnlyTheMissing(t *testing.T) {
	prefix := isolatedPrefix(t)
	s := testSpec()
	present := filepath.Join("256x256", "apps", s.AppID+".png")
	absent := filepath.Join("512x512", "apps", s.AppID+".png")
	trailing := filepath.Join("scalable", "apps", s.AppID+".svg")
	// Order matters: the missing size sits BETWEEN two present ones.
	s.IconRels = []string{present, absent, trailing}

	if err := Install(s, makeTarGz(t, []entry{
		{name: "bin/tcli", body: "#!/bin/sh\n", mode: 0o755},
		{name: "test-app-ui", body: "#!/bin/sh\n", mode: 0o755},
		{name: filepath.Join("icons", "hicolor", present), body: "PNG"},
		{name: filepath.Join("icons", "hicolor", trailing), body: "SVG"},
	}), "v1", Options{Prefix: prefix, Out: io_Discard{}}); err != nil {
		t.Fatalf("install: %v", err)
	}
	lay := s.LayoutFor(prefix)
	mustExist(t, filepath.Join(lay.Theme, present))
	mustNotExist(t, filepath.Join(lay.Theme, absent))
	mustExist(t, filepath.Join(lay.Theme, trailing)) // the skip must not stop here
}

// Re-installing over an existing install is the common case, and the previous
// version's launcher may be a real FILE rather than a symlink (an older layout,
// or a user's copy). os.Symlink refuses to clobber, so ForceSymlink has to
// replace whatever is in the way.
func TestForceSymlinkOverwritesExistingFile(t *testing.T) {
	dir := t.TempDir()
	link := filepath.Join(dir, "tcli")
	if err := os.WriteFile(link, []byte("an older real binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(dir, "real")
	if err := os.WriteFile(target, []byte("new"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := ForceSymlink(target, link); err != nil {
		t.Fatalf("ForceSymlink over an existing file: %v", err)
	}
	got, err := os.Readlink(link)
	if err != nil || got != target {
		t.Errorf("Readlink = %q, %v; want %q", got, err, target)
	}
}

// The three real shapes in this family, expressed through the builders.
func TestIconRelBuildersCoverTheFamilyShapes(t *testing.T) {
	const id = "com.example.app"
	for _, tc := range []struct {
		name string
		got  []string
		want []string
	}{
		{
			// voicelab, alert-log, netroute, gatehub-kit
			name: "single size plus scalable",
			got:  IconRels(id, 256),
			want: []string{"256x256/apps/" + id + ".png", "scalable/apps/" + id + ".svg"},
		},
		{
			// word-bank: the 512 is the desktop entry's default size and is
			// exactly what taking DefaultIconRels would have dropped.
			name: "two sizes plus scalable",
			got:  IconRels(id, 512, 256),
			want: []string{
				"512x512/apps/" + id + ".png",
				"256x256/apps/" + id + ".png",
				"scalable/apps/" + id + ".svg",
			},
		},
		{
			// mountbridge: six raster sizes, no SVG staged at all.
			name: "raster only, no scalable",
			got:  PNGIconRels(id, 512, 256, 128, 64, 48, 32),
			want: []string{
				"512x512/apps/" + id + ".png", "256x256/apps/" + id + ".png",
				"128x128/apps/" + id + ".png", "64x64/apps/" + id + ".png",
				"48x48/apps/" + id + ".png", "32x32/apps/" + id + ".png",
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if len(tc.got) != len(tc.want) {
				t.Fatalf("got %d rels %v, want %d", len(tc.got), tc.got, len(tc.want))
			}
			for i := range tc.want {
				if tc.got[i] != filepath.FromSlash(tc.want[i]) {
					t.Errorf("rel[%d] = %q, want %q", i, tc.got[i], tc.want[i])
				}
			}
		})
	}

	// DefaultIconRels must stay expressible as the one-size case, or the two
	// definitions drift.
	if a, b := DefaultIconRels(id), IconRels(id, 256); len(a) != len(b) || a[0] != b[0] || a[1] != b[1] {
		t.Errorf("DefaultIconRels %v != IconRels(id, 256) %v", a, b)
	}
}

// An icon whose basename is not the app-id installs fine and is then never
// found — the theme resolves by name. Nothing errors, the app just shows a
// generic icon, so Validate refuses it up front.
func TestValidateRejectsIconRelsNotNamedForAppID(t *testing.T) {
	s := testSpec()
	s.IconRels = []string{
		filepath.Join("256x256", "apps", s.AppID+".png"), // fine
		filepath.Join("512x512", "apps", "wrong-name.png"),
	}
	err := s.ValidateDesktop()
	if err == nil {
		t.Fatal("a mismatched icon basename must be refused")
	}
	for _, want := range []string{"wrong-name", s.AppID, "never be found"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error should mention %q; got: %v", want, err)
		}
	}

	// The correct set validates.
	s.IconRels = IconRels(s.AppID, 512, 256)
	if err := s.ValidateDesktop(); err != nil {
		t.Errorf("a well-formed icon set must validate: %v", err)
	}
	// So does a raster-only set.
	s.IconRels = PNGIconRels(s.AppID, 48, 32)
	if err := s.ValidateDesktop(); err != nil {
		t.Errorf("a raster-only icon set must validate: %v", err)
	}
}

// IconRels must not become a way to write outside the theme.
func TestValidateRejectsEscapingIconRel(t *testing.T) {
	s := testSpec()
	s.IconRels = []string{filepath.Join("..", "..", "apps", s.AppID+".png")}
	if err := s.ValidateDesktop(); err == nil {
		t.Fatal("an escaping icon rel must be refused")
	}
}

func TestDefaultIconRels(t *testing.T) {
	got := DefaultIconRels("com.example.app")
	want := []string{
		filepath.Join("256x256", "apps", "com.example.app.png"),
		filepath.Join("scalable", "apps", "com.example.app.svg"),
	}
	if len(got) != len(want) {
		t.Fatalf("got %d rels, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("rel[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestCopyFileIsAtomicAndSetsMode(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src")
	dst := filepath.Join(dir, "dst")
	if err := os.WriteFile(src, []byte("payload"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := CopyFile(src, dst, 0o644); err != nil {
		t.Fatalf("copy: %v", err)
	}
	fi, err := os.Stat(dst)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if fi.Mode().Perm() != 0o644 {
		t.Errorf("mode = %v, want 0644", fi.Mode().Perm())
	}
	// No temp files may be left behind on success.
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), ".installer-") {
			t.Errorf("temp file left behind: %s", e.Name())
		}
	}
}

func TestCopyFileMissingSource(t *testing.T) {
	dir := t.TempDir()
	if err := CopyFile(filepath.Join(dir, "absent"), filepath.Join(dir, "dst"), 0o644); err == nil {
		t.Fatal("expected error for missing source")
	}
}

func TestLayoutFor(t *testing.T) {
	s := testSpec()
	lay := s.LayoutFor("/opt/x")
	cases := map[string]string{
		lay.AppDir:  "/opt/x/share/test-app",
		lay.BinDir:  "/opt/x/bin",
		lay.AppsDir: "/opt/x/share/applications",
		lay.Theme:   "/opt/x/share/icons/hicolor",
	}
	for got, want := range cases {
		if got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	}
}

func TestDefaultPrefixUsesHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if got, want := DefaultPrefix(), filepath.Join(home, ".local"); got != want {
		t.Errorf("DefaultPrefix() = %q, want %q", got, want)
	}
}

func TestOnPath(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+"/usr/bin")
	if !OnPath(dir) {
		t.Errorf("OnPath(%q) = false, want true", dir)
	}
	if OnPath(filepath.Join(dir, "nope")) {
		t.Error("OnPath returned true for a directory not in PATH")
	}
}

// io_Discard is a local io.Writer sink; using it rather than io.Discard keeps
// the test output assertions explicit about what is being thrown away.
type io_Discard struct{}

func (io_Discard) Write(p []byte) (int, error) { return len(p), nil }
