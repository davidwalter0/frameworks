package deps

import (
	"fmt"
	"io"
	"sort"
)

// Outcome is what happened to one prerequisite.
type Outcome string

const (
	// Present: the tool is on PATH. Nothing to say.
	Present Outcome = "present"

	// Failed: a Required tool is absent. This is the only outcome that fails
	// the gate.
	Failed Outcome = "failed"

	// Skipped: an OptionalSkip tool is absent. Reported, never silent.
	Skipped Outcome = "skipped"

	// Degraded: an OptionalDegrade tool is absent and its fallback will be
	// used. Reported LOUDLY — this is the case the census found happening
	// invisibly.
	Degraded Outcome = "degraded"

	// Ignored: a BestEffort tool is absent and that is genuinely fine.
	Ignored Outcome = "ignored"
)

// Result is one tool's evaluation.
type Result struct {
	Tool    Tool
	Outcome Outcome
}

// Report is the whole evaluation.
type Report struct {
	Profile string
	Results []Result
}

// Exit codes. They are DISTINCT on purpose: a missing prerequisite, a broken
// manifest, and whatever the caller does afterwards are three different
// conditions, and collapsing them is how a failure gets attributed to the wrong
// cause. Same discipline as ui/tools/osv-gate.sh, where tool-absence has its
// own branch precisely so it cannot be mistaken for a real finding.
const (
	// ExitOK: every prerequisite is satisfied or acceptably absent.
	ExitOK = 0

	// ExitUnsatisfied: at least one Required tool is missing.
	ExitUnsatisfied = 1

	// ExitManifest: the manifest itself could not be read or is invalid. NOT a
	// prerequisite failure — the check never ran, which is a different thing
	// from the check failing.
	ExitManifest = 2
)

// Verify evaluates every prerequisite in the profile against probe.
func Verify(m Manifest, profile string, probe Probe) Report {
	rep := Report{Profile: profile}
	for _, t := range m.Requires {
		if !t.InProfile(profile) {
			continue
		}
		rep.Results = append(rep.Results, Result{Tool: t, Outcome: evaluate(t, probe)})
	}
	return rep
}

func evaluate(t Tool, probe Probe) Outcome {
	if probe(t.Name) {
		return Present
	}
	switch t.Policy {
	case Required:
		return Failed
	case OptionalSkip:
		return Skipped
	case OptionalDegrade:
		return Degraded
	case BestEffort:
		return Ignored
	default:
		// Validate rejects this before Verify runs; treating an unknown policy
		// as a failure rather than a pass keeps the fail-closed direction if it
		// ever slips through.
		return Failed
	}
}

// Unsatisfied returns the tools that failed the gate.
func (r Report) Unsatisfied() []Result {
	var out []Result
	for _, res := range r.Results {
		if res.Outcome == Failed {
			out = append(out, res)
		}
	}
	return out
}

// ExitCode is the process status for this report.
func (r Report) ExitCode() int {
	if len(r.Unsatisfied()) > 0 {
		return ExitUnsatisfied
	}
	return ExitOK
}

// Write renders the report. Everything that is not Present is surfaced —
// including skips and degradations, because an unreported skip is
// indistinguishable from an ignored one, and a silent degradation is the exact
// defect this package exists to end.
//
// Present tools are listed only in verbose mode: a wall of green obscures the
// two lines that matter.
func (r Report) Write(w io.Writer, verbose bool) {
	// p swallows the write error deliberately, and this is the documented
	// exception to the no-silent-discard rule. Write reports on a report; if
	// the destination is broken there is nowhere left to say so, and returning
	// an error here would force every caller to handle a failure it cannot act
	// on. The real outcome travels in ExitCode, not in these bytes.
	p := func(format string, a ...any) { _, _ = fmt.Fprintf(w, format, a...) }

	var present, notable []Result
	for _, res := range r.Results {
		if res.Outcome == Present {
			present = append(present, res)
		} else {
			notable = append(notable, res)
		}
	}
	sort.SliceStable(notable, func(i, j int) bool {
		return rank(notable[i].Outcome) < rank(notable[j].Outcome)
	})

	if verbose {
		for _, res := range present {
			p("  ok       %s\n", res.Tool.Name)
		}
	}

	for _, res := range notable {
		t := res.Tool
		switch res.Outcome {
		case Failed:
			p("  MISSING  %s — %s\n", t.Name, t.Why)
			if t.Install != "" {
				p("           install: %s\n", t.Install)
			}
		case Degraded:
			p("  DEGRADED %s absent — falling back to %s\n", t.Name, t.DegradeTo)
			p("           %s\n", t.Why)
			p("           this gate is now weaker than it claims; install %s to restore it\n", t.Name)
		case Skipped:
			p("  skipped  %s absent — not run\n", t.Name)
			p("           %s\n", t.Why)
		case Ignored:
			p("  note     %s absent — %s\n", t.Name, t.Why)
		}
	}

	if n := len(r.Unsatisfied()); n > 0 {
		p("\ndeps: %d required prerequisite(s) missing. FAIL\n", n)
		return
	}
	if len(notable) > 0 {
		p("\ndeps: all required prerequisites present. PASS\n")
		return
	}
	p("deps: all prerequisites present. PASS\n")
}

func rank(o Outcome) int {
	switch o {
	case Failed:
		return 0
	case Degraded:
		return 1
	case Skipped:
		return 2
	default:
		return 3
	}
}
