package target

import (
	"fmt"
	"path/filepath"

	"github.com/davidwalter0/frameworks/go/pkg/instruct"
	"github.com/davidwalter0/frameworks/go/pkg/plan"
	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

// HelmRunner renders a chart to manifest bytes.
//
// It is an interface so Kubernetes() stays testable with no helm binary and no
// cluster. The production implementation (ExecHelm) shells out to
// `helm template`, which is a LOCAL render: it creates nothing, mutates
// nothing, and needs no cluster unless Kube.Validate asks for API discovery.
// That is categorically different from `helm upgrade --install`, which this
// module never runs — it only ever prints it (see package instruct).
type HelmRunner interface {
	Template(c spec.Chart, k spec.Kube) ([]byte, error)
}

// DefaultRenderDir is where manifests land when RenderTo is unset.
const DefaultRenderDir = "dist/render"

// Kubernetes renders the chart to a directory and prints the apply commands.
//
// The kubeconfig and context are ADDRESSING inputs: they name the cluster the
// output is rendered for, and they are interpolated into every printed
// command so the operator cannot apply to the wrong cluster by forgetting an
// environment variable. Nothing here contacts a cluster unless
// Kube.Validate is set, and even then only to read its API versions.
func Kubernetes(s spec.Spec, r HelmRunner) (plan.Plan, error) {
	p := plan.Plan{Target: "kubernetes"}

	if s.Chart == nil || s.Chart.Path == "" {
		// Never render nothing and exit 0: an unavailable target says so.
		return p, fmt.Errorf("target unavailable: this build embeds no chart")
	}
	if r == nil {
		return p, fmt.Errorf("no helm runner supplied")
	}
	c := *s.Chart
	if c.Release == "" {
		c.Release = s.App
	}

	manifests, err := r.Template(c, s.Kube)
	if err != nil {
		return p, fmt.Errorf("render chart %s: %w", c.Path, err)
	}
	if len(manifests) == 0 {
		return p, fmt.Errorf("chart %s rendered no manifests", c.Path)
	}

	dir := s.RenderTo
	if dir == "" {
		dir = DefaultRenderDir
	}
	out := filepath.Join(dir, c.Release+".yaml")

	p.Mkdir(dir, "rendered manifest directory")
	p.Write(out, manifests, 0o644,
		fmt.Sprintf("helm template %s (release %s)", c.Path, c.Release))

	if s.Kube.Kubeconfig == "" && s.Kube.Context == "" {
		p.Note("no --kubeconfig or --kube-context given: the render is offline and the " +
			"printed commands address whatever context is currently active.")
		p.Instruct(instruct.K3dHint(""))
	}
	p.Instruct(
		instruct.HelmUpgrade(c, s.Kube),
		"# ...or apply the rendered tree directly:",
		instruct.KubectlApply(dir, c, s.Kube),
	)
	return p, nil
}
