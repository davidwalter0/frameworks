package target

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"

	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

// ExecHelm renders a chart with the real `helm` binary.
//
// This is the ONLY place in installkit that executes anything, and it runs
// exactly one subcommand: `helm template`, a local render. Activation verbs
// (`helm upgrade`, `kubectl apply`, `systemctl enable`) are produced as text
// by package instruct and are never executed here — that split is what makes
// the module's invariant mechanically checkable.
type ExecHelm struct {
	// Bin overrides the helm executable (tests, or a pinned path).
	Bin string
}

// Template runs `helm template` and returns the rendered manifests.
func (e ExecHelm) Template(c spec.Chart, k spec.Kube) ([]byte, error) {
	bin := e.Bin
	if bin == "" {
		bin = "helm"
	}
	if _, err := exec.LookPath(bin); err != nil {
		return nil, fmt.Errorf("helm not found on PATH: %w", err)
	}

	release := c.Release
	if release == "" {
		release = "release"
	}
	args := []string{"template", release, c.Path}
	if c.Namespace != "" {
		args = append(args, "--namespace", c.Namespace)
	}
	for _, v := range c.Values {
		args = append(args, "-f", v)
	}
	// Cluster contact happens only here, only on request, and only to read.
	if k.Validate {
		args = append(args, "--validate")
		if k.Kubeconfig != "" {
			args = append(args, "--kubeconfig", k.Kubeconfig)
		}
		if k.Context != "" {
			args = append(args, "--kube-context", k.Context)
		}
	}

	var stdout, stderr bytes.Buffer
	cmd := exec.Command(bin, args...)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, fmt.Errorf("helm %s: %s", strings.Join(args, " "), msg)
	}
	return stdout.Bytes(), nil
}
