package target

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"strings"
	"testing"

	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

type member struct {
	name string
	body string
	mode int64
	typ  byte
	link string
}

func tgz(t *testing.T, members ...member) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	tw := tar.NewWriter(zw)
	for _, m := range members {
		typ := m.typ
		if typ == 0 {
			typ = tar.TypeReg
		}
		mode := m.mode
		if mode == 0 {
			mode = 0o644
		}
		h := &tar.Header{Name: m.name, Mode: mode, Typeflag: typ, Linkname: m.link}
		if typ == tar.TypeReg {
			h.Size = int64(len(m.body))
		}
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if typ == tar.TypeReg {
			if _, err := tw.Write([]byte(m.body)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func fsSpec(t *testing.T) spec.Spec {
	return spec.Spec{
		App:    "demo",
		Prefix: "/opt/p",
		Payload: tgz(t,
			member{name: "bin/", typ: tar.TypeDir},
			member{name: "bin/demo", body: "#!/bin/sh\n", mode: 0o755},
			member{name: "share/data.txt", body: "hello\n"},
		),
		Binaries: []spec.Binary{{Name: "demo", Rel: "bin/demo"}},
	}
}

func TestFilesystemExtractsPayloadAndLinks(t *testing.T) {
	p, err := Filesystem(fsSpec(t))
	if err != nil {
		t.Fatalf("Filesystem: %v", err)
	}
	for _, want := range []string{
		"/opt/p/share/demo/bin/demo",
		"/opt/p/share/demo/share/data.txt",
		"/opt/p/bin/demo",
	} {
		if !hasPath(p.Paths(), want) {
			t.Errorf("missing %s in %v", want, p.Paths())
		}
	}

	var mode uint32
	for _, a := range p.Actions {
		if a.Path == "/opt/p/share/demo/bin/demo" {
			mode = uint32(a.Mode.Perm())
		}
		if a.Kind == "symlink" && a.Path == "/opt/p/bin/demo" {
			if a.LinkTarget != "/opt/p/share/demo/bin/demo" {
				t.Errorf("symlink target = %s", a.LinkTarget)
			}
		}
	}
	if mode != 0o755 {
		t.Errorf("executable bit lost: mode = %o", mode)
	}
}

// The previous tree is dropped, not merged into: a file a new version deleted
// must not survive as a stale leftover that still resolves on PATH.
func TestFilesystemRemovesPreviousTreeFirst(t *testing.T) {
	p, err := Filesystem(fsSpec(t))
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Actions) == 0 || p.Actions[0].Kind != "remove" {
		t.Fatalf("first action should drop the old tree, got %+v", p.Actions[0])
	}
	if p.Actions[0].Path != "/opt/p/share/demo" {
		t.Errorf("removing %s", p.Actions[0].Path)
	}
}

// The payload is our own build, but "our own" is a property of the build, not
// of the bytes in hand at extraction time.
func TestFilesystemRejectsPathTraversal(t *testing.T) {
	for _, name := range []string{"../escape", "a/../../escape", "/../escape"} {
		t.Run(name, func(t *testing.T) {
			s := fsSpec(t)
			s.Payload = tgz(t, member{name: name, body: "x"})
			_, err := Filesystem(s)
			if err == nil {
				t.Fatalf("member %q should be rejected", name)
			}
			if !strings.Contains(err.Error(), "escapes the install directory") {
				t.Errorf("got: %v", err)
			}
		})
	}
}

func TestFilesystemRejectsUnsupportedMemberTypes(t *testing.T) {
	s := fsSpec(t)
	s.Payload = tgz(t, member{name: "pipe", typ: tar.TypeFifo})
	_, err := Filesystem(s)
	if err == nil || !strings.Contains(err.Error(), "unsupported type") {
		t.Fatalf("a fifo member should be refused loudly; got %v", err)
	}
}

// word-bank's AppDir payloads carry AppRun-style symlinks; the extracted tree
// must keep them, and keep them RELATIVE so the tree survives a prefix move.
func TestFilesystemPreservesPayloadSymlinks(t *testing.T) {
	s := fsSpec(t)
	s.Payload = tgz(t,
		member{name: "usr/bin/app", body: "#!/bin/sh\n", mode: 0o755},
		member{name: "AppRun", typ: tar.TypeSymlink, link: "usr/bin/app"},
	)
	s.Binaries = []spec.Binary{{Name: "app", Rel: "AppRun"}}

	p, err := Filesystem(s)
	if err != nil {
		t.Fatalf("Filesystem: %v", err)
	}
	found := false
	for _, a := range p.Actions {
		if a.Kind == "symlink" && a.Path == "/opt/p/share/demo/AppRun" {
			found = true
			if a.LinkTarget != "usr/bin/app" {
				t.Errorf("link target rewritten to %q; must stay relative as authored", a.LinkTarget)
			}
		}
	}
	if !found {
		t.Errorf("payload symlink not planned; paths: %v", p.Paths())
	}
}

func TestFilesystemRejectsEscapingSymlinkTargets(t *testing.T) {
	for name, m := range map[string]member{
		"absolute": {name: "evil", typ: tar.TypeSymlink, link: "/etc/passwd"},
		"relative": {name: "sub/evil", typ: tar.TypeSymlink, link: "../../../etc/passwd"},
	} {
		t.Run(name, func(t *testing.T) {
			s := fsSpec(t)
			s.Payload = tgz(t, m)
			if _, err := Filesystem(s); err == nil ||
				!strings.Contains(err.Error(), "escapes the install directory") {
				t.Fatalf("link %q -> %q should be rejected; got %v", m.name, m.link, err)
			}
		})
	}
}

func TestFilesystemNoPayloadIsUnavailable(t *testing.T) {
	_, err := Filesystem(spec.Spec{App: "demo", Prefix: "/opt/p"})
	if err == nil || !strings.Contains(err.Error(), "target unavailable") {
		t.Fatalf("got %v", err)
	}
	if !strings.Contains(err.Error(), "dist-installer") {
		t.Error("the error should name how to build a payload")
	}
}

func TestFilesystemNoPrefixIsAnError(t *testing.T) {
	s := fsSpec(t)
	s.Prefix = ""
	if _, err := Filesystem(s); err == nil {
		t.Fatal("expected an error with no prefix")
	}
}

func TestFilesystemDesktopEntryAndIcons(t *testing.T) {
	s := fsSpec(t)
	s.DesktopEntry = "[Desktop Entry]\nName=Demo\n"
	s.IconName = "net.example.demo"
	s.Icons = map[string][]byte{"64x64": []byte("png"), "scalable": []byte("<svg/>")}

	p, err := Filesystem(s)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"/opt/p/share/applications/demo.desktop",
		"/opt/p/share/icons/hicolor/64x64/apps/net.example.demo.png",
		"/opt/p/share/icons/hicolor/scalable/apps/net.example.demo.svg",
	} {
		if !hasPath(p.Paths(), want) {
			t.Errorf("missing %s in %v", want, p.Paths())
		}
	}
	// The icon resolves BY NAME from the installed theme, so the cache
	// refresh has to be offered or a regenerated icon appears not to change.
	if len(p.Instructions) == 0 || !strings.Contains(strings.Join(p.Instructions, "\n"), "icon-cache") {
		t.Errorf("icons installed but no cache refresh offered: %v", p.Instructions)
	}
}

func TestFilesystemNotesMissingPathEntry(t *testing.T) {
	s := fsSpec(t)
	s.PathEnv = "/usr/bin:/bin"
	p, err := Filesystem(s)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Notes) == 0 || !strings.Contains(p.Notes[0], "not on your PATH") {
		t.Errorf("should note the bin dir is unreachable, got %v", p.Notes)
	}

	s.PathEnv = "/opt/p/bin:/usr/bin"
	p, err = Filesystem(s)
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range p.Notes {
		if strings.Contains(n, "not on your PATH") {
			t.Errorf("bin dir IS on PATH; should not warn: %v", p.Notes)
		}
	}
}

