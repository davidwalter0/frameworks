// Package cli is the adoption surface: an application's installer becomes a
// thin main that fills in a spec.Spec and calls Run.
//
// MIGRATED VERBATIM from installkit/pkg/cli, which was the one package of that
// module's six never brought across — `instruct`, `plan`, `receipt`, `spec` and
// `target` all moved, and D-0005 recorded installkit as retiring while 716
// lines of its option surface still had no home here. That was an overstatement
// in the decision record, not a completed migration.
//
// The gap it left was visible in consumers: what frameworks offered was
// [installer.RunFlags] — prefix, uninstall, version, three flags — so mountbridge
// hand-rolled --status/--restart/--repoint/--autostart/--daemon on top of it,
// and the systemd and kubernetes targets that pkg/target has always supported
// had no way to be reached from a command line at all.
//
// The port was an import rewrite and nothing else: every symbol it needs
// already existed here, and its thirteen tests pass unchanged against the
// MERGED spec.Spec (the one that absorbed the desktop half). Behaviour is
// therefore the installkit behaviour, verified rather than assumed.
//
// This is where the process environment is read — HOME, XDG_CONFIG_HOME, PATH
// — so that everything below it (target.Render, plan.Apply) stays a pure
// function of its inputs and is table-testable without touching a host.
package cli

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/davidwalter0/autocfg/pkg/flags"

	"github.com/davidwalter0/frameworks/go/pkg/plan"
	"github.com/davidwalter0/frameworks/go/pkg/receipt"
	"github.com/davidwalter0/frameworks/go/pkg/spec"
	"github.com/davidwalter0/frameworks/go/pkg/target"
)

// Env is the host state the installer depends on, injected so tests never
// read the real one.
type Env struct {
	Home       string
	ConfigHome string
	Path       string
	// StateHome is XDG_STATE_HOME (default ~/.local/state) — where the
	// install receipt lives, per the XDG convention for small host-local
	// state (the precedent is exttool/pkg/receipts).
	StateHome string
	// SystemIndexTheme is the content of the host's canonical hicolor
	// index.theme, empty when the host has none. See
	// spec.Spec.SystemIndexTheme for why the render wants it.
	SystemIndexTheme []byte
}

// systemHicolorIndexTheme is where every desktop distribution installs the
// canonical hicolor theme index.
const systemHicolorIndexTheme = "/usr/share/icons/hicolor/index.theme"

// OSEnv reads the real environment. This is the only impure edge.
func OSEnv() Env {
	home, _ := os.UserHomeDir()
	cfg := os.Getenv("XDG_CONFIG_HOME")
	if cfg == "" && home != "" {
		cfg = filepath.Join(home, ".config")
	}
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" && home != "" {
		state = filepath.Join(home, ".local", "state")
	}
	// A missing or unreadable system theme index is not an error — the
	// render synthesizes a minimal one; nil is the signal to do so.
	idx, _ := os.ReadFile(systemHicolorIndexTheme)
	return Env{Home: home, ConfigHome: cfg, Path: os.Getenv("PATH"),
		StateHome: state, SystemIndexTheme: idx}
}

