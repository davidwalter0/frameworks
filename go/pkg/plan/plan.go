// Package plan is the installer's unit of work: an ordered, content-addressed
// list of filesystem actions plus the commands an operator runs afterwards.
//
// A Plan is produced by a pure Render and consumed by Apply. Nothing here
// executes a command — Instructions are strings, deliberately, because the
// installer's contract across this whole module is:
//
//	It materializes artifacts and prints activation commands. It never activates.
package plan

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Kind is the sort of change an Action makes.
type Kind string

const (
	// KindMkdir creates a directory (and parents).
	KindMkdir Kind = "mkdir"
	// KindWrite writes a regular file.
	KindWrite Kind = "write"
	// KindSymlink creates or replaces a symlink.
	KindSymlink Kind = "symlink"
	// KindRemove deletes a path recursively (uninstall).
	KindRemove Kind = "remove"
)

// Action is one filesystem change.
type Action struct {
	Kind Kind
	Path string
	// Content is the file body for KindWrite.
	Content []byte
	// Mode is the permission bits for KindWrite and KindMkdir.
	Mode fs.FileMode
	// LinkTarget is the destination for KindSymlink.
	LinkTarget string
	// Guard, when non-nil, restricts the action to hosts in a particular
	// state. Nil means unconditional.
	Guard *Guard
	// Note explains WHY this action exists; it is shown in --dry-run output
	// so a plan reads as an explanation rather than a file list.
	Note string
}

// Guard is a host-state condition evaluated by Apply immediately before its
// action runs. This is how a PURE render expresses decisions that depend on
// the host: the render declares the condition, Apply observes the state.
//
// The conditions AND together. A guard is evaluated at the action's turn in
// sequence — after earlier actions have run — which is what lets one action
// depend on whether a previous one fired (see the icon-theme lifecycle in
// pkg/target, the case this vocabulary was built for).
//
// A dry run does NOT evaluate guards: guard N's truth depends on actions
// 1..N-1 having actually run, so evaluating against the untouched host would
// report conditions the real run will not see. The dry-run output prints the
// condition itself instead.
type Guard struct {
	// IfAbsent: run only if this path does not exist.
	IfAbsent string
	// IfPresent: run only if this path exists.
	IfPresent string
	// IfNoTreeFiles: run only if no file with one of the extensions exists
	// under the directory. A missing directory passes vacuously.
	IfNoTreeFiles *TreeCheck
	// IfEmptyDir: run only if this directory contains no entries at all. A
	// missing directory passes vacuously (already gone is as good as empty).
	// This is what lets an uninstall remove a SHARED directory it recorded
	// creating (share/applications) without taking other applications' files.
	IfEmptyDir string
}

// TreeCheck names a directory and the file extensions to look for.
type TreeCheck struct {
	Dir  string
	Exts []string // with the leading dot: ".png", ".svg"
}

// String renders the condition for dry-run output.
func (g Guard) String() string {
	var parts []string
	if g.IfAbsent != "" {
		parts = append(parts, fmt.Sprintf("if %s is absent", g.IfAbsent))
	}
	if g.IfPresent != "" {
		parts = append(parts, fmt.Sprintf("if %s exists", g.IfPresent))
	}
	if g.IfNoTreeFiles != nil {
		parts = append(parts, fmt.Sprintf("if no %s file remains under %s",
			strings.Join(g.IfNoTreeFiles.Exts, "/"), g.IfNoTreeFiles.Dir))
	}
	if g.IfEmptyDir != "" {
		parts = append(parts, fmt.Sprintf("if %s is empty", g.IfEmptyDir))
	}
	return strings.Join(parts, " and ")
}

// blocked returns a non-empty reason when the host's current state fails the
// guard.
func (g Guard) blocked() string {
	if g.IfAbsent != "" {
		if _, err := os.Lstat(g.IfAbsent); err == nil {
			return g.IfAbsent + " already exists"
		}
	}
	if g.IfPresent != "" {
		if _, err := os.Lstat(g.IfPresent); err != nil {
			return g.IfPresent + " does not exist"
		}
	}
	if t := g.IfNoTreeFiles; t != nil {
		if p := t.firstMatch(); p != "" {
			return p + " remains"
		}
	}
	if g.IfEmptyDir != "" {
		// Read one entry, not the whole directory: emptiness is the question.
		if f, err := os.Open(g.IfEmptyDir); err == nil {
			names, _ := f.Readdirnames(1)
			_ = f.Close()
			if len(names) > 0 {
				return g.IfEmptyDir + " still contains " + names[0]
			}
		}
	}
	return ""
}

// firstMatch returns one matching file under Dir, or "" when none exists.
// Naming the survivor matters: "kept because X remains" is diagnosable,
// "kept because files remain" is not.
func (t TreeCheck) firstMatch() string {
	found := ""
	// The walk error is deliberately dropped alongside unreadable entries: a
	// directory that cannot be read cannot demonstrate a remaining file, and
	// a missing directory passes the check vacuously.
	_ = filepath.WalkDir(t.Dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		for _, ext := range t.Exts {
			if strings.HasSuffix(path, ext) {
				found = path
				return fs.SkipAll
			}
		}
		return nil
	})
	return found
}

// Plan is everything one target intends to do.
type Plan struct {
	// Target names the backend that produced this plan.
	Target string
	// Actions are applied in order.
	Actions []Action
	// Instructions are the commands the OPERATOR runs to activate what was
	// installed. The installer prints them and never runs them.
	Instructions []string
	// Notes are advisory lines (missing runtime dependency, degraded
	// capability). A note never silently replaces an error.
	Notes []string
}

// Add appends an action.
func (p *Plan) Add(a Action) { p.Actions = append(p.Actions, a) }

