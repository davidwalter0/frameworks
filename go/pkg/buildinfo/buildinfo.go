// Package buildinfo reports Go build metadata sourced from
// runtime/debug.ReadBuildInfo, with no wrapper tool and no third-party
// dependencies. A plain `go build` stamps everything it needs: since Go 1.18
// the toolchain embeds VCS data (revision, commit time, dirty flag) and build
// settings (GOOS, GOARCH, -compiler, -race) automatically.
//
// ONE NARROW EXCEPTION, added 2026-08-24: injectedRevision / injectedCommitTime
// below may be set with -ldflags -X, and are consulted ONLY when Go embedded no
// vcs.* settings at all. This package previously advertised "no -ldflags -X
// injection" as an absolute; that stance was written on the belief that a
// module-download build simply could not carry a revision, which measurement
// refuted — the commit is in module metadata and go-version resolves it (see
// go-version's own pkg/tools/revision.go). The stance is narrowed rather than
// abandoned:
// injection never OVERRIDES what Go embedded, so a work-tree build is
// bit-identical in behaviour to before, and a binary built without the flags
// behaves exactly as it always did.
//
// This package is import-silent: importing it has no side effects, so it is
// safe to embed in a CLI or library. Call Read for the data, or Print / String
// / JSON to render it. Set NO_COLOR to disable the ANSI-colored labels emitted
// by Print.
//
// For the "print at startup just by importing" behavior, use the side-effect
// subpackage instead:
//
//	import _ "github.com/davidwalter0/frameworks/go/pkg/buildinfo/autoprint"
//
// Three fields are not present in Go's automatic build metadata and use weak
// substitutes:
//
//   - GitVersion (the VCS tag) falls back to the module version. Built inside
//     a VCS work tree, that is a pseudo-version derived from the nearest
//     ancestor tag, commit time, and revision (e.g.
//     v0.2.13-0.20260807143858-4921a47cdaa4), or the tag itself when HEAD is
//     exactly at a clean tag; it is "(devel)" only when Go has no VCS
//     information at all, e.g. `-buildvcs=false` or a source tree with no VCS
//     present. It is a real, verifiable vX.Y.Z (with a go.sum-style hash) when
//     the binary is produced by `go install <path>@<version>`.
//   - BuildDate (the compile time) uses the executable's mtime, because Go
//     embeds the commit time, not the build time.
//   - The build host's OS/ARCH is not recorded; only the target GOOS/GOARCH is
//     available (identical for a native, non-cross-compiled build).
//
// GitRevision and GitCommitDate are populated only when the main package is
// built from inside a VCS work tree — that is when Go embeds vcs.revision /
// vcs.time (since Go 1.18). `go install <mod>@<version>` builds from the
// module cache, never a work tree, so a binary produced that way carries a
// real semver in GitVersion but can never carry vcs.revision / vcs.time: the
// two are structurally mutually exclusive, not an occasional miss.
//
// Read that as a statement about Go's AUTOMATIC stamping only. The revision
// itself is not unobtainable — `go list -m -json <mod>@<version>` reports
// Origin.Hash (plus Ref and Time), it is persisted in the module cache's .info
// so it resolves with GOPROXY=off, and it is byte-equal to
// `git rev-parse <tag>^{commit}` (verified 2026-08-24). A builder can therefore
// inject it with -ldflags -X, which is exactly what this project already does
// for helm's and rclone's version strings. As of 2026-08-24 this package DOES
// accept that injection, through injectedRevision / injectedCommitTime and
// strictly as a gap-filler — see the narrow exception at the top and
// applyInjected's precedence rule.
//
// Note their absence does NOT correlate with whether GitVersion looks like a
// real tag: a local build sitting exactly on a clean tag has both a real
// GitVersion and a populated GitRevision, while `go install` of that identical
// tag has only the former. So GitVersion cannot be used to infer whether the
// revision fields should be present.
//
// Read() leaves the two fields genuinely empty in that case — the Info struct
// (and JSON/JSONString) always reflects exactly what Go embedded, with nothing
// synthesized mixed in, so a machine consumer never has to distinguish a real
// empty string from a rendered one. The human-facing renderers (String, Print,
// YAML, and the `version` command's one-line form) substitute an explicit
// marker instead of blank, "(not embedded: module-download build)", because an
// empty field there reads as "this project has no VCS" when the true state is
// "this build mode cannot carry one" — see notEmbeddedMarker and
// DisplayOrMarker.
//
// # Provenance, and why it lives here
//
// Lifted from go-version's pkg/buildinfo, which is itself the successor to
// github.com/davidwalter0/go-build/v2 and keeps that package's API as drop-in
// accessors (Get, Text, YAML, JSON) with one documented field rename,
// Revision -> GitRevision.
//
// It moved because the host was wrong, not the code: this is a general-purpose
// library that imports nothing outside the standard library, and its consumers
// were importing a Go TOOLCHAIN MANAGER in order to render `--version`. Same
// reasoning as D-0005, which made frameworks/go/pkg/installer canonical by
// absorbing installkit rather than leaving the library inside one of its
// callers.
//
// Three implementations of this package existed when the move was made:
// go-build/v2 (the original, 196 lines, whose own doc still presented itself
// as current and pointed at no successor), go-version's (this code), and
// autocfg's pkg/buildinfo (a third, independent API — Full/Short — used only
// inside autocfg and part of its published contract, so deliberately NOT
// folded in here).
package buildinfo

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"runtime"
	"runtime/debug"
	"time"
)

