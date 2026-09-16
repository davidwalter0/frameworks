package plan

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func samplePlan(dir string) Plan {
	var p Plan
	p.Target = "test"
	p.Mkdir(filepath.Join(dir, "share", "app"), "app dir")
	p.Write(filepath.Join(dir, "share", "app", "config"), []byte("hello\n"), 0o644, "config")
	p.Write(filepath.Join(dir, "share", "app", "run"), []byte("#!/bin/sh\n"), 0o755, "script")
	p.Symlink(filepath.Join(dir, "bin", "app"), filepath.Join(dir, "share", "app", "run"), "PATH link")
	p.Instruct("systemctl --user daemon-reload")
	return p
}

// A dry run must be a COMPLETE description of what Apply would do, which is
// only true if it writes nothing at all. Hashing the tree before and after is
// the assertion that cannot be fooled by checking a couple of known paths.
func TestDryRunWritesNothing(t *testing.T) {
	dir := t.TempDir()
	before := hashTree(t, dir)

	results, err := Apply(samplePlan(dir), Options{DryRun: true})
	if err != nil {
		t.Fatalf("Apply(dry): %v", err)
	}
	if got, want := len(results), 4; got != want {
		t.Errorf("dry run should still report %d results, got %d", want, got)
	}
	for _, r := range results {
		if r.Applied {
			t.Errorf("dry run reported %s %s as applied", r.Action.Kind, r.Action.Path)
		}
	}
	if after := hashTree(t, dir); after != before {
		t.Errorf("dry run mutated the filesystem:\n before %s\n after  %s", before, after)
	}
}

func TestApplyWritesFilesModesAndLinks(t *testing.T) {
	dir := t.TempDir()
	if _, err := Apply(samplePlan(dir), Options{}); err != nil {
		t.Fatalf("Apply: %v", err)
	}

	body, err := os.ReadFile(filepath.Join(dir, "share", "app", "config"))
	if err != nil || string(body) != "hello\n" {
		t.Errorf("config not written: %q %v", body, err)
	}
	info, err := os.Stat(filepath.Join(dir, "share", "app", "run"))
	if err != nil {
		t.Fatalf("stat run: %v", err)
	}
	if info.Mode().Perm() != 0o755 {
		t.Errorf("run mode = %v, want 0755", info.Mode().Perm())
	}
	target, err := os.Readlink(filepath.Join(dir, "bin", "app"))
	if err != nil {
		t.Fatalf("readlink: %v", err)
	}
	if want := filepath.Join(dir, "share", "app", "run"); target != want {
		t.Errorf("symlink -> %s, want %s", target, want)
	}
}

// Re-running an install is the common case (upgrade in place), so a stale
// symlink from a previous version must be replaced, not refused.
func TestApplyReplacesExistingSymlink(t *testing.T) {
	dir := t.TempDir()
	if _, err := Apply(samplePlan(dir), Options{}); err != nil {
		t.Fatalf("first Apply: %v", err)
	}
	if _, err := Apply(samplePlan(dir), Options{}); err != nil {
		t.Fatalf("second Apply must succeed over an existing tree: %v", err)
	}
}

func TestApplyBackupKeepsPreviousContent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "conf")
	if err := os.WriteFile(path, []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var p Plan
	p.Write(path, []byte("new\n"), 0o644, "")
	if _, err := Apply(p, Options{Backup: true}); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if b, _ := os.ReadFile(path); string(b) != "new\n" {
		t.Errorf("current content = %q", b)
	}
	if b, err := os.ReadFile(path + ".bak"); err != nil || string(b) != "old\n" {
		t.Errorf("backup = %q, %v", b, err)
	}
}

func TestApplyStopsAtFirstError(t *testing.T) {
	dir := t.TempDir()
	// A file where the plan then wants a directory: the second action fails.
	blocker := filepath.Join(dir, "blocked")
	if err := os.WriteFile(blocker, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	var p Plan
	p.Write(filepath.Join(dir, "ok"), []byte("1"), 0o644, "")
	p.Mkdir(filepath.Join(blocker, "sub"), "")
	p.Write(filepath.Join(dir, "never"), []byte("2"), 0o644, "")

	results, err := Apply(p, Options{})
	if err == nil {
		t.Fatal("expected an error")
	}
	if len(results) != 2 {
		t.Errorf("should stop after the failing action, got %d results", len(results))
	}
	if _, err := os.Stat(filepath.Join(dir, "never")); err == nil {
		t.Error("actions after a failure must not run")
	}
}

// Digest is what golden tests compare first, so it must be sensitive to every
// byte that reaches disk and to the order of operations.
func TestDigestChangesWithContentAndOrder(t *testing.T) {
	base := samplePlan("/x")
	same := samplePlan("/x")
	if base.Digest() != same.Digest() {
		t.Fatal("identical plans must digest identically")
	}

	changed := samplePlan("/x")
	changed.Actions[1].Content = []byte("hello!\n")
	if changed.Digest() == base.Digest() {
		t.Error("a content change must change the digest")
	}

	reordered := samplePlan("/x")
	reordered.Actions[0], reordered.Actions[1] = reordered.Actions[1], reordered.Actions[0]
	if reordered.Digest() == base.Digest() {
		t.Error("order is semantic (mkdir before write); the digest must reflect it")
	}

	instructed := samplePlan("/x")
	instructed.Instructions = append(instructed.Instructions, "extra")
	if instructed.Digest() == base.Digest() {
		t.Error("instructions are half the product; the digest must cover them")
	}
}

func TestRemoveIsRecursive(t *testing.T) {
	dir := t.TempDir()
	nested := filepath.Join(dir, "a", "b")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(nested, "f"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	var p Plan
	p.Remove(filepath.Join(dir, "a"), "")
	if _, err := Apply(p, Options{}); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "a")); !os.IsNotExist(err) {
		t.Error("tree should be gone")
	}
}

