package instruct

import (
	"strings"
	"testing"

	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

func TestSystemctlPrefixBySc0pe(t *testing.T) {
	if got := Systemctl(spec.ScopeUser); got != "systemctl --user" {
		t.Errorf("user scope = %q", got)
	}
	// The system manager needs sudo; the user manager must never get it.
	if got := Systemctl(spec.ScopeSystem); got != "sudo systemctl" {
		t.Errorf("system scope = %q", got)
	}
	if strings.Contains(Systemctl(spec.ScopeUser), "sudo") {
		t.Error("user-scope commands must not use sudo")
	}
}

func TestActivationOrdersSocketBeforeService(t *testing.T) {
	units := []UnitPlan{
		{Name: "ghk.service", Kind: spec.KindService, Stem: "ghk"},
		{Name: "ghk.socket", Kind: spec.KindSocket, Stem: "ghk"},
	}
	got := Activation(spec.ScopeUser, units)
	joined := strings.Join(got, "\n")

	if got[0] != "systemctl --user daemon-reload" {
		t.Errorf("daemon-reload must be first, got %q", got[0])
	}
	sock := indexContaining(got, "enable --now ghk.socket")
	svc := indexContaining(got, "restart ghk.service")
	if sock < 0 || svc < 0 {
		t.Fatalf("missing commands:\n%s", joined)
	}
	if sock > svc {
		t.Errorf("socket must be enabled before the service restart:\n%s", joined)
	}
}

func TestActivationNeverEnablesATimersService(t *testing.T) {
	units := []UnitPlan{
		{Name: "sweep.service", Kind: spec.KindService, Stem: "sweep"},
		{Name: "sweep.timer", Kind: spec.KindTimer, Stem: "sweep"},
	}
	joined := strings.Join(Activation(spec.ScopeSystem, units), "\n")
	if !strings.Contains(joined, "enable --now sweep.timer") {
		t.Errorf("timer must be enabled:\n%s", joined)
	}
	if strings.Contains(joined, "enable --now sweep.service") {
		t.Errorf("the timer's service must not be enabled:\n%s", joined)
	}
}

// A service with neither a socket nor a timer is the ordinary case and is
// simply enabled — the special cases must not swallow it.
func TestActivationPlainServiceIsEnabled(t *testing.T) {
	units := []UnitPlan{{Name: "lb.service", Kind: spec.KindService, Stem: "lb"}}
	joined := strings.Join(Activation(spec.ScopeUser, units), "\n")
	if !strings.Contains(joined, "systemctl --user enable --now lb.service") {
		t.Errorf("plain service should be enabled:\n%s", joined)
	}
}

func TestActivationEmptyForNoUnits(t *testing.T) {
	if got := Activation(spec.ScopeUser, nil); got != nil {
		t.Errorf("no units should produce no commands, got %v", got)
	}
}

// Stopping a service before its socket matters: disabling the socket first
// leaves the service holding descriptors systemd no longer manages.
func TestDeactivationStopsServiceBeforeSocket(t *testing.T) {
	units := []UnitPlan{
		{Name: "ghk.socket", Kind: spec.KindSocket, Stem: "ghk"},
		{Name: "ghk.service", Kind: spec.KindService, Stem: "ghk"},
	}
	joined := strings.Join(Deactivation(spec.ScopeUser, units), "\n")
	svc := strings.Index(joined, "disable --now ghk.service")
	sock := strings.Index(joined, "disable --now ghk.socket")
	if svc < 0 || sock < 0 {
		t.Fatalf("missing disable commands:\n%s", joined)
	}
	if svc > sock {
		t.Errorf("service must stop before its socket:\n%s", joined)
	}
}

func TestKubeFlagsDialectDiffers(t *testing.T) {
	k := spec.Kube{Kubeconfig: "/tmp/kc", Context: "k3d-dev"}
	// helm says --kube-context; kubectl says --context. Emitting the wrong
	// one is a command the operator has to fix by hand.
	if got := KubeFlags(k, false); !strings.Contains(got, "--kube-context k3d-dev") {
		t.Errorf("helm dialect = %q", got)
	}
	if got := KubeFlags(k, true); !strings.Contains(got, "--context k3d-dev") ||
		strings.Contains(got, "--kube-context") {
		t.Errorf("kubectl dialect = %q", got)
	}
	if got := KubeFlags(spec.Kube{}, true); got != "" {
		t.Errorf("no addressing should add no flags, got %q", got)
	}
}

// A path with a space must survive copy-paste into a shell.
func TestQuotingSurvivesSpaces(t *testing.T) {
	k := spec.Kube{Kubeconfig: "/tmp/my configs/kc"}
	got := KubeFlags(k, false)
	if !strings.Contains(got, `'/tmp/my configs/kc'`) {
		t.Errorf("path with a space must be quoted, got %q", got)
	}
}

func TestHelmUpgradeCarriesEverything(t *testing.T) {
	c := spec.Chart{Path: "deploy/helm/x", Release: "rel", Namespace: "ns", Values: []string{"a.yaml", "b.yaml"}}
	got := HelmUpgrade(c, spec.Kube{Kubeconfig: "/tmp/kc"})
	for _, want := range []string{
		"helm upgrade --install rel deploy/helm/x",
		"--kubeconfig /tmp/kc",
		"--namespace ns --create-namespace",
		"-f a.yaml", "-f b.yaml",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in %q", want, got)
		}
	}
}

func TestK3dHintIsAlwaysAComment(t *testing.T) {
	// Cluster lifecycle is out of scope by decision; the hint is a pointer,
	// never something that could be pasted and run by accident mid-script.
	for _, name := range []string{"", "dev", "ci"} {
		if got := K3dHint(name); !strings.HasPrefix(got, "#") {
			t.Errorf("K3dHint(%q) = %q, must be a comment", name, got)
		}
	}
}

func indexContaining(lines []string, substr string) int {
	for i, l := range lines {
		if strings.Contains(l, substr) {
			return i
		}
	}
	return -1
}
