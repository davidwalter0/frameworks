package installer

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/davidwalter0/frameworks/go/pkg/receipt"
	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

// RecordDir is where an install describes itself, under the app directory.
//
// Everything here is written BY the installer and read by nothing the payload
// ships, so it is namespaced with a leading dot and kept in one directory
// rather than scattered beside the application's own files.
const RecordDir = spec.InstalledManifestDir

// Record filenames within [RecordDir].
const (
	ManifestFile = "manifest.yaml"
	ReceiptFile  = "receipt.json"
)

// writeRecord makes the installed tree self-describing: it stores the manifest
// that drove this install and a receipt of what the install created.
//
// WHY THE MANIFEST IS WRITTEN VERBATIM, not re-marshalled from the Spec.
// Re-marshalling would produce a document that is EQUIVALENT to the one the
// author wrote and not IDENTICAL to it — comments gone, key order normalised,
// every defaulted field now spelled out. The comments are the part that
// carries the reasoning ("this is why libgtk-3-0 is declared for deb and
// bundled for AppImage"), and an install record whose whole purpose is to be
// read later should not be the one copy with the reasoning stripped. So the
// bytes the consumer embedded are the bytes that land.
//
// A consumer that has no manifest (a Spec still written as a Go literal)
// passes nil and gets a receipt only. That is deliberate: the record degrades
// rather than blocking the install, because a missing manifest is a migration
// state, not a failure.
func writeRecord(s Spec, lay Layout, version string, manifest []byte) error {
	dir := filepath.Join(lay.AppDir, RecordDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}

	if len(manifest) > 0 {
		if err := os.WriteFile(filepath.Join(dir, ManifestFile), manifest, 0o644); err != nil {
			return fmt.Errorf("write installed manifest: %w", err)
		}
	}

	r := receipt.Receipt{
		Schema:      1,
		App:         s.App,
		Version:     version,
		Target:      "filesystem",
		InstalledAt: time.Now().UTC(),
		Files:       installedFiles(s, lay),
	}
	if err := receipt.Save(filepath.Join(dir, ReceiptFile), r); err != nil {
		return fmt.Errorf("write install receipt: %w", err)
	}
	return nil
}

// installedFiles records what Install created OUTSIDE the app directory, plus
// the app directory itself.
//
// It deliberately does NOT enumerate the extracted payload. Uninstall removes
// the app directory wholesale, so listing several thousand bundle files would
// add weight to the record without adding a decision anyone makes from it. The
// entries that ARE listed are exactly the ones that live elsewhere in the
// prefix and would otherwise be orphaned — the case receipt.Orphans exists
// for.
func installedFiles(s Spec, lay Layout) []receipt.File {
	out := []receipt.File{{Path: lay.AppDir, Kind: "mkdir"}}
	for _, l := range s.Launchers {
		out = append(out, receipt.File{
			Path: filepath.Join(lay.BinDir, l.Name),
			Kind: "symlink",
			Link: filepath.Join(lay.AppDir, l.Target),
		})
	}
	// Component symlinks and generated units, recorded with the ABSOLUTE paths
	// the install actually wrote. This is the half of the manifest/receipt split
	// that must be absolute: the manifest declares roles and relative payload
	// paths so it stays portable, while the receipt describes one machine and
	// could not drive an uninstall otherwise — you cannot remove a relative
	// path.
	for _, c := range s.Components {
		if c.Role.OnPath() {
			out = append(out, receipt.File{
				Path: lay.DestinationFor(c),
				Kind: "symlink",
				Link: lay.PayloadPathFor(c),
			})
		}
		if c.HasUnit() && lay.UnitDir != "" {
			out = append(out, receipt.File{Path: lay.UnitPathFor(c), Kind: "write"})
		}
	}
	if s.DesktopSource != "" || s.DesktopEntry != "" {
		out = append(out, receipt.File{
			Path: filepath.Join(lay.AppsDir, s.DesktopTarget()),
			Kind: "write",
		})
	}
	for _, rel := range s.IconRelsOrDefault() {
		out = append(out, receipt.File{Path: filepath.Join(lay.Theme, rel), Kind: "write"})
	}
	return out
}

// InstalledManifest reads back the manifest an install recorded under prefix.
//
// This is the point of writing it: a later tool — a dependency check against
// the host, a packager, an upgrade — can ask an INSTALLED application what it
// is and what it needs, without the installer binary that produced it and
// without the source repo.
func InstalledManifest(s Spec, prefix string) (spec.Manifest, error) {
	lay := s.LayoutFor(prefix)
	return spec.LoadFile(filepath.Join(lay.AppDir, RecordDir, ManifestFile))
}

// InstalledReceipt reads back the receipt an install recorded under prefix.
func InstalledReceipt(s Spec, prefix string) (receipt.Receipt, error) {
	lay := s.LayoutFor(prefix)
	return receipt.Load(filepath.Join(lay.AppDir, RecordDir, ReceiptFile))
}
