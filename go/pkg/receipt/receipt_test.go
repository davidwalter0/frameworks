package receipt

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/davidwalter0/frameworks/go/pkg/plan"
)

func TestDefaultPathIsPerAppAndTarget(t *testing.T) {
	p, err := DefaultPath("/state", "demo", "filesystem")
	if err != nil {
		t.Fatal(err)
	}
	if p != filepath.Join("/state", "demo", "receipt-filesystem.json") {
		t.Errorf("got %s", p)
	}
	for name, call := range map[string]func() (string, error){
		"no state home": func() (string, error) { return DefaultPath("", "demo", "filesystem") },
		"no app":        func() (string, error) { return DefaultPath("/state", "", "filesystem") },
		"no target":     func() (string, error) { return DefaultPath("/state", "demo", "") },
	} {
		if _, err := call(); err == nil {
			t.Errorf("%s should refuse", name)
		}
	}
}

func TestSaveLoadRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "app", "receipt-filesystem.json")
	want := Receipt{
		App: "demo", Version: "1.2.3", Target: "filesystem",
		PlanDigest:  "abc",
		InstalledAt: time.Date(2026, 8, 8, 0, 0, 0, 0, time.UTC),
		Files: []File{
			{Path: "/p/share/demo/bin/demo", Kind: "write", SHA256: "ff", Size: 2},
			{Path: "/p/bin/demo", Kind: "symlink", Link: "/p/share/demo/bin/demo"},
		},
	}
	if err := Save(path, want); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.Schema != CurrentSchema {
		t.Errorf("Save must stamp the schema; got %d", got.Schema)
	}
	if got.App != want.App || got.Version != want.Version || len(got.Files) != 2 {
		t.Errorf("round trip lost data: %+v", got)
	}
}

// A missing receipt is the NORMAL state before the first receipt-writing
// install — the caller must be able to distinguish it from a broken one.
func TestLoadMissingIsErrNotExist(t *testing.T) {
	_, err := Load(filepath.Join(t.TempDir(), "nope.json"))
	if !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("want fs.ErrNotExist, got %v", err)
	}
}

// A receipt written by a FUTURE installer must be refused, not misread: its
// semantics are unknown, and uninstalling on a misreading deletes files.
func TestLoadRejectsNewerSchema(t *testing.T) {
	path := filepath.Join(t.TempDir(), "receipt.json")
	if err := os.WriteFile(path, []byte(`{"schema": 99}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil || !strings.Contains(err.Error(), "newer") {
		t.Fatalf("want a newer-schema refusal, got %v", err)
	}
}

// Only APPLIED actions are recorded: a guard-skipped write was not our doing
// and must not be removed as if it were.
func TestFromResultsRecordsAppliedOnly(t *testing.T) {
	results := []plan.Result{
		{Action: plan.Action{Kind: plan.KindMkdir, Path: "/p/share/demo"}, Applied: true},
		{Action: plan.Action{Kind: plan.KindWrite, Path: "/p/share/demo/f", Content: []byte("hi")}, Applied: true},
		{Action: plan.Action{Kind: plan.KindWrite, Path: "/theme/index.theme"}, Skipped: "index.theme already exists"},
		{Action: plan.Action{Kind: plan.KindSymlink, Path: "/p/bin/demo", LinkTarget: "/p/share/demo/f"}, Applied: true},
		{Action: plan.Action{Kind: plan.KindRemove, Path: "/p/old"}, Applied: true},
	}
	files := FromResults(results)
	if len(files) != 3 {
		t.Fatalf("want 3 recorded (skip and remove excluded), got %d: %+v", len(files), files)
	}
	if files[1].SHA256 == "" || files[1].Size != 2 {
		t.Errorf("write must record content hash and size: %+v", files[1])
	}
	if files[2].Link != "/p/share/demo/f" {
		t.Errorf("symlink must record its target: %+v", files[2])
	}
	for _, f := range files {
		if f.Path == "/theme/index.theme" {
			t.Error("a guard-skipped write must not be recorded")
		}
	}
}

func TestOrphansExcludesCoveredPaths(t *testing.T) {
	r := Receipt{Files: []File{
		{Path: "/p/share/demo/kept-by-render", Kind: "write"},   // in plan
		{Path: "/p/share/demo/sub/under-root", Kind: "write"},   // under recursive remove
		{Path: "/p/bin/old-tool", Kind: "symlink"},              // orphan file
		{Path: "/p/share/applications", Kind: "mkdir"},          // orphan dir (shared)
		{Path: "/p/share/applications/deep/dir", Kind: "mkdir"}, // deeper orphan dir
	}}
	var rendered plan.Plan
	rendered.Remove("/p/share/demo", "app tree")
	rendered.Write("/p/share/demo/kept-by-render", nil, 0o644, "")

	got := Orphans(r, rendered)
	if len(got) != 3 {
		t.Fatalf("want 3 orphans, got %+v", got)
	}
	if got[0].Path != "/p/bin/old-tool" {
		t.Errorf("files come before dirs: %+v", got)
	}
	if got[1].Path != "/p/share/applications/deep/dir" || got[2].Path != "/p/share/applications" {
		t.Errorf("dirs must be deepest-first so children empty before parents: %+v", got)
	}
}

// The shared-directory case the IfEmptyDir guard exists for: a recorded
// mkdir may be a directory other applications still populate.
func TestAppendRemovalsSparesOccupiedDirs(t *testing.T) {
	dir := t.TempDir()
	shared := filepath.Join(dir, "applications")
	if err := os.MkdirAll(shared, 0o755); err != nil {
		t.Fatal(err)
	}
	foreign := filepath.Join(shared, "other-app.desktop")
	if err := os.WriteFile(foreign, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	empty := filepath.Join(dir, "empty")
	if err := os.MkdirAll(empty, 0o755); err != nil {
		t.Fatal(err)
	}

	var p plan.Plan
	AppendRemovals(&p, []File{
		{Path: shared, Kind: "mkdir"},
		{Path: empty, Kind: "mkdir"},
	})
	results, err := plan.Apply(p, plan.Options{})
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if _, err := os.Stat(foreign); err != nil {
		t.Error("a foreign file in a recorded shared dir must survive")
	}
	if _, err := os.Stat(empty); !os.IsNotExist(err) {
		t.Error("an empty recorded dir should be removed")
	}
	var skips int
	for _, res := range results {
		if res.Skipped != "" {
			skips++
		}
	}
	if skips != 1 {
		t.Errorf("want exactly the occupied dir skipped, got %d skips", skips)
	}
}
