package cli

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

func testEnv(t *testing.T) (Env, string) {
	t.Helper()
	dir := t.TempDir()
	return Env{
		Home:       dir,
		ConfigHome: filepath.Join(dir, ".config"),
		Path:       filepath.Join(dir, ".local", "bin"),
		StateHome:  filepath.Join(dir, ".local", "state"),
	}, dir
}

func serviceSpec() spec.Spec {
	return spec.Spec{
		App:     "demo",
		Version: "1.2.3",
		Tokens:  map[string]string{"EXEC": "/usr/bin/demo", "CONFIG": "/etc/demo.yaml"},
		Units: []spec.Unit{
			{Kind: spec.KindService, Stem: "demo",
				Content: "[Service]\nExecStart=__EXEC__ --config __CONFIG__\n"},
			{Kind: spec.KindSocket, Stem: "demo",
				Content: "[Socket]\nListenStream=127.0.0.1:1\n"},
		},
	}
}

func run(t *testing.T, s spec.Spec, env Env, args ...string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	err := Run(s, args, env, &out)
	return out.String(), err
}

func TestVersionShortCircuits(t *testing.T) {
	env, _ := testEnv(t)
	out, err := run(t, serviceSpec(), env, "--version")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !strings.Contains(out, "demo installer 1.2.3") {
		t.Errorf("got %q", out)
	}
}

// End to end: units land in the staged XDG directory with tokens resolved,
// and the activation commands are printed rather than run.
func TestSystemdInstallWritesUnitsAndPrintsCommands(t *testing.T) {
	env, home := testEnv(t)
	out, err := run(t, serviceSpec(), env, "--target=systemd")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	unit := filepath.Join(home, ".config", "systemd", "user", "demo.service")
	body, err := os.ReadFile(unit)
	if err != nil {
		t.Fatalf("unit not written: %v", err)
	}
	if !strings.Contains(string(body), "ExecStart=/usr/bin/demo --config /etc/demo.yaml") {
		t.Errorf("tokens not substituted:\n%s", body)
	}
	if strings.Contains(string(body), "__") {
		t.Errorf("unsubstituted token survived:\n%s", body)
	}
	if !strings.Contains(out, "does not run them for you") {
		t.Errorf("output should say the commands are the operator's to run:\n%s", out)
	}
	if !strings.Contains(out, "systemctl --user enable --now demo.socket") {
		t.Errorf("missing activation command:\n%s", out)
	}
}

