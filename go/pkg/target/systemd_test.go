package target

import (
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

// ghkLikeSpec mirrors gatehub-kit's real packaging: a service plus a socket
// with a drop-in, user scope, three tokens. It is the shape the first
// adoption has to reproduce byte-for-byte.
func ghkLikeSpec() spec.Spec {
	return spec.Spec{
		App:        "ghk",
		Scope:      spec.ScopeUser,
		ConfigHome: "/tmp/stage/config",
		Tokens: map[string]string{
			"EXEC":       "/home/u/go/bin/ghk",
			"CONFIG":     "/home/u/.config/ghk/ghk.yaml",
			"CONFIG_DIR": "/home/u/.config/ghk",
			"HTTP_ADDR":  "127.0.0.1:8080",
		},
		Units: []spec.Unit{
			{
				Kind: spec.KindService, Stem: "ghk",
				Content: "[Service]\nExecStart=__EXEC__ serve --config __CONFIG__\n",
			},
			{
				Kind: spec.KindSocket, Stem: "ghk",
				Content: "[Socket]\nListenStream=__HTTP_ADDR__\nListenStream=__CONFIG_DIR__/ghk.sock\n",
				DropIns: map[string]string{"socket.conf": "[Unit]\nRequires=ghk.socket\n"},
			},
		},
	}
}

func TestSystemdRendersUnitsAndDropIns(t *testing.T) {
	p, err := Systemd(ghkLikeSpec(), nil)
	if err != nil {
		t.Fatalf("Systemd: %v", err)
	}

	dir := "/tmp/stage/config/systemd/user"
	want := map[string]string{
		filepath.Join(dir, "ghk.service"):              "ExecStart=/home/u/go/bin/ghk serve --config /home/u/.config/ghk/ghk.yaml",
		filepath.Join(dir, "ghk.socket"):               "ListenStream=127.0.0.1:8080",
		filepath.Join(dir, "ghk.socket.d/socket.conf"): "Requires=ghk.socket",
	}
	got := map[string]string{}
	for _, a := range p.Actions {
		if a.Kind == "write" {
			got[a.Path] = string(a.Content)
		}
	}
	for path, substr := range want {
		body, ok := got[path]
		if !ok {
			t.Errorf("no write action for %s (got %v)", path, keysOf(got))
			continue
		}
		if !strings.Contains(body, substr) {
			t.Errorf("%s does not contain %q:\n%s", path, substr, body)
		}
	}
	if strings.Contains(strings.Join(valuesOf(got), "\n"), "__") {
		t.Error("an unsubstituted __TOKEN__ survived into a rendered unit")
	}
}

// The socket must be enabled BEFORE the service is touched, and the service
// is restarted rather than enabled — that ordering is the entire reason
// ghk.socket exists (listeners survive a restart).
func TestSystemdSocketOrderingIsLoadBearing(t *testing.T) {
	p, err := Systemd(ghkLikeSpec(), nil)
	if err != nil {
		t.Fatalf("Systemd: %v", err)
	}
	joined := strings.Join(p.Instructions, "\n")

	socketAt := indexOfLine(p.Instructions, "enable --now ghk.socket")
	serviceAt := indexOfLine(p.Instructions, "ghk.service")
	if socketAt < 0 || serviceAt < 0 {
		t.Fatalf("missing socket or service instruction:\n%s", joined)
	}
	if socketAt > serviceAt {
		t.Errorf("socket must be enabled before the service is restarted:\n%s", joined)
	}
	if !strings.Contains(joined, "restart ghk.service") {
		t.Errorf("a socket-activated service should be RESTARTED, not enabled:\n%s", joined)
	}
	if strings.Contains(joined, "enable --now ghk.service") {
		t.Errorf("socket-activated service must not be enabled directly:\n%s", joined)
	}
	if !strings.HasPrefix(p.Instructions[0], "systemctl --user daemon-reload") {
		t.Errorf("daemon-reload must come first, got %q", p.Instructions[0])
	}
}

// A timer's paired service must never be enabled: enabling both makes the job
// run at boot AND on schedule, which reads as a scheduling bug for as long as
// it takes anyone to notice.
func TestSystemdTimerDoesNotEnablePairedService(t *testing.T) {
	s := spec.Spec{
		App: "sweeper", Scope: spec.ScopeSystem,
		Units: []spec.Unit{
			{Kind: spec.KindService, Stem: "sweep", Content: "[Service]\nExecStart=/bin/true\n"},
			{Kind: spec.KindTimer, Stem: "sweep", Content: "[Timer]\nOnCalendar=daily\n"},
		},
	}
	p, err := Systemd(s, nil)
	if err != nil {
		t.Fatalf("Systemd: %v", err)
	}
	joined := strings.Join(p.Instructions, "\n")
	if !strings.Contains(joined, "sudo systemctl enable --now sweep.timer") {
		t.Errorf("timer should be enabled:\n%s", joined)
	}
	if strings.Contains(joined, "enable --now sweep.service") {
		t.Errorf("a timer's paired service must NOT be enabled:\n%s", joined)
	}
	if !strings.Contains(joined, "do NOT enable it directly") {
		t.Errorf("the reason should be stated inline:\n%s", joined)
	}
}

// A user manager cannot mount. Installing the unit anyway would leave a file
// that looks installed and never mounts anything — the exact silent no-op the
// design refuses.
func TestSystemdUserScopeMountRefused(t *testing.T) {
	s := spec.Spec{
		App: "mountbridge", Scope: spec.ScopeUser, ConfigHome: "/tmp/c",
		Units: []spec.Unit{{Kind: spec.KindMount, Where: "/mnt/gdrive", Content: "[Mount]\nWhat=mountbridge\n"}},
	}
	_, err := Systemd(s, nil)
	if err == nil {
		t.Fatal("expected a refusal for --scope=user with a .mount unit")
	}
	for _, want := range []string{"--scope=system", "instance service", "/mnt/gdrive"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("refusal should name %q; got:\n%s", want, err)
		}
	}
}