// Options are the parsed flags. Flag names, shorthands and help text come
// from the tags (autocfg tagspec); a `flag:` tag appears only where the
// derived kebab-case name is not the documented flag. Slice flags are csv
// mode — `--target=filesystem,systemd` splits — matching the option surface
// this struct replaced. A --dropin path containing a comma would need
// `slice:"array"`; csv is kept because it is the pre-adoption behaviour.
type Options struct {
	Targets   []string `flag:"target" doc:"deployment target: filesystem, systemd, kubernetes (repeatable)"`
	Prefix    string   `doc:"install prefix (filesystem target)"`
	Uninstall bool     `doc:"remove a previous install and exit"`
	DryRun    bool     `doc:"print the plan and the commands; write nothing"`
	Version   bool     `short:"V" doc:"print version and exit"`

	Scope    string   `doc:"systemd scope: user or system"`
	Units    []string `flag:"unit" doc:"systemd unit kinds to install: service, socket, mount, timer (default: whatever the payload ships)"`
	UnitDir  string   `doc:"override the systemd unit directory"`
	Instance string   `doc:"instance name for a template unit (foo@INSTANCE.service)"`
	DropIns  []string `flag:"dropin" doc:"drop-in fragment as UNIT=FILE (repeatable)"`

	Chart      string   `doc:"chart directory (default: the embedded chart)"`
	Values     []string `doc:"helm values file (repeatable)"`
	Namespace  string   `doc:"kubernetes namespace"`
	Kubeconfig string   `doc:"kubeconfig the rendered output is addressed to"`
	Context    string   `flag:"kube-context" doc:"kube context the rendered output is addressed to"`
	Validate   bool     `doc:"ask helm to validate the render against the addressed cluster (read-only; requires a cluster)"`
	RenderTo   string   `flag:"render-to" doc:"directory for rendered manifests"`
}

// Run parses args, renders the requested targets, prints the plan, applies it
// unless --dry-run, and prints the activation commands.
//
// It never activates anything: the last thing it does is print commands for
// the operator to run (decision D-0004).
func Run(base spec.Spec, args []string, env Env, out io.Writer) error {
	// Defaults live here rather than in `default:` tags: Prefix depends on
	// the injected env, RenderTo and Scope reference package constants, and a
	// slice field's default: tag is not applied at all. flags.Register binds
	// each flag with the field's current value as its default, so these show
	// in --help exactly as tag defaults would.
	o := Options{
		Targets:  []string{"filesystem"},
		Prefix:   defaultPrefix(env),
		Scope:    string(spec.ScopeUser),
		RenderTo: target.DefaultRenderDir,
	}

	fs, err := flags.Register(nil, &o)
	if err != nil {
		return err
	}
	fs.SortFlags = false
	fs.SetOutput(out)
	// Register(nil, …) names the set "autocfg"; without this override --help
	// would print "Usage of autocfg:" instead of naming the application.
	fs.Usage = func() {
		// Usage is func() — it has no error channel, so a failed banner
		// write is best-effort by construction.
		_, _ = fmt.Fprintf(out, "Usage of %s installer:\n", base.App)
		_, _ = fmt.Fprint(out, fs.FlagUsages())
	}
	if err := fs.Parse(args); err != nil {
		return err
	}
	if o.Version {
		_, err := fmt.Fprintf(out, "%s installer %s\n", base.App, base.Version)
		return err
	}

	s, kinds, err := apply(base, o, env)
	if err != nil {
		return err
	}

	var plans []plan.Plan
	for _, name := range o.Targets {
		p, err := renderOne(strings.TrimSpace(name), s, kinds, o.Uninstall)
		if err != nil {
			return err
		}
		if o.Uninstall {
			// Reconcile against the receipt: a previous VERSION may have
			// recorded paths this render no longer knows about, and those
			// orphans are the reason the receipt exists (every replaced
			// installer uninstalled from a hardcoded list and left them).
			if err := addReceiptRemovals(&p, s, env); err != nil {
				return err
			}
		}
		plans = append(plans, p)
	}

	for _, p := range plans {
		results, err := emit(out, p, o.DryRun)
		if err != nil {
			return err
		}
		if !o.DryRun && !o.Uninstall && recordsReceipt(p.Target) {
			path, err := receipt.DefaultPath(env.StateHome, s.App, p.Target)
			if err != nil {
				// A host with no resolvable state home gets the install
				// without the record — degraded, and SAID, not an error:
				// failing the install over its own audit trail helps nobody.
				if _, werr := fmt.Fprintf(out,
					"\nNote: install receipt not recorded (%v); uninstall will rely on the rendered plan alone.\n",
					err); werr != nil {
					return werr
				}
				continue
			}
			r := receipt.Receipt{App: s.App, Version: s.Version, Target: p.Target,
				PlanDigest: p.Digest(), InstalledAt: time.Now().UTC(),
				Files: receipt.FromResults(results)}
			// A failed receipt is loud even though the install itself
			// landed: without it the NEXT uninstall is back to guessing.
			if err := receipt.Save(path, r); err != nil {
				return fmt.Errorf("install completed but the receipt could not be written: %w", err)
			}
			if _, err := fmt.Fprintf(out, "\nRecorded install receipt: %s\n", path); err != nil {
				return err
			}
		}
	}
	return nil
}