// dateLayout is the dotted timestamp format used in the printed output,
// e.g. 2024.03.29.17.38.09.-0400.
const dateLayout = "2006.01.02.15.04.05.-0700"

// notEmbeddedMarker explains an empty GitRevision/GitCommitDate in the
// human-facing renderers: `go install <mod>@<version>` builds from the
// module cache, not a VCS work tree, so Go embeds no vcs.revision / vcs.time
// at all — the field isn't missing by accident, this build mode structurally
// cannot carry one. An unexplained blank reads as "no VCS"; this marker says
// which of the two it actually is.
const notEmbeddedMarker = "(not embedded: module-download build)"

// DisplayOrMarker returns v, or notEmbeddedMarker when v is empty. It is the
// single definition of how an un-embedded GitRevision/GitCommitDate is shown
// to a human, used by this package's renderers (fields, YAML) and exported so
// a consumer's own one-line `version` output renders the same marker rather
// than a bare blank — go-version's `version` command is the original such
// caller. Read() and the raw Info struct (so JSON/JSONString too) keep the
// field genuinely empty; see the package doc.
//
// Exported rather than duplicated at the call site so the marker text has one
// home: a second copy in a consumer's cmd/ would drift from this one silently.
func DisplayOrMarker(v string) string {
	if v == "" {
		return notEmbeddedMarker
	}
	return v
}

// displayOrMarker is the unexported alias retained for this package's own
// renderers, which read more naturally unqualified.
func displayOrMarker(v string) string { return DisplayOrMarker(v) }

// Info is the set of build metadata fields reported by this package.
type Info struct {
	GitVersion    string `json:"version"`       // module version / VCS tag; pseudo-version or tag in a VCS build, "(devel)" only with no VCS info at all
	GitRevision   string `json:"revision"`      // VCS commit hash ("-dirty" suffix if modified); "" when Go had no VCS work tree at build time (renderers show a marker; see package doc)
	GitCommitDate string `json:"commit-date"`   // VCS commit time; "" under the same condition as GitRevision
	BuildDate     string `json:"build-date"`    // best-effort compile time (executable mtime)
	Arch          string `json:"arch"`          // target GOARCH
	OS            string `json:"os"`            // target GOOS
	Compiler      string `json:"compiler"`      // gc / gccgo
	RaceDetector  string `json:"race-detector"` // "true" / "false"
	GoVersion     string `json:"go-version"`    // toolchain version
}

