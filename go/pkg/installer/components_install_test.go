package installer

import (
	"archive/tar"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/davidwalter0/frameworks/go/pkg/receipt"
	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

// componentSpec declares one of each role plus a unit template, which is the
// shape mountbridge and cross-bridge both have: a daemon, a CLI a person types, a
// windowed app, and a helper the payload invokes but nobody types.
func componentSpec() Spec {
	return Spec{
		AppID:         "com.example.demo",
		DisplayName:   "demo",
		ShareSubdir:   "demo",
		DesktopSource: "demo.desktop",
		Components: []Component{
			{Name: "demod", Role: spec.RoleDaemon, Rel: "bin/demod", Args: []string{"--serve"}},
			{Name: "demo", Role: spec.RoleCLI, Rel: "bin/demo"},
			{Name: "demo-ui", Role: spec.RoleGUI, Rel: "demo-ui"},
			{Name: "helper", Role: spec.RoleHelper, Rel: "libexec/helper"},
		},
	}
}

// componentPayload ships a unit template carrying __EXEC__ — the shape real
// repos already use (netroute, ghk and waterworks all ship placeholdered
// units today) — and a desktop entry naming a component token directly.
func componentPayload(t *testing.T) []byte {
	t.Helper()
	return makeTarGz(t, []entry{
		{name: "bin/", typeflag: tar.TypeDir, mode: 0o755},
		{name: "bin/demod", body: "#!/bin/sh\necho daemon\n", mode: 0o755},
		{name: "bin/demo", body: "#!/bin/sh\necho cli\n", mode: 0o755},
		{name: "demo-ui", body: "#!/bin/sh\necho gui\n", mode: 0o755},
		{name: "libexec/", typeflag: tar.TypeDir, mode: 0o755},
		{name: "libexec/helper", body: "#!/bin/sh\necho helper\n", mode: 0o755},
		{name: "units/", typeflag: tar.TypeDir, mode: 0o755},
		{name: "units/demod.service", body: "" +
			"[Unit]\nDescription=demo daemon\n\n" +
			"[Service]\nExecStart=__EXEC__ --serve\nRestart=on-failure\n\n" +
			"[Install]\nWantedBy=default.target\n"},
		{name: "demo.desktop", body: "[Desktop Entry]\nExec=__EXEC_DEMO_UI__\nIcon=com.example.demo\n"},
		{name: "icons/hicolor/256x256/apps/com.example.demo.png", body: "PNGDATA"},
		{name: "icons/hicolor/scalable/apps/com.example.demo.svg", body: "<svg/>"},
	})
}

// componentEnv gives the install a private HOME so nothing is written to the
// developer's real ~/.config/systemd/user.
func componentEnv(t *testing.T) (Env, string) {
	t.Helper()
	home := t.TempDir()
	return spec.EnvForHome(home), home
}

func installComponents(t *testing.T) (Spec, Layout, string) {
	t.Helper()
	isolatedPrefix(t) // redirect the system index.theme away from /usr/share
	env, home := componentEnv(t)
	s := componentSpec()
	opt := Options{Env: env, Out: io.Discard}

	if err := Install(s, componentPayload(t), "v1.2.3", opt); err != nil {
		t.Fatalf("Install: %v", err)
	}
	lay, err := opt.layout(s)
	if err != nil {
		t.Fatalf("layout: %v", err)
	}
	return s, lay, home
}

// THE ACCEPTANCE TEST for the whole mechanism. The unit that lands on disk must
// name the path the installer actually wrote — not a path anyone typed, and not
// the binary that happened to run the install.
//
// mountbridge's five units named ~/go/bin while its installer wrote
// ~/.local/share/mountbridge/bin, so reinstalling never changed what ran and the
// daemon sat 19 commits stale. This is that failure, expressed as an assertion.
func TestGeneratedUnitNamesTheInstalledBinary(t *testing.T) {
	s, lay, home := installComponents(t)

	daemon := s.Components[0]
	unitPath := lay.UnitPathFor(daemon)
	mustExist(t, unitPath)

	b, err := os.ReadFile(unitPath)
	if err != nil {
		t.Fatalf("read unit: %v", err)
	}
	got := string(b)

	want := lay.PayloadPathFor(daemon)
	if !strings.Contains(got, "ExecStart="+want+" --serve") {
		t.Errorf("unit ExecStart does not name the installed binary.\nwant path: %s\nunit:\n%s", want, got)
	}
	// The binary the unit names must be the one on disk.
	mustExist(t, want)

	if strings.Contains(got, "__") {
		t.Errorf("unit still contains an unsubstituted placeholder:\n%s", got)
	}
	// The unit must be under the private HOME, never the real one.
	if !strings.HasPrefix(unitPath, home) {
		t.Fatalf("unit escaped the test HOME: %s", unitPath)
	}
	// The repo's own directives survive: generating unit text from scratch
	// would have dropped them, which is why substitution was chosen.
	for _, keep := range []string{"Restart=on-failure", "WantedBy=default.target"} {
		if !strings.Contains(got, keep) {
			t.Errorf("unit lost the repo's own directive %q", keep)
		}
	}
}

// Only a cli reaches PATH. A helper or daemon in BinDir is how eight
// cross-bridge binaries came to shadow each other across two directories.
func TestOnlyCLIComponentsReachBinDir(t *testing.T) {
	s, lay, _ := installComponents(t)

	mustExist(t, filepath.Join(lay.BinDir, "demo"))
	for _, name := range []string{"demod", "demo-ui", "helper"} {
		mustNotExist(t, filepath.Join(lay.BinDir, name))
	}

	// And it is a symlink INTO the app tree, not a copy: one file, so an
	// upgrade cannot leave two versions disagreeing.
	link, err := os.Readlink(lay.DestinationFor(s.Components[1]))
	if err != nil {
		t.Fatalf("bin entry is not a symlink: %v", err)
	}
	if link != lay.PayloadPathFor(s.Components[1]) {
		t.Errorf("symlink target = %q, want the payload path %q",
			link, lay.PayloadPathFor(s.Components[1]))
	}
}

// A desktop entry may name a component directly rather than rebuilding the path
// from __PREFIX__ plus a hardcoded subdirectory — which is the same "spell the
// destination twice" defect one layer down.
func TestDesktopEntryResolvesComponentToken(t *testing.T) {
	s, lay, _ := installComponents(t)

	b, err := os.ReadFile(filepath.Join(lay.AppsDir, s.DesktopTarget()))
	if err != nil {
		t.Fatalf("read desktop entry: %v", err)
	}
	got := string(b)
	want := lay.PayloadPathFor(s.Components[2]) // demo-ui
	if !strings.Contains(got, "Exec="+want) {
		t.Errorf("desktop Exec does not name the installed GUI.\nwant: %s\ngot:\n%s", want, got)
	}
	if strings.Contains(got, "__EXEC") {
		t.Errorf("desktop entry still contains a placeholder:\n%s", got)
	}
}

// The receipt must record the ABSOLUTE paths written, including the unit and
// the bin symlink — that is the half of the manifest/receipt split that has to
// be absolute, because an uninstall cannot act on a relative path.
func TestReceiptRecordsUnitsAndComponentLinks(t *testing.T) {
	s, lay, _ := installComponents(t)

	b, err := os.ReadFile(filepath.Join(lay.AppDir, RecordDir, ReceiptFile))
	if err != nil {
		t.Fatalf("read receipt: %v", err)
	}
	var r receipt.Receipt
	if err := json.Unmarshal(b, &r); err != nil {
		t.Fatalf("parse receipt: %v", err)
	}

	paths := make(map[string]receipt.File, len(r.Files))
	for _, f := range r.Files {
		paths[f.Path] = f
		if !filepath.IsAbs(f.Path) {
			t.Errorf("receipt path %q is not absolute", f.Path)
		}
	}
	if _, ok := paths[lay.UnitPathFor(s.Components[0])]; !ok {
		t.Errorf("receipt does not record the generated unit; uninstall cannot remove it")
	}
	link, ok := paths[lay.DestinationFor(s.Components[1])]
	if !ok {
		t.Fatalf("receipt does not record the cli symlink")
	}
	if link.Link != lay.PayloadPathFor(s.Components[1]) {
		t.Errorf("receipt symlink target = %q, want %q", link.Link, lay.PayloadPathFor(s.Components[1]))
	}
}

// Whatever Install created, Uninstall removes. A unit left behind keeps naming
// a binary that is gone; a bin entry left behind is a dangling symlink on PATH.
func TestUninstallRemovesComponentsAndUnits(t *testing.T) {
	isolatedPrefix(t)
	env, _ := componentEnv(t)
	s := componentSpec()
	opt := Options{Env: env, Out: io.Discard}

	if err := Install(s, componentPayload(t), "v1", opt); err != nil {
		t.Fatalf("Install: %v", err)
	}
	lay, err := opt.layout(s)
	if err != nil {
		t.Fatalf("layout: %v", err)
	}
	unit := lay.UnitPathFor(s.Components[0])
	cli := lay.DestinationFor(s.Components[1])
	mustExist(t, unit)
	mustExist(t, cli)

	if err := Uninstall(s, opt); err != nil {
		t.Fatalf("Uninstall: %v", err)
	}
	mustNotExist(t, unit)
	mustNotExist(t, cli)
	mustNotExist(t, lay.AppDir)
}

// A daemon whose unit template is missing must FAIL, not silently install
// without a service — an install that looks complete and started nothing is the
// class of failure this change exists to remove.
func TestMissingUnitTemplateIsAnError(t *testing.T) {
	isolatedPrefix(t)
	env, _ := componentEnv(t)
	s := componentSpec()

	payload := makeTarGz(t, []entry{
		{name: "bin/", typeflag: tar.TypeDir, mode: 0o755},
		{name: "bin/demod", body: "#!/bin/sh\n", mode: 0o755},
		{name: "bin/demo", body: "#!/bin/sh\n", mode: 0o755},
		{name: "demo-ui", body: "#!/bin/sh\n", mode: 0o755},
		{name: "libexec/helper", body: "#!/bin/sh\n", mode: 0o755},
		// units/ deliberately absent
	})
	err := Install(s, payload, "v1", Options{Env: env, Out: io.Discard})
	if err == nil {
		t.Fatal("want an error when a daemon's unit template is missing")
	}
	if !strings.Contains(err.Error(), "demod") {
		t.Errorf("error should name the offending component, got: %v", err)
	}
}