// Mkdir appends a directory creation.
func (p *Plan) Mkdir(path string, note string) {
	p.Add(Action{Kind: KindMkdir, Path: path, Mode: 0o755, Note: note})
}

// Write appends a file write.
func (p *Plan) Write(path string, content []byte, mode fs.FileMode, note string) {
	p.Add(Action{Kind: KindWrite, Path: path, Content: content, Mode: mode, Note: note})
}

// Symlink appends a symlink creation.
func (p *Plan) Symlink(path, target, note string) {
	p.Add(Action{Kind: KindSymlink, Path: path, LinkTarget: target, Note: note})
}

// Remove appends a recursive delete.
func (p *Plan) Remove(path, note string) {
	p.Add(Action{Kind: KindRemove, Path: path, Note: note})
}

// Instruct appends one operator command, skipping empties.
func (p *Plan) Instruct(lines ...string) {
	for _, l := range lines {
		if strings.TrimSpace(l) != "" {
			p.Instructions = append(p.Instructions, l)
		}
	}
}

// Note appends an advisory line.
func (p *Plan) Note(format string, args ...any) {
	p.Notes = append(p.Notes, fmt.Sprintf(format, args...))
}

// Paths returns every path the plan touches, sorted — used by tests and by
// the uninstall reversal.
func (p Plan) Paths() []string {
	out := make([]string, 0, len(p.Actions))
	for _, a := range p.Actions {
		out = append(out, a.Path)
	}
	sort.Strings(out)
	return out
}

// Digest is a content address for the whole plan: the same Spec must produce
// the same digest, and any change to a rendered byte must change it. Golden
// tests compare digests before diffing trees, so an unintended change is a
// one-line failure rather than a wall of output.
func (p Plan) Digest() string {
	// hash.Hash documents that Write never returns an error, so these are
	// discarded deliberately rather than overlooked.
	h := sha256.New()
	_, _ = fmt.Fprintf(h, "target\x00%s\x00", p.Target)
	for _, a := range p.Actions {
		_, _ = fmt.Fprintf(h, "%s\x00%s\x00%o\x00%s\x00", a.Kind, a.Path, a.Mode, a.LinkTarget)
		if a.Guard != nil {
			// A guard changes what the plan DOES on a given host, so two
			// plans differing only in a guard must not share a digest.
			_, _ = fmt.Fprintf(h, "g\x00%s\x00", a.Guard.String())
		}
		_, _ = h.Write(a.Content)
		_, _ = h.Write([]byte{0})
	}
	for _, i := range p.Instructions {
		_, _ = fmt.Fprintf(h, "i\x00%s\x00", i)
	}
	return hex.EncodeToString(h.Sum(nil))
}

// Result records what happened to one Action.
type Result struct {
	Action Action
	// Applied is false in a dry run, or when the action was skipped.
	Applied bool
	// Skipped carries the guard's reason when host state blocked the action
	// ("index.theme already exists"). Empty otherwise. A guard skip is an
	// OUTCOME, not an error: the plan anticipated both states of the host.
	Skipped string
	Err     error
}

// Options control Apply.
type Options struct {
	// DryRun writes nothing. Apply still returns a Result per action so the
	// caller can print exactly what WOULD happen.
	DryRun bool
	// Backup renames an existing regular file to <path>.bak before
	// overwriting it. Directories and symlinks are replaced without backup —
	// a symlink carries no content to lose.
	Backup bool
}

// Apply performs the plan's actions in order, stopping at the first error.
//
// It writes files. It does not run commands: there is no exec path in this
// package, which is what makes the module's central invariant mechanically
// checkable rather than merely documented.
func Apply(p Plan, opts Options) ([]Result, error) {
	results := make([]Result, 0, len(p.Actions))
	for _, a := range p.Actions {
		res := Result{Action: a}
		if opts.DryRun {
			results = append(results, res)
			continue
		}
		if a.Guard != nil {
			if reason := a.Guard.blocked(); reason != "" {
				res.Skipped = reason
				results = append(results, res)
				continue
			}
		}
		if err := applyOne(a, opts); err != nil {
			res.Err = err
			results = append(results, res)
			return results, fmt.Errorf("%s %s: %w", a.Kind, a.Path, err)
		}
		res.Applied = true
		results = append(results, res)
	}
	return results, nil
}

func applyOne(a Action, opts Options) error {
	switch a.Kind {
	case KindMkdir:
		return os.MkdirAll(a.Path, dirMode(a.Mode))

	case KindWrite:
		if err := os.MkdirAll(filepath.Dir(a.Path), 0o755); err != nil {
			return err
		}
		if opts.Backup {
			if err := backup(a.Path); err != nil {
				return err
			}
		}
		return os.WriteFile(a.Path, a.Content, fileMode(a.Mode))

	case KindSymlink:
		if err := os.MkdirAll(filepath.Dir(a.Path), 0o755); err != nil {
			return err
		}
		// Replace unconditionally: a stale link to a previous version is the
		// common case, and Symlink refuses to clobber.
		if err := os.Remove(a.Path); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		return os.Symlink(a.LinkTarget, a.Path)

	case KindRemove:
		return os.RemoveAll(a.Path)
	}
	return fmt.Errorf("unknown action kind %q", a.Kind)
}

func backup(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return err
	}
	if !info.Mode().IsRegular() {
		return nil
	}
	return os.Rename(path, path+".bak")
}

func dirMode(m fs.FileMode) fs.FileMode {
	if m == 0 {
		return 0o755
	}
	return m
}

func fileMode(m fs.FileMode) fs.FileMode {
	if m == 0 {
		return 0o644
	}
	return m
}
