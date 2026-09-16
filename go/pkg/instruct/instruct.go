// Package instruct builds the command lines the OPERATOR runs after the
// installer has written its files.
//
// This package is deliberately the only place in installkit where the strings
// "systemctl", "helm upgrade" and "kubectl apply" appear, and it contains no
// exec path — it imports os/exec nowhere and formats text only. That is what
// makes the module's invariant checkable by a test rather than by reading
// every file:
//
//	The installer materializes artifacts and prints activation commands.
//	It never activates.
//
// Ordering is not cosmetic. Two rules are encoded here because getting them
// wrong is silent:
//
//   - A socket unit is enabled BEFORE the service is restarted, so systemd is
//     already holding the listeners; that is the entire reason ghk.socket
//     exists (a restart then leaves a client's connect() in the accept queue
//     instead of returning ECONNREFUSED).
//   - A timer's paired service is NEVER enabled. Enabling both makes the job
//     run at boot as well as on schedule, which looks like a scheduling bug
//     for as long as it takes to notice.
package instruct

import (
	"fmt"
	"sort"
	"strings"

	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

// Systemctl returns the systemctl invocation prefix for a scope, including
// the sudo the system manager needs and the user manager must not have.
func Systemctl(scope spec.Scope) string {
	if scope == spec.ScopeSystem {
		return "sudo systemctl"
	}
	return "systemctl --user"
}

// DaemonReload is the reload command for a scope.
func DaemonReload(scope spec.Scope) string {
	return Systemctl(scope) + " daemon-reload"
}

// UnitPlan is the minimum the instruction builder needs to know about one
// rendered unit: its final filename and its kind.
type UnitPlan struct {
	Name string // "ghk.socket", "mnt-data.mount"
	Kind spec.UnitKind
	Stem string // "ghk" — used to pair a timer with its service
}

// Activation returns the ordered command list for a set of rendered units.
//
// The returned slice is safe to print verbatim, in order.
func Activation(scope spec.Scope, units []UnitPlan) []string {
	if len(units) == 0 {
		return nil
	}
	sc := Systemctl(scope)
	out := []string{DaemonReload(scope)}

	// Stems that own a timer: their .service is schedule-driven and must not
	// be enabled directly.
	timerStems := map[string]bool{}
	for _, u := range units {
		if u.Kind == spec.KindTimer {
			timerStems[u.Stem] = true
		}
	}
	// Stems that own a socket: the service is socket-activated, so the socket
	// is enabled and the service is restarted rather than enabled first.
	socketStems := map[string]bool{}
	for _, u := range units {
		if u.Kind == spec.KindSocket {
			socketStems[u.Stem] = true
		}
	}

	// Sockets first — see the package comment.
	for _, u := range byKind(units, spec.KindSocket) {
		out = append(out, fmt.Sprintf("%s enable --now %s", sc, u.Name))
	}
	for _, u := range byKind(units, spec.KindMount) {
		out = append(out, fmt.Sprintf("%s enable --now %s", sc, u.Name))
	}
	for _, u := range byKind(units, spec.KindTimer) {
		out = append(out, fmt.Sprintf("%s enable --now %s", sc, u.Name))
	}
	for _, u := range byKind(units, spec.KindService) {
		switch {
		case timerStems[u.Stem]:
			out = append(out, fmt.Sprintf(
				"# %s is started by %s.timer — do NOT enable it directly", u.Name, u.Stem))
		case socketStems[u.Stem]:
			out = append(out, fmt.Sprintf("%s restart %s   # rebinds via the socket unit", sc, u.Name))
		default:
			out = append(out, fmt.Sprintf("%s enable --now %s", sc, u.Name))
		}
	}
	return out
}

// Deactivation returns the ordered command list to disable and forget units.
// Services stop before the sockets they were activated from.
func Deactivation(scope spec.Scope, units []UnitPlan) []string {
	if len(units) == 0 {
		return nil
	}
	sc := Systemctl(scope)
	var out []string
	for _, k := range []spec.UnitKind{spec.KindService, spec.KindTimer, spec.KindMount, spec.KindSocket} {
		for _, u := range byKind(units, k) {
			out = append(out, fmt.Sprintf("%s disable --now %s", sc, u.Name))
		}
	}
	out = append(out, DaemonReload(scope))
	return out
}

func byKind(units []UnitPlan, k spec.UnitKind) []UnitPlan {
	var out []UnitPlan
	for _, u := range units {
		if u.Kind == k {
			out = append(out, u)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// KubeFlags renders the cluster-addressing flags shared by helm and kubectl.
// They are interpolated into every printed command precisely so the operator
// cannot apply to the wrong cluster by forgetting KUBECONFIG.
func KubeFlags(k spec.Kube, kubectlStyle bool) string {
	var parts []string
	if k.Kubeconfig != "" {
		parts = append(parts, "--kubeconfig "+shellQuote(k.Kubeconfig))
	}
	if k.Context != "" {
		if kubectlStyle {
			parts = append(parts, "--context "+shellQuote(k.Context))
		} else {
			parts = append(parts, "--kube-context "+shellQuote(k.Context))
		}
	}
	return strings.Join(parts, " ")
}

// HelmUpgrade is the chart-install command for the operator to run.
func HelmUpgrade(c spec.Chart, k spec.Kube) string {
	b := &strings.Builder{}
	fmt.Fprintf(b, "helm upgrade --install %s %s", c.Release, shellQuote(c.Path))
	if f := KubeFlags(k, false); f != "" {
		fmt.Fprintf(b, " %s", f)
	}
	if c.Namespace != "" {
		fmt.Fprintf(b, " --namespace %s --create-namespace", shellQuote(c.Namespace))
	}
	for _, v := range c.Values {
		fmt.Fprintf(b, " -f %s", shellQuote(v))
	}
	return b.String()
}

// KubectlApply applies a rendered manifest directory.
func KubectlApply(dir string, c spec.Chart, k spec.Kube) string {
	b := &strings.Builder{}
	b.WriteString("kubectl")
	if f := KubeFlags(k, true); f != "" {
		fmt.Fprintf(b, " %s", f)
	}
	if c.Namespace != "" {
		fmt.Fprintf(b, " --namespace %s", shellQuote(c.Namespace))
	}
	fmt.Fprintf(b, " apply -f %s", shellQuote(dir))
	return b.String()
}

// K3dHint is printed when no cluster is addressed. It is a POINTER, never an
// action: cluster lifecycle is destructive and stays with the repo's own
// scripts (see decision D-0004).
func K3dHint(cluster string) string {
	if cluster == "" {
		cluster = "dev"
	}
	return fmt.Sprintf(
		"# no --kubeconfig/--kube-context given; to create a local cluster first: k3d cluster create %s",
		cluster)
}

// GtkUpdateIconCache is the icon-cache refresh for the OPERATOR to run after a
// desktop install.
//
// Added when frameworks absorbed this package (D-0005). frameworks' installer
// used to exec `gtk-update-icon-cache` itself, which was its single violation
// of D-0004's invariant — materialize artifacts and PRINT activation commands,
// never activate. Moving the string here keeps this package the only place such
// commands are spelled, which is what makes the invariant checkable by
// TestExactlyOneExecPath rather than by reading every file.
//
// Losing the automatic refresh is not much of a regression: the call was
// already best-effort (a missing binary was silently fine), desktops generally
// pick a new icon up at the next login regardless, and an operator who wants it
// immediately now gets an exact command instead of a silent no-op.
func GtkUpdateIconCache(theme string) string {
	return fmt.Sprintf("gtk-update-icon-cache -f -t %s", shellQuote(theme))
}

// shellQuote single-quotes a value when it contains anything a shell would
// interpret, so a path with a space survives copy-paste.
func shellQuote(s string) string {
	if s == "" {
		return "''"
	}
	if strings.IndexFunc(s, func(r rune) bool { return !shellSafe(r) }) < 0 {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// shellSafe reports whether a rune can appear unquoted in a command line the
// operator will copy and paste.
func shellSafe(r rune) bool {
	switch {
	case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		return true
	}
	return r == '/' || r == '.' || r == '-' || r == '_' || r == ':' || r == '@'
}