// injectedRevision and injectedCommitTime are the -ldflags -X targets that let
// a module-download build carry the commit Go could not stamp. Both are empty
// in any ordinary build, including `go build` and `go test`.
//
// They are consulted ONLY when Go embedded no vcs.revision — never as an
// override — so:
//
//   - a work-tree build ignores them entirely, even if they were set;
//   - a binary built without them behaves exactly as before;
//   - the value can only ever FILL a gap, never contradict the toolchain.
//
// go-version sets them from module metadata via the {{.Revision}} /
// {{.CommitTime}} placeholders in its own family.json entry.
var (
	injectedRevision   string
	injectedCommitTime string
)

// Read assembles Info from the running binary's embedded build metadata. It
// never fails: fields Go does not embed fall back to runtime values, and
// GitRevision/GitCommitDate are left genuinely empty when no VCS work tree was
// visible at build time. The marker is applied by the display layer, not here
// — see DisplayOrMarker and the package doc.
func Read() Info {
	bi, ok := debug.ReadBuildInfo()
	return applyInjected(infoFromBuildInfo(bi, ok), injectedRevision, injectedCommitTime)
}

// applyInjected fills GitRevision/GitCommitDate from -X-injected values, and
// only where Go embedded nothing. Split out and pure so the precedence rule is
// testable without building two differently-linked binaries — the same reason
// infoFromBuildInfo is split from Read.
//
// Why this may go in the STRUCT when the not-embedded marker may not: the
// marker is PROSE, a sentence synthesized for a human, and putting it in JSON
// would make a consumer parse English to learn a field was absent. An injected
// revision is DATA — the real commit the module version was cut from, verified
// byte-equal to `git rev-parse <tag>^{commit}`. Reporting it is reporting the
// truth about the build, so it belongs in Info and in JSON alongside anything
// Go embeds itself.
//
// "unknown" is rejected explicitly: that is what the ldflags placeholder
// expands to when resolution failed, and treating it as a revision would turn
// a known-unknown into a confident wrong answer.
func applyInjected(info Info, rev, commitTime string) Info {
	if info.GitRevision == "" && rev != "" && rev != "unknown" {
		info.GitRevision = rev
	}
	if info.GitCommitDate == "" && commitTime != "" && commitTime != "unknown" {
		info.GitCommitDate = fmtTime(commitTime)
	}
	return info
}

// infoFromBuildInfo is Read's pure core, split out so tests can drive both
// the "VCS settings embedded" and "not embedded" states directly against a
// synthetic *debug.BuildInfo, rather than needing two differently-built test
// binaries to exercise a condition that is only decided at build time.
func infoFromBuildInfo(bi *debug.BuildInfo, ok bool) Info {
	info := Info{
		Arch:         runtime.GOARCH,
		OS:           runtime.GOOS,
		Compiler:     runtime.Compiler,
		RaceDetector: "false",
		GoVersion:    runtime.Version(),
	}

	if ok {
		if bi.GoVersion != "" {
			info.GoVersion = bi.GoVersion
		}
		info.GitVersion = bi.Main.Version

		s := make(map[string]string, len(bi.Settings))
		for _, kv := range bi.Settings {
			s[kv.Key] = kv.Value
		}
		if v := s["GOARCH"]; v != "" {
			info.Arch = v
		}
		if v := s["GOOS"]; v != "" {
			info.OS = v
		}
		if v := s["-compiler"]; v != "" {
			info.Compiler = v
		}
		if v := s["-race"]; v != "" {
			info.RaceDetector = v
		}
		if v := s["vcs.revision"]; v != "" {
			info.GitRevision = v
			if s["vcs.modified"] == "true" {
				info.GitRevision += "-dirty"
			}
		}
		if v := s["vcs.time"]; v != "" {
			info.GitCommitDate = fmtTime(v)
		}
	}

	info.BuildDate = execModTime()
	return info
}

// fields returns the ordered label/value pairs Print and String emit.
func (i Info) fields() [][2]string {
	return [][2]string{
		{"Git Version", i.GitVersion},
		{"Git Revision", displayOrMarker(i.GitRevision)},
		{"Git Commit Date", displayOrMarker(i.GitCommitDate)},
		{"Go Build Date", i.BuildDate},
		{"Go Arch", i.Arch},
		{"Go OS", i.OS},
		{"Go Compiler", i.Compiler},
		{"Go Race Detector", i.RaceDetector},
		{"Go Version", i.GoVersion},
	}
}