func TestPathsAreSorted(t *testing.T) {
	p := samplePlan("/x")
	got := p.Paths()
	if !sort.StringsAreSorted(got) {
		t.Errorf("Paths() must be sorted, got %v", got)
	}
}

func TestInstructSkipsBlankLines(t *testing.T) {
	var p Plan
	p.Instruct("a", "", "   ", "b")
	if strings.Join(p.Instructions, ",") != "a,b" {
		t.Errorf("got %v", p.Instructions)
	}
}

// A guard is evaluated at the action's turn in sequence, which is what lets
// one action depend on whether an earlier one fired. This mirrors the exact
// shape the icon-theme lifecycle uses: marker and index share ONE condition
// (the index's absence), marker ordered first.
func TestGuardsEvaluateInSequence(t *testing.T) {
	dir := t.TempDir()
	index := filepath.Join(dir, "index.theme")
	marker := filepath.Join(dir, ".marker")

	var p Plan
	p.Add(Action{Kind: KindWrite, Path: marker, Guard: &Guard{IfAbsent: index}})
	p.Add(Action{Kind: KindWrite, Path: index, Content: []byte("theme"), Guard: &Guard{IfAbsent: index}})

	results, err := Apply(p, Options{})
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	for _, r := range results {
		if !r.Applied || r.Skipped != "" {
			t.Errorf("fresh host: %s should apply, got applied=%v skipped=%q",
				r.Action.Path, r.Applied, r.Skipped)
		}
	}

	// Second run: the index now exists, so BOTH actions must skip — the
	// marker must not be rewritten over a file someone else now owns.
	results, err = Apply(p, Options{})
	if err != nil {
		t.Fatalf("second Apply: %v", err)
	}
	for _, r := range results {
		if r.Applied || r.Skipped == "" {
			t.Errorf("existing index: %s should skip with a reason, got applied=%v skipped=%q",
				r.Action.Path, r.Applied, r.Skipped)
		}
	}
}

func TestGuardIfPresentAndTreeCheck(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(dir, ".marker")
	index := filepath.Join(dir, "index.theme")
	for _, f := range []string{marker, index} {
		if err := os.WriteFile(f, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	icon := filepath.Join(dir, "apps", "other.png")
	if err := os.MkdirAll(filepath.Dir(icon), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(icon, []byte("PNG"), 0o644); err != nil {
		t.Fatal(err)
	}

	guard := &Guard{IfPresent: marker, IfNoTreeFiles: &TreeCheck{Dir: dir, Exts: []string{".png", ".svg"}}}
	var p Plan
	p.Add(Action{Kind: KindRemove, Path: index, Guard: guard})

	// A surviving icon blocks the removal, and the reason NAMES the file —
	// "kept because files remain" would be undiagnosable.
	results, err := Apply(p, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if results[0].Applied || !strings.Contains(results[0].Skipped, "other.png") {
		t.Errorf("expected a skip naming the surviving icon, got applied=%v skipped=%q",
			results[0].Applied, results[0].Skipped)
	}

	if err := os.Remove(icon); err != nil {
		t.Fatal(err)
	}
	results, err = Apply(p, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if !results[0].Applied {
		t.Errorf("with no icons left the removal should run, got skipped=%q", results[0].Skipped)
	}

	// Missing marker: not ours to remove.
	if err := os.WriteFile(index, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	results, err = Apply(p, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if results[0].Applied {
		t.Error("without the authorship marker the index must be kept")
	}
}

// A dry run must not evaluate guards: guard N's truth depends on actions
// 1..N-1 having run, so evaluating against the untouched host would report
// conditions the real run will not see.
func TestDryRunDoesNotEvaluateGuards(t *testing.T) {
	dir := t.TempDir()
	present := filepath.Join(dir, "present")
	if err := os.WriteFile(present, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	var p Plan
	p.Add(Action{Kind: KindWrite, Path: filepath.Join(dir, "out"), Guard: &Guard{IfAbsent: present}})

	results, err := Apply(p, Options{DryRun: true})
	if err != nil {
		t.Fatal(err)
	}
	if results[0].Skipped != "" {
		t.Errorf("dry run evaluated a guard: %q", results[0].Skipped)
	}
}

// A guard changes what the plan DOES on a given host, so two plans differing
// only in a guard must not share a digest.
func TestDigestCoversGuards(t *testing.T) {
	mk := func(g *Guard) Plan {
		var p Plan
		p.Add(Action{Kind: KindWrite, Path: "/x", Content: []byte("c"), Guard: g})
		return p
	}
	bare := mk(nil)
	guarded := mk(&Guard{IfAbsent: "/y"})
	other := mk(&Guard{IfPresent: "/y"})
	if bare.Digest() == guarded.Digest() {
		t.Error("adding a guard must change the digest")
	}
	if guarded.Digest() == other.Digest() {
		t.Error("different guard conditions must digest differently")
	}
}

// hashTree fingerprints every path, mode and byte under root.
func hashTree(t *testing.T, root string) string {
	t.Helper()
	h := sha256.New()
	err := filepath.Walk(root, func(path string, info fs.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		_, _ = fmt.Fprintf(h, "%s\x00%o\x00", rel, info.Mode())
		if info.Mode().IsRegular() {
			b, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			_, _ = h.Write(b)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("hashTree: %v", err)
	}
	return hex.EncodeToString(h.Sum(nil))
}