// On Wayland the window icon resolves from the .desktop file whose FILENAME
// equals the app-id; any other name silently loses it (Spec.AppID).
func TestFilesystemDesktopNaming(t *testing.T) {
	s := fsSpec(t)
	s.DesktopEntry = "[Desktop Entry]\n"

	s.AppID = "com.example.Demo"
	p, err := Filesystem(s)
	if err != nil {
		t.Fatal(err)
	}
	if !hasPath(p.Paths(), "/opt/p/share/applications/com.example.Demo.desktop") {
		t.Errorf("AppID should name the entry; got %v", p.Paths())
	}

	s.DesktopName = "legacy.desktop"
	if p, err = Filesystem(s); err != nil {
		t.Fatal(err)
	}
	if !hasPath(p.Paths(), "/opt/p/share/applications/legacy.desktop") {
		t.Errorf("DesktopName should override AppID; got %v", p.Paths())
	}

	u, err := FilesystemUninstall(s)
	if err != nil {
		t.Fatal(err)
	}
	if !hasPath(u.Paths(), "/opt/p/share/applications/legacy.desktop") {
		t.Errorf("uninstall must remove the same name install wrote; got %v", u.Paths())
	}
}

// The template ships INSIDE the payload; render resolves it from the archive
// bytes — no host read — and substitutes __PREFIX__ plus the Spec's tokens.
func TestFilesystemDesktopFromPayloadTemplate(t *testing.T) {
	s := fsSpec(t)
	s.AppID = "com.example.Demo"
	s.Tokens = map[string]string{"EXEC": "demo-ui"}
	s.DesktopSource = "share/demo.desktop"
	s.Payload = tgz(t,
		member{name: "bin/demo", body: "x", mode: 0o755},
		member{name: "share/demo.desktop",
			body: "[Desktop Entry]\nExec=__PREFIX__/bin/__EXEC__\nKeep=__UNKNOWN__\n"},
	)

	p, err := Filesystem(s)
	if err != nil {
		t.Fatal(err)
	}
	var got string
	for _, a := range p.Actions {
		if a.Path == "/opt/p/share/applications/com.example.Demo.desktop" {
			got = string(a.Content)
		}
	}
	if !strings.Contains(got, "Exec=/opt/p/bin/demo-ui") {
		t.Errorf("tokens not substituted:\n%s", got)
	}
	if !strings.Contains(got, "Keep=__UNKNOWN__") {
		t.Errorf("an unknown token in app-authored text must be left alone:\n%s", got)
	}

	// A payload without the template is a CLI-only install, not an error.
	s.Payload = tgz(t, member{name: "bin/demo", body: "x", mode: 0o755})
	p, err = Filesystem(s)
	if err != nil {
		t.Fatalf("absent template must not fail the install: %v", err)
	}
	if hasPath(p.Paths(), "/opt/p/share/applications/com.example.Demo.desktop") {
		t.Error("no template, yet a desktop entry was planned")
	}
	if len(p.Notes) == 0 || !strings.Contains(strings.Join(p.Notes, "\n"), "share/demo.desktop") {
		t.Errorf("the skipped entry should be noted, not silent: %v", p.Notes)
	}
}