// String renders the build info as an aligned, uncolored multi-line block.
func (i Info) String() string {
	var b []byte
	for _, f := range i.fields() {
		b = append(b, fmt.Sprintf("%-16s : %s\n", f[0], f[1])...)
	}
	return string(b)
}

// Print writes the build info to w as an aligned block, with teal labels unless
// NO_COLOR is set.
//
// Write errors are discarded deliberately, not by oversight. Print carries no
// error return because it is part of the go-build/v2 drop-in surface this
// package preserves, and its only job is best-effort diagnostic output to a
// terminal or stderr. A caller that must know whether the bytes landed has two
// options that do report: JSON, which returns an error, or String, which hands
// back the text to write however the caller likes.
//
// (This discard was implicit until the package moved into frameworks, whose
// golangci-lint config runs errcheck; the original home's did not flag it.)
func Print(w io.Writer) {
	for _, f := range Read().fields() {
		_, _ = fmt.Fprintf(w, "%s : %s\n", teal(fmt.Sprintf("%-16s", f[0])), f[1])
	}
}

// JSON writes the build info to w as a single-line JSON object.
func JSON(w io.Writer) error {
	return json.NewEncoder(w).Encode(Read())
}

// The accessors below are drop-in equivalents for the API of
// github.com/davidwalter0/go-build/v2, so callers migrating to this package
// need minimal changes. The one field-name difference is Revision -> GitRevision
// (and the other Git*/Go* fields); see the Info struct.

// Get is an alias for Read, provided for go-build/v2 source compatibility.
func Get() Info { return Read() }

// Text returns the aligned, uncolored multi-line block (Read().String()).
func Text() string { return Read().String() }

// YAML returns the build info as a flat YAML mapping.
func YAML() string { return Read().YAML() }

// JSONString returns the build info as a single-line JSON object string. It is
// the string-returning companion to JSON, which writes to an io.Writer.
func JSONString() string {
	b, err := json.Marshal(Read())
	if err != nil {
		return "{}"
	}
	return string(b)
}

// YAML renders the receiver as a flat YAML mapping. The fields are flat strings,
// so the lines are hand-emitted (key: "value") and the package stays
// dependency-free. Keys mirror the JSON struct tags. Values are double-quoted,
// which is valid YAML and safe for the version/revision/date scalars.
func (i Info) YAML() string {
	pairs := [][2]string{
		{"version", i.GitVersion},
		{"revision", displayOrMarker(i.GitRevision)},
		{"commit-date", displayOrMarker(i.GitCommitDate)},
		{"build-date", i.BuildDate},
		{"arch", i.Arch},
		{"os", i.OS},
		{"compiler", i.Compiler},
		{"race-detector", i.RaceDetector},
		{"go-version", i.GoVersion},
	}
	var b []byte
	for _, p := range pairs {
		b = append(b, fmt.Sprintf("%s: %q\n", p[0], p[1])...)
	}
	return string(b)
}

// fmtTime reformats an RFC3339 timestamp (as embedded in vcs.time) into
// dateLayout, returning the input unchanged if it cannot be parsed and "" if
// empty.
func fmtTime(rfc3339 string) string {
	if rfc3339 == "" {
		return ""
	}
	if t, err := time.Parse(time.RFC3339, rfc3339); err == nil {
		return t.Format(dateLayout)
	}
	return rfc3339
}

// execModTime returns the running executable's modification time formatted in
// dateLayout, used as a best-effort build date ("" if it cannot be determined).
func execModTime() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	fi, err := os.Stat(exe)
	if err != nil {
		return ""
	}
	return fi.ModTime().Format(dateLayout)
}

// teal wraps s in an ANSI teal SGR sequence unless NO_COLOR is set.
func teal(s string) string {
	if os.Getenv("NO_COLOR") != "" {
		return s
	}
	return "\033[1;36m" + s + "\033[0m"
}
