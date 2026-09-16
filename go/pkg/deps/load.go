package deps

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

func newReader(b []byte) *bytes.Reader { return bytes.NewReader(b) }

// FileName is the manifest's name at a repo root. Fixed rather than
// configurable: a per-repo location would be one more thing to discover, and
// the point of this package is that there is one place to look.
const FileName = "deps.yaml"

// Load reads and validates a manifest.
//
// A missing file is an error, not an empty manifest. "No deps.yaml" and "this
// component declares no prerequisites" are different statements, and silently
// treating the first as the second would make a typo in a path look like a
// clean bill of health — the vacuous pass this family keeps rediscovering.
// A component with genuinely nothing to declare writes `requires: []`.
func Load(path string) (Manifest, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Manifest{}, fmt.Errorf("deps: reading %s: %w", path, err)
	}
	m, err := LoadBytes(b)
	if err != nil {
		return m, fmt.Errorf("%s: %w", path, err)
	}
	return m, nil
}

// LoadBytes parses and validates a manifest from memory.
//
// Split out from [Load] so parsing is testable without a temp file, and so an
// installed manifest read from a tree can be checked with the same code path
// that checks a repo's.
func LoadBytes(b []byte) (Manifest, error) {
	var m Manifest

	// KnownFields makes a misspelled key an error instead of a silently
	// ignored line. A prerequisite that was meant to be `required` but is
	// spelled `requred` would otherwise vanish without a word.
	dec := yaml.NewDecoder(newReader(b))
	dec.KnownFields(true)
	if err := dec.Decode(&m); err != nil {
		return m, fmt.Errorf("deps: parsing: %w", err)
	}

	if err := m.Validate(); err != nil {
		return m, err
	}
	return m, nil
}

// Find locates the manifest for dir, walking up to the repo root so a Makefile
// in go/ or ui/ finds the one at the top without naming a relative path that
// breaks when the tree is reorganised.
//
// The walk stops at a .git entry (file or directory — a worktree's .git is a
// FILE, and treating only directories as roots would walk out of every worktree
// into the parent checkout).
func Find(dir string) (string, error) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return "", fmt.Errorf("deps: resolving %s: %w", dir, err)
	}
	for {
		cand := filepath.Join(abs, FileName)
		if _, err := os.Stat(cand); err == nil {
			return cand, nil
		}
		if _, err := os.Stat(filepath.Join(abs, ".git")); err == nil {
			return "", fmt.Errorf("deps: no %s at repo root %s", FileName, abs)
		}
		parent := filepath.Dir(abs)
		if parent == abs {
			return "", fmt.Errorf("deps: no %s found from %s upward", FileName, dir)
		}
		abs = parent
	}
}
