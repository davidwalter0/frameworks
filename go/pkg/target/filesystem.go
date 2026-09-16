package target

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"path"
	"path/filepath"
	"slices"
	"sort"
	"strings"

	"github.com/davidwalter0/frameworks/go/pkg/plan"
	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

// maxPayloadFile bounds one extracted member. A self-extracting installer
// unpacks an archive it carries, but the archive is still untrusted input at
// the moment it is read, and an unbounded copy is how a corrupt payload turns
// into an OOM instead of an error.
const maxPayloadFile = 1 << 30 // 1 GiB

// IconThemeMarker records that THIS installer authored the hicolor theme's
// index.theme, as opposed to it having been present already. Uninstall removes
// an index.theme only when a marker says we created it — a shared prefix may
// hold other applications' icons, and deleting a system-provided theme index
// would break all of them. (Ported from frameworks/go/pkg/installer, per
// decision D-0005; gatehub-kit's bespoke installer carried the same idea as
// .ghk-wrote-index-theme — list those older names in
// Spec.LegacyIconThemeMarkers so pre-migration installs still clean up.)
const IconThemeMarker = ".installkit-wrote-index-theme"

// minimalIndexTheme is written when the host has no system hicolor
// index.theme to copy — just enough for gtk-update-icon-cache to accept the
// directory as a theme.
const minimalIndexTheme = `[Icon Theme]
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

// Filesystem renders the classic install: extract the payload under
// <prefix>/share/<app>, symlink executables onto PATH, and write the desktop
// entry and icons.
//
// This is the behaviour the seven forked installers already share — eleven
// byte-identical functions between them — expressed once, as a plan.
func Filesystem(s spec.Spec) (plan.Plan, error) {
	p := plan.Plan{Target: "filesystem"}

	if len(s.Payload) == 0 {
		return p, fmt.Errorf("target unavailable: this build embeds no payload " +
			"(build it with the packaging target, e.g. `make dist-installer`)")
	}
	if s.Prefix == "" {
		return p, fmt.Errorf("no install prefix: set Spec.Prefix or pass --prefix")
	}

	app := filepath.Join(s.Prefix, "share", s.App)
	binDir := filepath.Join(s.Prefix, "bin")

	// Replace the previous payload rather than merging into it: a file that
	// a new version deleted must not survive as a stale leftover.
	p.Remove(app, "drop any previous payload tree")
	p.Mkdir(app, "application directory")
	p.Mkdir(binDir, "PATH directory")

	files, err := extractTarGz(s.Payload)
	if err != nil {
		return p, fmt.Errorf("extract payload: %w", err)
	}
	for _, f := range files {
		dst := filepath.Join(app, f.name)
		switch {
		case f.dir:
			p.Mkdir(dst, "")
		case f.link != "":
			p.Symlink(dst, f.link, "")
		default:
			p.Write(dst, f.body, f.mode, "")
		}
	}

	for _, b := range s.Binaries {
		p.Symlink(filepath.Join(binDir, b.Name), filepath.Join(app, b.Rel),
			"put "+b.Name+" on PATH")
	}

	desktop := s.DesktopEntry
	if desktop == "" && s.DesktopSource != "" {
		if m, ok := findMember(files, s.DesktopSource); ok {
			desktop = string(m.body)
		} else {
			p.Note("payload has no %s; no desktop entry installed (the correct outcome for a CLI-only payload).", s.DesktopSource)
		}
	}
	if desktop != "" {
		appsDir := filepath.Join(s.Prefix, "share", "applications")
		p.Mkdir(appsDir, "desktop entry directory")
		// The filename is load-bearing on Wayland — see Spec.AppID.
		p.Write(filepath.Join(appsDir, s.DesktopFileName()),
			[]byte(substituteTokens(desktop, s)), 0o644, "desktop entry")
	}
	for _, size := range sortedKeys(s.Icons) {
		// hicolor is the theme every desktop searches; the icon resolves BY
		// NAME from the installed theme, never from the repo, so installing
		// it here is what makes the name resolvable at all.
		var rel string
		if size == "scalable" {
			rel = filepath.Join("icons", "hicolor", "scalable", "apps", s.IconName+".svg")
		} else {
			rel = filepath.Join("icons", "hicolor", size, "apps", s.IconName+".png")
		}
		p.Write(filepath.Join(s.Prefix, "share", rel), s.Icons[size], 0o644, "icon "+size)
	}
	for _, rel := range s.IconRels {
		m, ok := findMember(files, path.Join("icons", "hicolor", filepath.ToSlash(rel)))
		if !ok {
			p.Note("payload has no icons/hicolor/%s; that icon degrades to the generic one.", rel)
			continue
		}
		p.Write(filepath.Join(s.Prefix, "share", "icons", "hicolor", rel), m.body, 0o644,
			"icon "+rel+" (mirrored out of the payload)")
	}

	if s.PathEnv != "" && !onPath(binDir, s.PathEnv) {
		p.Note("%s is not on your PATH; add it to use the installed commands by name.", binDir)
	}
	if len(s.Icons) > 0 || len(s.IconRels) > 0 {
		theme := themeDir(s)
		index := filepath.Join(theme, "index.theme")
		content := s.SystemIndexTheme
		if len(content) == 0 {
			content = []byte(minimalIndexTheme)
		}
		// Without an index.theme, gtk-update-icon-cache refuses to run ("No
		// theme index file") and a stale icon-theme.cache from a prior run
		// masks the new icons entirely — the icon looks unchanged and the
		// cause is invisible. Both writes are guarded on the SAME condition,
		// index.theme's absence, because a pre-existing index belongs to the
		// system or another app and must survive us. Order is load-bearing:
		// the marker goes first, while the guard path still does not exist —
		// writing the index first would turn the marker's own guard false.
		p.Add(plan.Action{Kind: plan.KindWrite, Path: filepath.Join(theme, IconThemeMarker),
			Mode: 0o644, Guard: &plan.Guard{IfAbsent: index},
			Note: "authorship marker: uninstall may remove index.theme only because we wrote it"})
		p.Add(plan.Action{Kind: plan.KindWrite, Path: index, Content: content,
			Mode: 0o644, Guard: &plan.Guard{IfAbsent: index},
			Note: "theme index so gtk-update-icon-cache accepts the directory"})
		p.Instruct("gtk-update-icon-cache -f -t " + theme +
			"   # a running app keeps its old icon until restarted")
	}
	return p, nil
}

// FilesystemUninstall removes what Filesystem installed.
func FilesystemUninstall(s spec.Spec) (plan.Plan, error) {
	p := plan.Plan{Target: "filesystem"}
	if s.Prefix == "" {
		return p, fmt.Errorf("no install prefix: set Spec.Prefix or pass --prefix")
	}
	app := filepath.Join(s.Prefix, "share", s.App)
	p.Remove(app, "application directory")
	for _, b := range s.Binaries {
		p.Remove(filepath.Join(s.Prefix, "bin", b.Name), "PATH symlink")
	}
	if s.DesktopEntry != "" || s.DesktopSource != "" {
		p.Remove(filepath.Join(s.Prefix, "share", "applications", s.DesktopFileName()), "desktop entry")
	}
	for _, size := range sortedKeys(s.Icons) {
		ext, dir := ".png", size
		if size == "scalable" {
			ext = ".svg"
		}
		p.Remove(filepath.Join(themeDir(s), dir, "apps", s.IconName+ext), "icon")
	}
	for _, rel := range s.IconRels {
		p.Remove(filepath.Join(s.Prefix, "share", "icons", "hicolor", rel), "icon")
	}
	if len(s.Icons) > 0 || len(s.IconRels) > 0 {
		theme := themeDir(s)
		index := filepath.Join(theme, "index.theme")
		icons := &plan.TreeCheck{Dir: theme, Exts: []string{".png", ".svg"}}
		// index.theme goes only if (a) an authorship marker proves an
		// installer of this family wrote it and (b) no other application's
		// icons remain under the theme — EVERY icon removal above must come
		// first, or the walk finds our own leftovers and keeps the index for
		// a tenant that is already gone. When icons remain, BOTH files stay:
		// the marker must survive so a LATER uninstall, after the other app
		// has gone, is still authorized. Legacy markers ride the same guard
		// shape so an install laid down by a pre-migration installer still
		// cleans up after itself.
		for _, marker := range append([]string{IconThemeMarker}, s.LegacyIconThemeMarkers...) {
			m := filepath.Join(theme, marker)
			p.Add(plan.Action{Kind: plan.KindRemove, Path: index,
				Guard: &plan.Guard{IfPresent: m, IfNoTreeFiles: icons},
				Note:  "theme index (authored by " + marker + ")"})
			p.Add(plan.Action{Kind: plan.KindRemove, Path: m,
				Guard: &plan.Guard{IfPresent: m, IfNoTreeFiles: icons},
				Note:  "authorship marker"})
		}
	}
	return p, nil
}

// themeDir is the hicolor theme root under the prefix.
func themeDir(s spec.Spec) string {
	return filepath.Join(s.Prefix, "share", "icons", "hicolor")
}

type payloadFile struct {
	name string
	body []byte
	mode fs.FileMode
	dir  bool
	// link is a symlink member's target, kept RELATIVE as authored so the
	// extracted tree stays relocatable (word-bank's AppDir payloads carry
	// AppRun-style links that must survive a prefix move).
	link string
}

func extractTarGz(blob []byte) ([]payloadFile, error) {
	zr, err := gzip.NewReader(bytes.NewReader(blob))
	if err != nil {
		return nil, err
	}
	defer func() { _ = zr.Close() }()

	var out []payloadFile
	tr := tar.NewReader(zr)
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		name, err := safeName(h.Name)
		if err != nil {
			return nil, err
		}
		if name == "" {
			continue
		}
		switch h.Typeflag {
		case tar.TypeDir:
			out = append(out, payloadFile{name: name, dir: true})
		case tar.TypeReg:
			body, err := io.ReadAll(io.LimitReader(tr, maxPayloadFile))
			if err != nil {
				return nil, err
			}
			out = append(out, payloadFile{name: name, body: body, mode: fs.FileMode(h.Mode).Perm()})
		case tar.TypeSymlink:
			if err := safeLinkTarget(name, h.Linkname); err != nil {
				return nil, err
			}
			out = append(out, payloadFile{name: name, link: h.Linkname})
		default:
			// Devices, fifos and hardlinks inside a payload are not part of
			// the format these installers produce; refusing them loudly beats
			// materialising something unexpected.
			return nil, fmt.Errorf("payload member %q has unsupported type %q", h.Name, h.Typeflag)
		}
	}
	return out, nil
}

// safeName rejects path traversal. The payload is our own, but "our own" is a
// property of the build, not of the bytes in hand at extraction time.
//
// The obvious implementation — Clean("/" + name) then strip the slash — is
// WRONG in a way that looks right: rooting the path makes Clean ABSORB the
// traversal ("/../escape" becomes "/escape"), so the check that follows can
// never fire and a member lands somewhere the archive did not name, silently.
// Cleaning the RELATIVE path preserves a leading "..", which is what makes
// the refusal reachable at all.
//
// Tar member names are always slash-separated regardless of host, so this uses
// path, not path/filepath.
func safeName(name string) (string, error) {
	n := strings.ReplaceAll(name, `\`, "/")
	if strings.HasPrefix(n, "/") {
		return "", fmt.Errorf("payload member %q is absolute and escapes the install directory", name)
	}
	clean := path.Clean(n)
	if clean == "." || clean == "" {
		return "", nil
	}
	if clean == ".." || strings.HasPrefix(clean, "../") {
		return "", fmt.Errorf("payload member %q escapes the install directory", name)
	}
	return clean, nil
}

// findMember locates a non-directory payload member by its clean
// slash-separated path.
func findMember(files []payloadFile, name string) (payloadFile, bool) {
	want := path.Clean(strings.ReplaceAll(name, `\`, "/"))
	for _, f := range files {
		if f.name == want && !f.dir {
			return f, true
		}
	}
	return payloadFile{}, false
}

// substituteTokens resolves __PREFIX__ and the Spec's Tokens in desktop-entry
// content. Unlike unit rendering, an unresolved __X__ here is left alone
// rather than failing: a desktop template is app-authored text that may
// legitimately contain double underscores, where a unit is this module's own
// format with a closed token set.
func substituteTokens(content string, s spec.Spec) string {
	content = strings.ReplaceAll(content, "__PREFIX__", s.Prefix)
	for k, v := range s.Tokens {
		content = strings.ReplaceAll(content, "__"+k+"__", v)
	}
	return content
}

// safeLinkTarget rejects a payload symlink whose target escapes the extracted
// tree. The link's own PATH is already constrained by safeName; its TARGET is
// not, and a link pointing outside the tree is how a later write follows a
// payload out of the prefix. Absolute targets are refused outright; relative
// ones are resolved against the link's own directory.
func safeLinkTarget(name, linkname string) error {
	if linkname == "" {
		return fmt.Errorf("payload symlink %q has an empty target", name)
	}
	l := strings.ReplaceAll(linkname, `\`, "/")
	if strings.HasPrefix(l, "/") {
		return fmt.Errorf("payload symlink %q has absolute target %q, which escapes the install directory", name, linkname)
	}
	resolved := path.Clean(path.Join(path.Dir(name), l))
	if resolved == ".." || strings.HasPrefix(resolved, "../") {
		return fmt.Errorf("payload symlink %q target %q escapes the install directory", name, linkname)
	}
	return nil
}

// onPath reports whether dir appears in a PATH-style list. The list is passed
// in rather than read from the environment so rendering stays pure.
func onPath(dir, pathEnv string) bool {
	return slices.Contains(filepath.SplitList(pathEnv), dir)
}

func sortedKeys(m map[string][]byte) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
