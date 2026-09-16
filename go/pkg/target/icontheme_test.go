package target

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/davidwalter0/frameworks/go/pkg/plan"
	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

// These tests are ported from frameworks/go/pkg/installer (decision D-0005):
// the four ownership behaviours its installer_test.go established are the
// reason the icon-theme lifecycle is known to work, so they move WITH the
// code. The shape differs — frameworks installed imperatively, here a pure
// render emits guarded actions and Apply evaluates them — but each assertion
// is the same claim about the same host outcome.

// iconSpec returns a spec with icons, rooted at a real temp prefix so the
// rendered plan can actually be applied.
func iconSpec(t *testing.T) spec.Spec {
	t.Helper()
	s := fsSpec(t)
	s.Prefix = t.TempDir()
	s.DesktopEntry = "[Desktop Entry]\nName=Demo\n"
	s.IconName = "net.example.demo"
	s.Icons = map[string][]byte{
		"256x256":  []byte("PNG"),
		"scalable": []byte("<svg/>"),
	}
	return s
}

func mustApply(t *testing.T, p plan.Plan) []plan.Result {
	t.Helper()
	results, err := plan.Apply(p, plan.Options{})
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	return results
}

func install(t *testing.T, s spec.Spec) {
	t.Helper()
	p, err := Filesystem(s)
	if err != nil {
		t.Fatalf("Filesystem: %v", err)
	}
	mustApply(t, p)
}

func uninstall(t *testing.T, s spec.Spec) {
	t.Helper()
	p, err := FilesystemUninstall(s)
	if err != nil {
		t.Fatalf("FilesystemUninstall: %v", err)
	}
	mustApply(t, p)
}

func mustExist(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); err != nil {
		t.Errorf("%s should exist: %v", path, err)
	}
}

func mustNotExist(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); err == nil {
		t.Errorf("%s should not exist", path)
	}
}