// IconRels mirror icons out of the payload tree into the prefix theme — the
// path is relative to both, so one list describes source and destination.
func TestFilesystemIconRelsMirrorPayloadIcons(t *testing.T) {
	rel := "256x256/apps/com.example.Demo.png"
	s := fsSpec(t)
	s.IconRels = []string{rel, "scalable/apps/com.example.Demo.svg"}
	s.Payload = tgz(t,
		member{name: "bin/demo", body: "x", mode: 0o755},
		member{name: "icons/hicolor/" + rel, body: "png-bytes"},
	)

	p, err := Filesystem(s)
	if err != nil {
		t.Fatal(err)
	}
	want := "/opt/p/share/icons/hicolor/" + rel
	var got string
	for _, a := range p.Actions {
		if a.Path == want {
			got = string(a.Content)
		}
	}
	if got != "png-bytes" {
		t.Errorf("icon not mirrored from payload; content %q", got)
	}
	// The absent SVG degrades to the generic icon, with a note, not a failure.
	if len(p.Notes) == 0 || !strings.Contains(strings.Join(p.Notes, "\n"), "scalable/apps") {
		t.Errorf("missing icon member should be noted: %v", p.Notes)
	}
	if len(p.Instructions) == 0 || !strings.Contains(strings.Join(p.Instructions, "\n"), "icon-cache") {
		t.Errorf("payload icons installed but no cache refresh offered: %v", p.Instructions)
	}

	u, err := FilesystemUninstall(s)
	if err != nil {
		t.Fatal(err)
	}
	if !hasPath(u.Paths(), want) {
		t.Errorf("uninstall misses the mirrored icon; got %v", u.Paths())
	}
}

func TestFilesystemUninstallRemovesWhatInstallWrote(t *testing.T) {
	s := fsSpec(t)
	s.DesktopEntry = "[Desktop Entry]\n"
	s.IconName = "net.example.demo"
	s.Icons = map[string][]byte{"64x64": []byte("png")}

	p, err := FilesystemUninstall(s)
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range p.Actions {
		if a.Kind != "remove" {
			t.Errorf("uninstall should only remove, got %s %s", a.Kind, a.Path)
		}
	}
	for _, want := range []string{
		"/opt/p/share/demo",
		"/opt/p/bin/demo",
		"/opt/p/share/applications/demo.desktop",
		"/opt/p/share/icons/hicolor/64x64/apps/net.example.demo.png",
	} {
		if !hasPath(p.Paths(), want) {
			t.Errorf("uninstall misses %s (installed by Filesystem); got %v", want, p.Paths())
		}
	}
}
