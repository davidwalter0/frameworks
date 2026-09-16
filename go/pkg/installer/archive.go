package installer

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// ExtractTarGz unpacks a gzip-compressed tar in data into dst, preserving file
// modes so launchers and bundled binaries stay executable.
//
// It rejects any entry whose resolved path would escape dst (the zip-slip /
// path-traversal guard). The payload is our own embedded data, so this is
// defence in depth rather than a live threat — but an installer runs against a
// user's home directory, which is exactly where a traversal bug is worst.
func ExtractTarGz(data []byte, dst string) error {
	gz, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return err
	}
	defer func() { _ = gz.Close() }()

	tr := tar.NewReader(gz)
	dstClean := filepath.Clean(dst)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		target := filepath.Join(dst, hdr.Name)
		if target != dstClean && !strings.HasPrefix(target, dstClean+string(os.PathSeparator)) {
			return fmt.Errorf("unsafe path in archive: %q", hdr.Name)
		}
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, os.FileMode(hdr.Mode)|0o700); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := writeRegular(tr, target, os.FileMode(hdr.Mode), hdr.Size); err != nil {
				return err
			}
		case tar.TypeSymlink:
			// A symlink's TARGET is not constrained by the check above — only
			// the link's own location is. Reject links that point outside the
			// destination tree, so an archive cannot plant a link that a later
			// write follows out of the prefix.
			if err := checkLinkTarget(dstClean, target, hdr.Linkname); err != nil {
				return err
			}
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			if err := ForceSymlink(hdr.Linkname, target); err != nil {
				return err
			}
		default:
			// Other entry types (char/block/fifo/hardlink) are not expected in
			// a payload; skip rather than fail the whole install.
		}
	}
	return nil
}

// checkLinkTarget rejects a symlink whose resolved target escapes root.
// Absolute link targets are refused outright; relative ones are resolved
// against the link's own directory.
func checkLinkTarget(root, linkPath, linkname string) error {
	if filepath.IsAbs(linkname) {
		return fmt.Errorf("unsafe absolute symlink target in archive: %q -> %q", linkPath, linkname)
	}
	resolved := filepath.Clean(filepath.Join(filepath.Dir(linkPath), linkname))
	if resolved != root && !strings.HasPrefix(resolved, root+string(os.PathSeparator)) {
		return fmt.Errorf("unsafe symlink target in archive: %q -> %q", linkPath, linkname)
	}
	return nil
}

func writeRegular(r io.Reader, target string, mode os.FileMode, size int64) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	// CopyN bounded by the header size avoids an unbounded decompression copy
	// (a decompression bomb writes until the disk fills; the header tells us
	// how much to expect, so bounding it is cheap insurance).
	if _, err := io.CopyN(f, r, size); err != nil && err != io.EOF {
		_ = f.Close()
		return err
	}
	return f.Close()
}

// ForceSymlink creates newname -> oldname, replacing any existing entry.
// Re-running an installer over a previous install is the normal case, so a
// pre-existing link is expected rather than exceptional.
func ForceSymlink(oldname, newname string) error {
	_ = os.Remove(newname)
	return os.Symlink(oldname, newname)
}

// CopyFile copies the regular file at src to dst atomically: it writes a temp
// file in dst's own directory, chmods it to mode (unmasked by umask), then
// renames it over dst.
//
// The atomicity matters for icon installs: a torn icon file is picked up by
// gtk-update-icon-cache and then cached in that state.
func CopyFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()

	tmp, err := os.CreateTemp(filepath.Dir(dst), ".installer-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()

	cleanup := func(e error) error {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return e
	}
	if _, err := io.Copy(tmp, in); err != nil {
		return cleanup(err)
	}
	if err := tmp.Chmod(mode); err != nil {
		return cleanup(err)
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	if err := os.Rename(tmpPath, dst); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	return nil
}