// recordsReceipt reports whether a target's Apply places files a receipt
// should track. The kubernetes target only renders manifests into a
// disposable directory — regenerable output, not an install — and refuses
// --uninstall anyway.
func recordsReceipt(target string) bool {
	return target == "filesystem" || target == "systemd"
}

// addReceiptRemovals appends removals for recorded orphans, then for the
// receipt file itself — as plan actions, so a dry run shows them.
func addReceiptRemovals(p *plan.Plan, s spec.Spec, env Env) error {
	path, err := receipt.DefaultPath(env.StateHome, s.App, p.Target)
	if err != nil || !recordsReceipt(p.Target) {
		// No state home (or a non-recording target): nothing recorded,
		// nothing to reconcile — the rendered plan stands alone.
		return nil
	}
	r, err := receipt.Load(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		// Pre-receipt install (or never installed): the rendered plan is
		// the best knowledge available. This fallback is what keeps the
		// migration safe for installs laid down before receipts existed.
		return nil
	case err != nil:
		return err
	}
	receipt.AppendRemovals(p, receipt.Orphans(r, *p))
	p.Remove(path, "install receipt (this uninstall consumes it)")
	p.Add(plan.Action{Kind: plan.KindRemove, Path: filepath.Dir(path),
		Guard: &plan.Guard{IfEmptyDir: filepath.Dir(path)},
		Note:  "receipt directory (removed only when empty)"})
	return nil
}

// apply folds the parsed flags into the application's base Spec.
func apply(base spec.Spec, o Options, env Env) (spec.Spec, []spec.UnitKind, error) {
	s := base
	s.Prefix = o.Prefix
	s.Home, s.ConfigHome, s.PathEnv = env.Home, env.ConfigHome, env.Path
	s.SystemIndexTheme = env.SystemIndexTheme
	s.UnitDir = o.UnitDir
	s.RenderTo = o.RenderTo

	scope, err := spec.ParseScope(o.Scope)
	if err != nil {
		return s, nil, err
	}
	s.Scope = scope

	var kinds []spec.UnitKind
	for _, u := range o.Units {
		k, err := spec.ParseUnitKind(strings.TrimSpace(u))
		if err != nil {
			return s, nil, err
		}
		kinds = append(kinds, k)
	}

	if o.Instance != "" {
		units := make([]spec.Unit, 0, len(s.Units))
		for _, u := range s.Units {
			// Only template-capable kinds take an instance; a .mount is named
			// after its mount point and has no instance to carry.
			if u.Kind != spec.KindMount {
				u.Instance = o.Instance
			}
			units = append(units, u)
		}
		s.Units = units
	}

	for _, d := range o.DropIns {
		unitName, file, ok := strings.Cut(d, "=")
		if !ok {
			return s, nil, fmt.Errorf("--dropin wants UNIT=FILE, got %q", d)
		}
		body, err := os.ReadFile(file)
		if err != nil {
			return s, nil, fmt.Errorf("--dropin %s: %w", d, err)
		}
		stem, _, _ := strings.Cut(unitName, ".")
		found := false
		for i := range s.Units {
			if s.Units[i].Stem != stem {
				continue
			}
			if s.Units[i].DropIns == nil {
				s.Units[i].DropIns = map[string]string{}
			}
			s.Units[i].DropIns[filepath.Base(file)] = string(body)
			found = true
		}
		if !found {
			return s, nil, fmt.Errorf("--dropin %s names no unit this payload ships", unitName)
		}
	}

	if o.Chart != "" || o.Namespace != "" || len(o.Values) > 0 {
		c := spec.Chart{}
		if s.Chart != nil {
			c = *s.Chart
		}
		if o.Chart != "" {
			c.Path = o.Chart
		}
		if o.Namespace != "" {
			c.Namespace = o.Namespace
		}
		if len(o.Values) > 0 {
			c.Values = o.Values
		}
		s.Chart = &c
	}
	s.Kube = spec.Kube{Kubeconfig: o.Kubeconfig, Context: o.Context, Validate: o.Validate}
	return s, kinds, nil
}