// --dry-run must be a complete description: same output, no file.
func TestDryRunPrintsButWritesNothing(t *testing.T) {
	env, home := testEnv(t)
	out, err := run(t, serviceSpec(), env, "--target=systemd", "--dry-run")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !strings.Contains(out, "Would install") {
		t.Errorf("dry run should say so:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(home, ".config", "systemd", "user", "demo.service")); !os.IsNotExist(err) {
		t.Error("--dry-run wrote a unit file")
	}
	if !strings.Contains(out, "systemctl --user daemon-reload") {
		t.Errorf("a dry run must still show the commands:\n%s", out)
	}
}

func TestUnitDirOverrideStages(t *testing.T) {
	env, _ := testEnv(t)
	staged := t.TempDir()
	if _, err := run(t, serviceSpec(), env, "--target=systemd", "--unit-dir", staged); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, err := os.Stat(filepath.Join(staged, "demo.service")); err != nil {
		t.Errorf("--unit-dir should stage there: %v", err)
	}
}

func TestUnitKindFilter(t *testing.T) {
	env, home := testEnv(t)
	if _, err := run(t, serviceSpec(), env, "--target=systemd", "--unit=socket"); err != nil {
		t.Fatalf("Run: %v", err)
	}
	dir := filepath.Join(home, ".config", "systemd", "user")
	if _, err := os.Stat(filepath.Join(dir, "demo.socket")); err != nil {
		t.Errorf("socket should be installed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "demo.service")); !os.IsNotExist(err) {
		t.Error("--unit=socket must not install the service")
	}
}

func TestBadFlagValuesAreNamed(t *testing.T) {
	env, _ := testEnv(t)
	if _, err := run(t, serviceSpec(), env, "--target=systemd", "--scope=root"); err == nil ||
		!strings.Contains(err.Error(), "root") {
		t.Errorf("bad scope should be rejected by name, got %v", err)
	}
	if _, err := run(t, serviceSpec(), env, "--target=systemd", "--unit=sevice"); err == nil ||
		!strings.Contains(err.Error(), "sevice") {
		t.Errorf("a typo'd unit kind must fail rather than install nothing, got %v", err)
	}
	if _, err := run(t, serviceSpec(), env, "--target=nonsense"); err == nil ||
		!strings.Contains(err.Error(), "nonsense") {
		t.Errorf("unknown target should be named, got %v", err)
	}
}

func TestInstanceFlagAppliesToTemplateUnits(t *testing.T) {
	env, home := testEnv(t)
	if _, err := run(t, serviceSpec(), env, "--target=systemd", "--unit=service",
		"--instance", "you@example.com"); err != nil {
		t.Fatalf("Run: %v", err)
	}
	want := filepath.Join(home, ".config", "systemd", "user", `demo@you\x40example.com.service`)
	if _, err := os.Stat(want); err != nil {
		t.Errorf("instance unit not written at %s: %v", want, err)
	}
}

// The kubernetes target renders; it never applied anything, so it has nothing
// to withdraw and must say so rather than pretending to uninstall.
func TestKubernetesUninstallIsRefusedWithAReason(t *testing.T) {
	env, _ := testEnv(t)
	_, err := run(t, serviceSpec(), env, "--target=kubernetes", "--uninstall")
	if err == nil {
		t.Fatal("expected a refusal")
	}
	if !strings.Contains(err.Error(), "helm uninstall") {
		t.Errorf("the refusal should name the operator's route out; got %v", err)
	}
}

func TestFilesystemInstallAndUninstall(t *testing.T) {
	env, home := testEnv(t)
	s := spec.Spec{
		App:      "demo",
		Payload:  tarGz(t, map[string]string{"bin/demo": "#!/bin/sh\necho hi\n"}),
		Binaries: []spec.Binary{{Name: "demo", Rel: "bin/demo"}},
	}
	if _, err := run(t, s, env, "--target=filesystem"); err != nil {
		t.Fatalf("install: %v", err)
	}
	appFile := filepath.Join(home, ".local", "share", "demo", "bin", "demo")
	if _, err := os.Stat(appFile); err != nil {
		t.Fatalf("payload not extracted: %v", err)
	}
	link := filepath.Join(home, ".local", "bin", "demo")
	target, err := os.Readlink(link)
	if err != nil || target != appFile {
		t.Errorf("symlink = %q (%v), want %q", target, err, appFile)
	}

	if _, err := run(t, s, env, "--target=filesystem", "--uninstall"); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Stat(appFile); !os.IsNotExist(err) {
		t.Error("uninstall left the payload behind")
	}
}

// The cross-version orphan case the receipt exists for: v1 installs a binary
// that v2 stopped shipping, then v2 uninstalls. Every installer this module
// replaces used a hardcoded list here and left v1's file resolving on PATH.
func TestUninstallRemovesOtherVersionsOrphans(t *testing.T) {
	env, home := testEnv(t)
	v1 := spec.Spec{
		App:     "demo",
		Version: "1",
		Payload: tarGz(t, map[string]string{"bin/demo": "v1", "bin/demo-helper": "v1"}),
		Binaries: []spec.Binary{
			{Name: "demo", Rel: "bin/demo"},
			{Name: "demo-helper", Rel: "bin/demo-helper"},
		},
	}
	out, err := run(t, v1, env, "--target=filesystem")
	if err != nil {
		t.Fatalf("v1 install: %v", err)
	}
	if !strings.Contains(out, "Recorded install receipt") {
		t.Fatalf("install should say where the receipt went:\n%s", out)
	}
	helper := filepath.Join(home, ".local", "bin", "demo-helper")
	if _, err := os.Lstat(helper); err != nil {
		t.Fatalf("v1 helper link missing: %v", err)
	}

	// v2 dropped demo-helper. Its RENDERED uninstall knows nothing of it;
	// only the receipt does.
	v2 := v1
	v2.Version = "2"
	v2.Payload = tarGz(t, map[string]string{"bin/demo": "v2"})
	v2.Binaries = []spec.Binary{{Name: "demo", Rel: "bin/demo"}}

	if _, err := run(t, v2, env, "--target=filesystem", "--uninstall"); err != nil {
		t.Fatalf("v2 uninstall: %v", err)
	}
	if _, err := os.Lstat(helper); !os.IsNotExist(err) {
		t.Error("v1's orphaned helper link survived the receipt-driven uninstall")
	}
	receiptPath := filepath.Join(env.StateHome, "demo", "receipt-filesystem.json")
	if _, err := os.Stat(receiptPath); !os.IsNotExist(err) {
		t.Error("the uninstall should consume the receipt")
	}
}

// A host with no resolvable state home installs WITHOUT a receipt — degraded
// and said, never an install failure over its own audit trail.
func TestNoStateHomeDegradesLoudly(t *testing.T) {
	env, _ := testEnv(t)
	env.StateHome = ""
	s := spec.Spec{
		App:      "demo",
		Payload:  tarGz(t, map[string]string{"bin/demo": "x"}),
		Binaries: []spec.Binary{{Name: "demo", Rel: "bin/demo"}},
	}
	out, err := run(t, s, env, "--target=filesystem")
	if err != nil {
		t.Fatalf("install must succeed without a state home: %v", err)
	}
	if !strings.Contains(out, "receipt not recorded") {
		t.Errorf("the degradation must be said:\n%s", out)
	}
}

func TestFilesystemWithoutPayloadIsUnavailable(t *testing.T) {
	env, _ := testEnv(t)
	_, err := run(t, spec.Spec{App: "demo"}, env, "--target=filesystem")
	if err == nil || !strings.Contains(err.Error(), "target unavailable") {
		t.Fatalf("a payload-less build must say so; got %v", err)
	}
}

// Two targets in one invocation is the point of a repeatable --target.
func TestMultipleTargetsInOneRun(t *testing.T) {
	env, home := testEnv(t)
	s := serviceSpec()
	s.Payload = tarGz(t, map[string]string{"bin/demo": "x"})
	s.Binaries = []spec.Binary{{Name: "demo", Rel: "bin/demo"}}

	out, err := run(t, s, env, "--target=filesystem,systemd")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !strings.Contains(out, "[filesystem]") || !strings.Contains(out, "[systemd]") {
		t.Errorf("both targets should report:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(home, ".local", "share", "demo", "bin", "demo")); err != nil {
		t.Errorf("filesystem target did not run: %v", err)
	}
	if _, err := os.Stat(filepath.Join(home, ".config", "systemd", "user", "demo.service")); err != nil {
		t.Errorf("systemd target did not run: %v", err)
	}
}

func tarGz(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	tw := tar.NewWriter(zw)
	for name, body := range files {
		if err := tw.WriteHeader(&tar.Header{
			Name: name, Mode: 0o755, Size: int64(len(body)), Typeflag: tar.TypeReg,
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(body)); err != nil {
			t.Fatal(err)
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