// The mount unit's filename is DERIVED. A caller cannot supply one, and the
// derived name must match systemd's own escaping (see TestEscapeMatchesSystemd).
func TestSystemdMountUnitNameIsDerived(t *testing.T) {
	s := spec.Spec{
		App: "store", Scope: spec.ScopeSystem,
		Units: []spec.Unit{{Kind: spec.KindMount, Where: "/mnt/my-disk", Content: "[Mount]\nWhat=/dev/sdb1\n"}},
	}
	p, err := Systemd(s, nil)
	if err != nil {
		t.Fatalf("Systemd: %v", err)
	}
	want := `/etc/systemd/system/mnt-my\x2ddisk.mount`
	if !hasPath(p.Paths(), want) {
		t.Errorf("want unit at %s, got %v", want, p.Paths())
	}
}

func TestSystemdInstanceUnitEscapesInstance(t *testing.T) {
	s := spec.Spec{
		App: "mountbridge", Scope: spec.ScopeUser, ConfigHome: "/tmp/c",
		Units: []spec.Unit{{
			Kind: spec.KindService, Stem: "mountbridge", Instance: "you@example.com",
			Content: "[Service]\nExecStart=/bin/true\n",
		}},
	}
	p, err := Systemd(s, nil)
	if err != nil {
		t.Fatalf("Systemd: %v", err)
	}
	want := `/tmp/c/systemd/user/mountbridge@you\x40example.com.service`
	if !hasPath(p.Paths(), want) {
		t.Errorf("want %s, got %v", want, p.Paths())
	}
}

// The whole-file sed this replaces could not tell an undefined token from a
// deliberate one: it shipped the placeholder as literal text, or substituted
// an empty string and produced a unit that looked fine and did nothing.
func TestSystemdUndefinedTokenIsAnError(t *testing.T) {
	s := spec.Spec{
		App: "x", Scope: spec.ScopeUser, ConfigHome: "/tmp/c",
		Tokens: map[string]string{"EXEC": "/bin/x"},
		Units: []spec.Unit{
			{Kind: spec.KindService, Stem: "x", Content: "ExecStart=__EXEC__ --config __CONFIG__\n"},
		},
	}
	_, err := Systemd(s, nil)
	if err == nil {
		t.Fatal("an undefined token must be a hard error")
	}
	if !strings.Contains(err.Error(), "__CONFIG__") {
		t.Errorf("error should name the missing token; got: %v", err)
	}
	if !strings.Contains(err.Error(), "__EXEC__") {
		t.Errorf("error should list what IS defined; got: %v", err)
	}
}

func TestSystemdNoUnitsIsUnavailableNotEmptySuccess(t *testing.T) {
	_, err := Systemd(spec.Spec{App: "x", Scope: spec.ScopeUser, ConfigHome: "/tmp/c"}, nil)
	if err == nil {
		t.Fatal("a payload with no units must report an unavailable target")
	}
	if !strings.Contains(err.Error(), "target unavailable") {
		t.Errorf("got: %v", err)
	}
}

func TestSystemdUninstallDisablesBeforeRemoving(t *testing.T) {
	p, err := SystemdUninstall(ghkLikeSpec(), nil)
	if err != nil {
		t.Fatalf("SystemdUninstall: %v", err)
	}
	if len(p.Instructions) == 0 {
		t.Fatal("uninstall should print disable commands")
	}
	joined := strings.Join(p.Instructions, "\n")
	svcAt := strings.Index(joined, "disable --now ghk.service")
	sockAt := strings.Index(joined, "disable --now ghk.socket")
	if svcAt < 0 || sockAt < 0 {
		t.Fatalf("missing disable commands:\n%s", joined)
	}
	if svcAt > sockAt {
		t.Errorf("the service should stop before its socket:\n%s", joined)
	}
	if len(p.Actions) == 0 {
		t.Error("uninstall should remove the unit files")
	}
}

// Digest is what golden tests compare first: the same Spec must render
// identically every time, or a "no change" refactor cannot be told from a
// silent behaviour change.
func TestRenderIsDeterministic(t *testing.T) {
	a, err := Systemd(ghkLikeSpec(), nil)
	if err != nil {
		t.Fatal(err)
	}
	b, err := Systemd(ghkLikeSpec(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if a.Digest() != b.Digest() {
		t.Errorf("render is not deterministic:\n%s\n%s", a.Digest(), b.Digest())
	}
}

func keysOf(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

func valuesOf(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for _, v := range m {
		out = append(out, v)
	}
	return out
}

func indexOfLine(lines []string, substr string) int {
	for i, l := range lines {
		if strings.Contains(l, substr) {
			return i
		}
	}
	return -1
}

func hasPath(paths []string, want string) bool {
	return slices.Contains(paths, want)
}
