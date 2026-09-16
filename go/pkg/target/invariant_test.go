package target_test

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// activationVerbs are the commands that CHANGE a host's or a cluster's running
// state. installkit prints them; it must never run them.
//
// `helm template` is deliberately absent: it is a local render that creates
// nothing, and pkg/target/helm_exec.go is the one sanctioned exec path.
var activationVerbs = []string{
	"systemctl",
	"helm upgrade",
	"helm install",
	"kubectl apply",
	"kubectl create",
}

// TestOnlyInstructPackageNamesActivationVerbs is the mechanical form of this
// module's central invariant (decision D-0004):
//
//	The installer materializes artifacts and prints activation commands.
//	It never activates.
//
// A comment saying so binds nothing; this test does.
//
// It scans STRING LITERALS via the AST rather than raw file text, and that
// distinction is the whole point: a verb in a comment is documentation, while
// a verb in a string literal is the argument you would hand exec.Command. A
// text-level grep cannot tell those apart — the first version of this test
// failed on five of its own explanatory comments.
func TestOnlyInstructPackageNamesActivationVerbs(t *testing.T) {
	root := repoRoot(t)
	allowed := filepath.Join(root, "pkg", "instruct")

	forEachGoFile(t, filepath.Join(root, "pkg"), func(path string, file *ast.File) {
		if strings.HasPrefix(path, allowed+string(filepath.Separator)) {
			return
		}
		rel, _ := filepath.Rel(root, path)
		ast.Inspect(file, func(n ast.Node) bool {
			lit, ok := n.(*ast.BasicLit)
			if !ok || lit.Kind != token.STRING {
				return true
			}
			val, err := strconv.Unquote(lit.Value)
			if err != nil {
				val = lit.Value
			}
			for _, verb := range activationVerbs {
				if strings.Contains(val, verb) {
					t.Errorf("%s has the string %q containing %q — activation verbs belong "+
						"only in pkg/instruct, which never executes them", rel, val, verb)
				}
			}
			return true
		})
	})
}

// TestInstructNeverExecutes pins the other half: the package that owns the
// activation strings must have no way to run them.
func TestInstructNeverExecutes(t *testing.T) {
	root := repoRoot(t)
	forEachGoFile(t, filepath.Join(root, "pkg", "instruct"), func(path string, file *ast.File) {
		rel, _ := filepath.Rel(root, path)
		for _, imp := range file.Imports {
			p, _ := strconv.Unquote(imp.Path.Value)
			if p == "os/exec" || p == "syscall" {
				t.Errorf("%s imports %q; this package formats text only", rel, p)
			}
		}
	})
}

// TestPlanPackageNeverExecutes: Apply writes files. If it grew an exec path,
// --dry-run would stop being a complete description of what Apply does.
func TestPlanPackageNeverExecutes(t *testing.T) {
	root := repoRoot(t)
	forEachGoFile(t, filepath.Join(root, "pkg", "plan"), func(path string, file *ast.File) {
		rel, _ := filepath.Rel(root, path)
		for _, imp := range file.Imports {
			p, _ := strconv.Unquote(imp.Path.Value)
			if p == "os/exec" {
				t.Errorf("%s imports os/exec; Apply writes files and runs nothing", rel)
			}
		}
	})
}

// execAllowed is the complete set of files in this module permitted to import
// os/exec, each with the reason it is not a violation of D-0004's invariant
// (materialize artifacts and PRINT activation commands; never activate).
//
// It is an ALLOWLIST over a walk of the whole module, deliberately, rather than
// a walk narrowed to the installer packages. Narrowing the scope would let a new
// package start execing without the gate noticing; an allowlist makes every
// exception visible, and adding one an explicit edit somebody has to justify
// here.
var execAllowed = map[string]string{
	// The single sanctioned installer exec: renders a chart LOCALLY to files.
	// It produces artifacts; it does not apply them to a cluster.
	"pkg/target/helm_exec.go": "renders a helm chart to local files; the apply command is printed, not run",

	// NOT part of the installer. pkg/pins backs cmd/pin-monitor, which reports
	// version drift across consumer repos by running `git tag --list` and
	// `git fetch --tags`. D-0004 governs what an INSTALLER may do to the
	// machine it installs on; a release-drift reporter reading git is outside
	// that scope entirely, and folding it in would dilute the invariant rather
	// than strengthen it.
	"pkg/pins/pins.go": "release-drift reporting via git; not an installer path",

	// PROBING IS NOT ACTIVATION. pkg/deps uses exec.LookPath to answer "is this
	// tool on PATH", which resolves a filename against PATH and returns it —
	// it never starts a process. That is the opposite of the behaviour D-0004
	// forbids: the whole point of the package is to report what is missing so
	// the operator can act, rather than acting for them.
	//
	// This entry was added because the gate CAUGHT pkg/deps on its first run,
	// which is the allowlist working as intended: a new exec importer must be
	// justified in writing rather than merged unnoticed.
	"pkg/deps/deps.go": "exec.LookPath resolves a name on PATH; it never executes anything",
}

// TestExactlyOneExecPath keeps the sanctioned exec surface from spreading.
//
// Absorbed from installkit with the rest of pkg/target (D-0005). It arrived
// FAILING, which is exactly what it is for: it found pkg/installer/icons.go
// execing gtk-update-icon-cache — frameworks' one standing violation of the
// invariant — and that call is now instruct.GtkUpdateIconCache, printed.
func TestExactlyOneExecPath(t *testing.T) {
	root := repoRoot(t)
	var violations []string
	seen := map[string]bool{}
	forEachGoFile(t, filepath.Join(root, "pkg"), func(path string, file *ast.File) {
		for _, imp := range file.Imports {
			p, _ := strconv.Unquote(imp.Path.Value)
			if p != "os/exec" {
				continue
			}
			rel, _ := filepath.Rel(root, path)
			rel = filepath.ToSlash(rel)
			seen[rel] = true
			if _, ok := execAllowed[rel]; !ok {
				violations = append(violations, rel)
			}
		}
	})

	for _, v := range violations {
		t.Errorf("%s imports os/exec and is not in execAllowed.\n"+
			"An installer materializes artifacts and PRINTS activation commands (D-0004).\n"+
			"Either print the command via pkg/instruct, or add an entry to execAllowed\n"+
			"stating why this file is not an activation path.", v)
	}

	// A stale allowlist is its own failure: an entry that no longer execs makes
	// the gate look stricter than it is, and hides the next real one behind an
	// exception nobody re-reads.
	for file := range execAllowed {
		if !seen[file] {
			t.Errorf("execAllowed lists %s, but it no longer imports os/exec — drop the entry", file)
		}
	}
}

func forEachGoFile(t *testing.T, dir string, fn func(path string, file *ast.File)) {
	t.Helper()
	fset := token.NewFileSet()
	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		parsed, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			return err
		}
		fn(path, parsed)
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s: %v", dir, err)
	}
}

func repoRoot(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd() // .../pkg/target
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	return filepath.Dir(filepath.Dir(wd))
}