func renderOne(name string, s spec.Spec, kinds []spec.UnitKind, uninstall bool) (plan.Plan, error) {
	switch name {
	case "filesystem":
		if uninstall {
			return target.FilesystemUninstall(s)
		}
		return target.Filesystem(s)
	case "systemd":
		if uninstall {
			return target.SystemdUninstall(s, kinds)
		}
		return target.Systemd(s, kinds)
	case "kubernetes":
		if uninstall {
			return plan.Plan{}, fmt.Errorf(
				"--uninstall is not supported for the kubernetes target: this installer renders " +
					"manifests and never applied them, so it has nothing to withdraw.\n" +
					"  Remove the release yourself: helm uninstall <release>")
		}
		return target.Kubernetes(s, target.ExecHelm{})
	}
	return plan.Plan{}, fmt.Errorf("unknown target %q (want filesystem, systemd or kubernetes)", name)
}

// errWriter defers write-error handling to one place. A partially written
// report is still a report, but the error must not be dropped: an installer
// whose output is being piped somewhere full should say so rather than appear
// to have completed cleanly.
type errWriter struct {
	w   io.Writer
	err error
}

func (e *errWriter) printf(format string, a ...any) {
	if e.err != nil {
		return
	}
	_, e.err = fmt.Fprintf(e.w, format, a...)
}

// emit prints the plan, applies it unless this is a dry run, then prints the
// operator's commands last so they are the final thing on screen. It returns
// Apply's results so the caller can record a receipt of what actually landed.
func emit(out io.Writer, p plan.Plan, dryRun bool) ([]plan.Result, error) {
	e := &errWriter{w: out}

	verb := "Installing"
	if dryRun {
		verb = "Would install"
	}
	e.printf("\n== %s [%s]\n", verb, p.Target)
	for _, a := range p.Actions {
		note := ""
		if a.Note != "" {
			note = "   # " + a.Note
		}
		cond := ""
		if a.Guard != nil {
			// A dry run cannot evaluate guards (each depends on the actions
			// before it having run), so the condition itself is the output.
			cond = " [" + a.Guard.String() + "]"
		}
		e.printf("  %-8s %s%s%s\n", a.Kind, a.Path, cond, note)
	}

	results, err := plan.Apply(p, plan.Options{DryRun: dryRun})
	if err != nil {
		return results, err
	}
	for _, r := range results {
		if r.Skipped != "" {
			// A guard skip is an anticipated outcome, but a silent one would
			// make "did it write the theme index?" unanswerable after the fact.
			e.printf("  skipped  %s (%s)\n", r.Action.Path, r.Skipped)
		}
	}

	for _, n := range p.Notes {
		e.printf("\nNote: %s\n", n)
	}
	if len(p.Instructions) > 0 {
		e.printf("\nRun these to activate (this installer does not run them for you):\n")
		for _, i := range p.Instructions {
			e.printf("  %s\n", i)
		}
	}
	return results, e.err
}

func defaultPrefix(env Env) string {
	if env.Home == "" {
		return ".local"
	}
	return filepath.Join(env.Home, ".local")
}
