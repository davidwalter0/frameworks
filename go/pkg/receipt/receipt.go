// Package receipt records what an install actually placed on this host, so
// uninstall can remove exactly that — including files a NEWER version's
// render no longer knows about.
//
// Every installer this module replaces uninstalled from a hardcoded path
// list, which cannot remove what a different version installed: a file the
// new version stopped shipping survives as an orphan that still resolves on
// PATH. The receipt closes that gap. It is the "what WAS installed" half of
// the manifest split (decision D-0004/D-0005 and the migration plan): the
// input manifest says what SHOULD be installed and is generated at build
// time; the receipt says what a particular Apply DID and can only exist
// after it.
//
// Modeled on exttool/pkg/receipts — the one installer in the family that
// records — including its two load-bearing habits: a schema version from the
// first commit (a versionless file is unmigratable later), and an
// XDG_STATE_HOME home ("small, host-local, non-cache, non-config state").
// Like the rest of this module, path derivation is pure: the state home is
// injected at the call site, never read here.
package receipt

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/davidwalter0/frameworks/go/pkg/plan"
)

// CurrentSchema is the receipt file's schema version. Load rejects a NEWER
// schema (written by a future installer this code cannot interpret) rather
// than misreading it; older schemas gain migration logic when a second
// schema exists.
const CurrentSchema = 1

// File is one recorded placement.
type File struct {
	// Path is the absolute path the action touched.
	Path string `json:"path"`
	// Kind is the plan action kind that produced it: mkdir, write, symlink.
	Kind string `json:"kind"`
	// SHA256 is the content address of a written file, empty otherwise. It
	// is recorded so a LATER tool can tell "still the bytes we wrote" from
	// "modified since install"; uninstall itself does not gate on it.
	SHA256 string `json:"sha256,omitempty"`
	// Size is the written content length in bytes.
	Size int64 `json:"size,omitempty"`
	// Link is a symlink's recorded target.
	Link string `json:"link,omitempty"`
}

// Receipt is what one target's Apply did on this host.
type Receipt struct {
	Schema      int       `json:"schema"`
	App         string    `json:"app"`
	Version     string    `json:"version"`
	Target      string    `json:"target"`
	PlanDigest  string    `json:"plan_digest"`
	InstalledAt time.Time `json:"installed_at"`
	Files       []File    `json:"files"`
}

// DefaultPath is the receipt's location:
// <stateHome>/<app>/receipt-<target>.json. stateHome is XDG_STATE_HOME
// resolved at the CALL SITE (cli.OSEnv), so this stays a pure function.
//
// Receipts are PER TARGET, not per app: with one shared file, uninstalling
// only the filesystem target would see the systemd target's recorded unit
// files as orphans — paths its own render does not cover — and remove a
// live install's units.
func DefaultPath(stateHome, app, target string) (string, error) {
	if stateHome == "" {
		return "", fmt.Errorf("no state home: set XDG_STATE_HOME or HOME")
	}
	if app == "" || target == "" {
		return "", fmt.Errorf("receipt path needs both an app and a target name")
	}
	return filepath.Join(stateHome, app, "receipt-"+target+".json"), nil
}

// FromResults builds the recorded file list from what Apply reported. Only
// APPLIED actions are recorded: a guard-skipped write (an index.theme that
// already belonged to someone else) was not our doing and must not be
// removed as if it were. Remove actions do not record — they took state
// away rather than placing any.
func FromResults(results []plan.Result) []File {
	var out []File
	for _, r := range results {
		if !r.Applied {
			continue
		}
		a := r.Action
		switch a.Kind {
		case plan.KindMkdir:
			out = append(out, File{Path: a.Path, Kind: string(a.Kind)})
		case plan.KindWrite:
			sum := sha256.Sum256(a.Content)
			out = append(out, File{Path: a.Path, Kind: string(a.Kind),
				SHA256: hex.EncodeToString(sum[:]), Size: int64(len(a.Content))})
		case plan.KindSymlink:
			out = append(out, File{Path: a.Path, Kind: string(a.Kind), Link: a.LinkTarget})
		}
	}
	return out
}

// Load reads a receipt. A missing file is returned as os.ErrNotExist for the
// caller to treat as "no recorded install" — the normal state before the
// first receipt-writing install, never an error to report.
func Load(path string) (Receipt, error) {
	var r Receipt
	b, err := os.ReadFile(path)
	if err != nil {
		return r, err
	}
	if err := json.Unmarshal(b, &r); err != nil {
		return r, fmt.Errorf("receipt %s: %w", path, err)
	}
	if r.Schema > CurrentSchema {
		return r, fmt.Errorf("receipt %s has schema %d, newer than this installer understands (%d)",
			path, r.Schema, CurrentSchema)
	}
	return r, nil
}

// Save writes the receipt atomically (temp file + rename), creating the
// directory. A torn receipt is worse than none: uninstall would trust it.
func Save(path string, r Receipt) error {
	r.Schema = CurrentSchema
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Orphans returns the recorded files a rendered uninstall plan does NOT
// already cover — the paths only the receipt still knows about, because a
// newer version's render stopped shipping them. Coverage means the path
// itself is in the plan, or it sits under a directory the plan removes
// recursively (the app tree).
//
// Files and symlinks come back before directories, and directories deepest
// first, so a caller appending removals empties children before parents.
func Orphans(r Receipt, rendered plan.Plan) []File {
	covered := map[string]bool{}
	var roots []string
	for _, a := range rendered.Actions {
		covered[a.Path] = true
		if a.Kind == plan.KindRemove {
			roots = append(roots, a.Path)
		}
	}
	under := func(p string) bool {
		for _, root := range roots {
			if p == root || strings.HasPrefix(p, root+string(filepath.Separator)) {
				return true
			}
		}
		return false
	}

	var files, dirs []File
	for _, f := range r.Files {
		if covered[f.Path] || under(f.Path) {
			continue
		}
		if f.Kind == string(plan.KindMkdir) {
			dirs = append(dirs, f)
		} else {
			files = append(files, f)
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Path < files[j].Path })
	// Deepest directory first: children empty before their parent is judged.
	sort.Slice(dirs, func(i, j int) bool {
		return strings.Count(dirs[i].Path, string(filepath.Separator)) >
			strings.Count(dirs[j].Path, string(filepath.Separator))
	})
	return append(files, dirs...)
}

// AppendRemovals appends removal actions for orphans to a plan: files and
// symlinks unconditionally, directories only when EMPTY — a recorded mkdir
// may be a shared directory (share/applications) that other applications
// still populate, and a recursive remove there would take their files too.
func AppendRemovals(p *plan.Plan, orphans []File) {
	for _, f := range orphans {
		if f.Kind == string(plan.KindMkdir) {
			p.Add(plan.Action{Kind: plan.KindRemove, Path: f.Path,
				Guard: &plan.Guard{IfEmptyDir: f.Path},
				Note:  "recorded directory (removed only when empty)"})
			continue
		}
		p.Add(plan.Action{Kind: plan.KindRemove, Path: f.Path,
			Note: "recorded by a previous version's install"})
	}
}