// A fresh host gets an index.theme and the authorship marker; with no system
// index injected, the synthesized minimal one is written.
func TestIconThemeInstallWritesIndexAndMarker(t *testing.T) {
	s := iconSpec(t)
	install(t, s)

	theme := themeDir(s)
	mustExist(t, filepath.Join(theme, "index.theme"))
	mustExist(t, filepath.Join(theme, IconThemeMarker))

	b, err := os.ReadFile(filepath.Join(theme, "index.theme"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "Name=Hicolor") {
		t.Errorf("expected the synthesized fallback index, got:\n%s", b)
	}
}

// The COPY-SUCCESS path: when the host has a system hicolor index.theme, its
// content is installed — and the marker must be written on THIS path too.
// In frameworks the marker was originally written only on the fallback path,
// stranding index.theme forever on every real desktop; the injected
// SystemIndexTheme field makes the distinction testable without a global.
func TestIconThemeUsesSystemIndexContent(t *testing.T) {
	const sysBody = "[Icon Theme]\nName=SystemHicolorUnderTest\nDirectories=48x48/apps\n"
	s := iconSpec(t)
	s.SystemIndexTheme = []byte(sysBody)
	install(t, s)

	theme := themeDir(s)
	b, err := os.ReadFile(filepath.Join(theme, "index.theme"))
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != sysBody {
		t.Fatalf("copy-success path did not run: installed index.theme is not the system copy\ngot:\n%s", b)
	}
	// The marker is what authorizes removal; its absence was the defect.
	mustExist(t, filepath.Join(theme, IconThemeMarker))
}

// Uninstall must remove an index.theme it wrote itself.
func TestIconThemeUninstallRemovesOwn(t *testing.T) {
	s := iconSpec(t)
	install(t, s)
	uninstall(t, s)

	theme := themeDir(s)
	mustNotExist(t, filepath.Join(theme, "index.theme"))
	mustNotExist(t, filepath.Join(theme, IconThemeMarker))
}

// A pre-existing (system or other-app) index.theme must survive both install
// and uninstall — a shared prefix may host other applications' icons, and
// deleting a theme index we did not write would break all of them.
func TestIconThemeKeepsForeign(t *testing.T) {
	s := iconSpec(t)
	theme := themeDir(s)
	if err := os.MkdirAll(theme, 0o755); err != nil {
		t.Fatal(err)
	}
	foreign := filepath.Join(theme, "index.theme")
	const foreignBody = "[Icon Theme]\nName=Foreign\n"
	if err := os.WriteFile(foreign, []byte(foreignBody), 0o644); err != nil {
		t.Fatal(err)
	}

	install(t, s)
	mustNotExist(t, filepath.Join(theme, IconThemeMarker))
	uninstall(t, s)

	b, err := os.ReadFile(foreign)
	if err != nil {
		t.Fatalf("foreign index.theme was removed: %v", err)
	}
	if string(b) != foreignBody {
		t.Errorf("foreign index.theme was overwritten:\n%s", b)
	}
}

// Our index.theme must NOT be removed while another app's icons remain — and
// the MARKER must survive too, so a later uninstall (after the other app has
// gone) is still authorized to finish the job.
func TestIconThemeKeptWhileOtherIconsRemain(t *testing.T) {
	s := iconSpec(t)
	install(t, s)

	theme := themeDir(s)
	otherDir := filepath.Join(theme, "256x256", "apps")
	other := filepath.Join(otherDir, "com.example.otherApp.png")
	if err := os.WriteFile(other, []byte("PNG"), 0o644); err != nil {
		t.Fatal(err)
	}

	uninstall(t, s)
	mustExist(t, filepath.Join(theme, "index.theme"))
	mustExist(t, filepath.Join(theme, IconThemeMarker))
	mustExist(t, other)

	// The other app leaves; the retained marker is what makes this second
	// uninstall able to remove the index at all.
	if err := os.Remove(other); err != nil {
		t.Fatal(err)
	}
	uninstall(t, s)
	mustNotExist(t, filepath.Join(theme, "index.theme"))
	mustNotExist(t, filepath.Join(theme, IconThemeMarker))
}

// An install laid down by a PRE-MIGRATION installer wrote its own marker name
// (.ghk-wrote-index-theme, .frameworks-wrote-index-theme). Uninstall must
// honour those, or every migrated repo strands the index.theme of exactly the
// installs the migration is upgrading.
func TestIconThemeLegacyMarkerAuthorizesRemoval(t *testing.T) {
	const legacy = ".ghk-wrote-index-theme"
	s := iconSpec(t)
	s.LegacyIconThemeMarkers = []string{legacy}

	// Simulate the pre-migration install: icons + index.theme + old marker.
	theme := themeDir(s)
	if err := os.MkdirAll(theme, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"index.theme", legacy} {
		if err := os.WriteFile(filepath.Join(theme, f), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	uninstall(t, s)
	mustNotExist(t, filepath.Join(theme, "index.theme"))
	mustNotExist(t, filepath.Join(theme, legacy))
}

// Icons mirrored out of the payload (IconRels) must be removed BEFORE the
// guarded index removal, or the tree-check finds our own leftovers and keeps
// index.theme for a tenant that is already gone.
func TestIconThemeRemovedAfterIconRelsCleanup(t *testing.T) {
	s := fsSpec(t)
	s.Prefix = t.TempDir()
	s.IconName = "net.example.demo"
	s.IconRels = []string{filepath.Join("256x256", "apps", "net.example.demo.png")}
	s.Payload = tgz(t,
		member{name: "bin/demo", body: "#!/bin/sh\n", mode: 0o755},
		member{name: "icons/hicolor/256x256/apps/net.example.demo.png", body: "PNG"},
	)

	install(t, s)
	theme := themeDir(s)
	mustExist(t, filepath.Join(theme, "256x256", "apps", "net.example.demo.png"))
	mustExist(t, filepath.Join(theme, "index.theme"))

	uninstall(t, s)
	mustNotExist(t, filepath.Join(theme, "index.theme"))
	mustNotExist(t, filepath.Join(theme, IconThemeMarker))
}
