package target

import (
	"errors"
	"strings"
	"testing"

	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

// fakeHelm records what it was asked to render and returns canned manifests,
// so the whole kubernetes path is testable with no helm binary and no cluster.
type fakeHelm struct {
	out      string
	err      error
	gotChart spec.Chart
	gotKube  spec.Kube
	calls    int
}

func (f *fakeHelm) Template(c spec.Chart, k spec.Kube) ([]byte, error) {
	f.calls++
	f.gotChart, f.gotKube = c, k
	if f.err != nil {
		return nil, f.err
	}
	return []byte(f.out), nil
}

func k8sSpec() spec.Spec {
	return spec.Spec{
		App: "ghk",
		Chart: &spec.Chart{
			Path:      "deploy/helm/ghk-observability",
			Release:   "ghk-obs",
			Namespace: "observability",
			Values:    []string{"values-prod.yaml"},
		},
		RenderTo: "out/render",
	}
}

func TestKubernetesRendersToDisk(t *testing.T) {
	fh := &fakeHelm{out: "apiVersion: v1\nkind: Namespace\n"}
	p, err := Kubernetes(k8sSpec(), fh)
	if err != nil {
		t.Fatalf("Kubernetes: %v", err)
	}
	if fh.calls != 1 {
		t.Errorf("expected one template call, got %d", fh.calls)
	}
	if !hasPath(p.Paths(), "out/render/ghk-obs.yaml") {
		t.Errorf("manifests should be written to the render dir; got %v", p.Paths())
	}
	var wrote bool
	for _, a := range p.Actions {
		if a.Kind == "write" && strings.Contains(string(a.Content), "kind: Namespace") {
			wrote = true
		}
	}
	if !wrote {
		t.Error("rendered manifest content was not written")
	}
}

// The kubeconfig is an ADDRESSING input: it must appear in the printed
// commands so the operator cannot apply to the wrong cluster by forgetting an
// environment variable.
func TestKubernetesKubeconfigIsInterpolatedIntoCommands(t *testing.T) {
	s := k8sSpec()
	s.Kube = spec.Kube{Kubeconfig: "/tmp/kubeconfig.dev", Context: "k3d-dev"}
	p, err := Kubernetes(s, &fakeHelm{out: "kind: Namespace\n"})
	if err != nil {
		t.Fatalf("Kubernetes: %v", err)
	}
	joined := strings.Join(p.Instructions, "\n")
	for _, want := range []string{
		"helm upgrade --install ghk-obs",
		"--kubeconfig /tmp/kubeconfig.dev",
		"--kube-context k3d-dev",
		"kubectl",
		"--context k3d-dev",
		"apply -f out/render",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("instructions should contain %q:\n%s", want, joined)
		}
	}
}

// Rendering must work with no cluster at all. Nothing in the offline path may
// require a kubeconfig.
func TestKubernetesRendersOfflineAndHintsAtK3d(t *testing.T) {
	fh := &fakeHelm{out: "kind: Namespace\n"}
	p, err := Kubernetes(k8sSpec(), fh)
	if err != nil {
		t.Fatalf("offline render must succeed: %v", err)
	}
	if fh.gotKube.Validate {
		t.Error("offline render must not ask helm to validate against a cluster")
	}
	joined := strings.Join(p.Instructions, "\n")
	if !strings.Contains(joined, "k3d cluster create") {
		t.Errorf("with no cluster addressed, print the k3d hint:\n%s", joined)
	}
	if !strings.HasPrefix(strings.TrimSpace(joined), "#") {
		t.Errorf("the k3d hint must be a comment, never a command to run:\n%s", joined)
	}
	if len(p.Notes) == 0 {
		t.Error("an unaddressed render should note which context the commands will hit")
	}
}

func TestKubernetesNoChartIsUnavailableNotEmptySuccess(t *testing.T) {
	_, err := Kubernetes(spec.Spec{App: "x"}, &fakeHelm{})
	if err == nil {
		t.Fatal("a build with no chart must report an unavailable target")
	}
	if !strings.Contains(err.Error(), "target unavailable") {
		t.Errorf("got: %v", err)
	}
}

func TestKubernetesEmptyRenderIsAnError(t *testing.T) {
	_, err := Kubernetes(k8sSpec(), &fakeHelm{out: ""})
	if err == nil || !strings.Contains(err.Error(), "no manifests") {
		t.Fatalf("an empty render must fail loudly; got %v", err)
	}
}

func TestKubernetesPropagatesHelmFailure(t *testing.T) {
	_, err := Kubernetes(k8sSpec(), &fakeHelm{err: errors.New("chart is broken")})
	if err == nil || !strings.Contains(err.Error(), "chart is broken") {
		t.Fatalf("helm's own error must survive; got %v", err)
	}
}
