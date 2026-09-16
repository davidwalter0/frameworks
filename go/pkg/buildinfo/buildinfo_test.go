package buildinfo

import (
	"encoding/json"
	"runtime/debug"
	"strings"
	"testing"
)

func TestFmtTime(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{"empty", "", ""},
		{"utc-z", "2024-03-29T21:38:09Z", "2024.03.29.21.38.09.+0000"},
		{"negative-offset", "2024-03-29T17:38:09-04:00", "2024.03.29.17.38.09.-0400"},
		{"unparseable passthrough", "not-a-timestamp", "not-a-timestamp"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := fmtTime(tt.in); got != tt.want {
				t.Errorf("fmtTime(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}

func TestReadPopulatesRuntimeFields(t *testing.T) {
	got := Read()
	if got.GoVersion == "" {
		t.Error("Read().GoVersion is empty; expected a toolchain version")
	}
	if got.Arch == "" || got.OS == "" {
		t.Errorf("Read() target arch/os empty: arch=%q os=%q", got.Arch, got.OS)
	}
	if got.Compiler == "" {
		t.Error("Read().Compiler is empty")
	}
	// RaceDetector must always be one of the two literals, never blank.
	if got.RaceDetector != "true" && got.RaceDetector != "false" {
		t.Errorf("Read().RaceDetector = %q, want \"true\" or \"false\"", got.RaceDetector)
	}
	// What a human is shown for GitRevision/GitCommitDate must never be a bare
	// blank (see notEmbeddedMarker) — regardless of which branch Read() takes.
	//
	// This is deliberately NOT asserting "must be a real revision, not the
	// marker": verified 2026-08-08, `go test`'s default -buildvcs=auto does
	// NOT stamp VCS info into the compiled test binary even from inside this
	// repo's own (non-worktree) checkout, because go test's synthesized
	// _testmain package is built outside the repository, which fails the
	// documented auto-mode heuristic ("the main package, the main module
	// containing it, and the current directory" must all be in the same
	// repository — `go help build`). Forcing `go test -buildvcs=true`
	// confirmed VCS data is available and gets embedded when asked; the gate
	// is that "auto" declines, not that Go can't see the repo. So this test
	// binary itself legitimately hits the notEmbeddedMarker branch under a
	// plain `go test` / `make test` run, and asserting otherwise would be
	// asserting a false premise about the ambient test invocation rather than
	// about Read()'s correctness.
	// The raw struct field is ALLOWED to be empty — Info reports exactly what
	// Go embedded, so a machine consumer never has to tell a real empty string
	// from a rendered one. The invariant is at the display layer: what a human
	// is shown must never be a bare blank.
	if DisplayOrMarker(got.GitRevision) == "" {
		t.Error("DisplayOrMarker(GitRevision) is blank; want a hash or notEmbeddedMarker")
	}
	if DisplayOrMarker(got.GitCommitDate) == "" {
		t.Error("DisplayOrMarker(GitCommitDate) is blank; want a timestamp or notEmbeddedMarker")
	}
	if got.GitRevision == "" && DisplayOrMarker(got.GitRevision) != notEmbeddedMarker {
		t.Errorf("empty GitRevision rendered as %q, want notEmbeddedMarker",
			DisplayOrMarker(got.GitRevision))
	}
}

// TestInfoFromBuildInfoVCSPresence is the load-bearing test for remedy (a):
// GitRevision/GitCommitDate must RENDER notEmbeddedMarker, never a bare blank,
// whenever Go had no VCS work tree at build time — while the raw struct field
// stays empty in that state, so JSON consumers see what Go actually embedded
// rather than a synthesized sentence. It must render
// the real values whenever it did, regardless of what GitVersion looks like
// (a real tag and a populated GitRevision are NOT mutually exclusive; see the
// "clean build sitting exactly on a tag" case below). Drives the pure core
// directly against a synthetic *debug.BuildInfo so both states are exercised
// deterministically, without needing two differently-built test binaries.
func TestInfoFromBuildInfoVCSPresence(t *testing.T) {
	tests := []struct {
		name           string
		bi             *debug.BuildInfo
		ok             bool
		wantGitVersion string
		wantRevision   string
		wantCommitDate string
	}{
		{
			name: "vcs settings present, clean, untagged commit (pseudo-version)",
			bi: &debug.BuildInfo{
				Main: debug.Module{Version: "v0.2.13-0.20260807143858-4921a47cdaa4"},
				Settings: []debug.BuildSetting{
					{Key: "vcs", Value: "git"},
					{Key: "vcs.revision", Value: "4921a47cdaa40eaad254e54972f89467e7e57b17"},
					{Key: "vcs.time", Value: "2026-08-07T14:38:58Z"},
					{Key: "vcs.modified", Value: "false"},
				},
			},
			ok:             true,
			wantGitVersion: "v0.2.13-0.20260807143858-4921a47cdaa4",
			wantRevision:   "4921a47cdaa40eaad254e54972f89467e7e57b17",
			wantCommitDate: "2026.08.07.14.38.58.+0000",
		},
		{
			name: "vcs settings present, dirty tree",
			bi: &debug.BuildInfo{
				Main: debug.Module{Version: "v0.2.13-0.20260807143858-4921a47cdaa4"},
				Settings: []debug.BuildSetting{
					{Key: "vcs", Value: "git"},
					{Key: "vcs.revision", Value: "4921a47cdaa40eaad254e54972f89467e7e57b17"},
					{Key: "vcs.time", Value: "2026-08-07T14:38:58Z"},
					{Key: "vcs.modified", Value: "true"},
				},
			},
			ok:             true,
			wantGitVersion: "v0.2.13-0.20260807143858-4921a47cdaa4",
			wantRevision:   "4921a47cdaa40eaad254e54972f89467e7e57b17-dirty",
			wantCommitDate: "2026.08.07.14.38.58.+0000",
		},
		{
			// Verified 2026-08-08: a local build exactly on a clean tag stamps
			// the tag itself as GitVersion while ALSO embedding vcs.revision —
			// so a real semver GitVersion does not imply an empty GitRevision.
			name: "vcs settings present, clean, exactly at a tag",
			bi: &debug.BuildInfo{
				Main: debug.Module{Version: "v0.2.13"},
				Settings: []debug.BuildSetting{
					{Key: "vcs", Value: "git"},
					{Key: "vcs.revision", Value: "9abb0b651bee5f2d016d37a1bd029d4e1eb7f97f"},
					{Key: "vcs.time", Value: "2026-08-07T19:30:06Z"},
					{Key: "vcs.modified", Value: "false"},
				},
			},
			ok:             true,
			wantGitVersion: "v0.2.13",
			wantRevision:   "9abb0b651bee5f2d016d37a1bd029d4e1eb7f97f",
			wantCommitDate: "2026.08.07.19.30.06.+0000",
		},
		{
			// The module-download build case: `go install pkg@version` builds
			// from the module cache, so BuildInfo carries a real tagged
			// version and a go.sum hash, but zero vcs.* settings.
			name: "vcs settings absent (module-download build)",
			bi: &debug.BuildInfo{
				Main: debug.Module{
					Version: "v0.2.13",
					Sum:     "h1:E/XGXVOwFudFzp6TGc58pYgt8u3yAbtUWjub2hLxfcY=",
				},
				Settings: []debug.BuildSetting{
					{Key: "GOARCH", Value: "amd64"},
					{Key: "GOOS", Value: "linux"},
				},
			},
			ok:             true,
			wantGitVersion: "v0.2.13",
			wantRevision:   "",
			wantCommitDate: "",
		},
		{
			// -buildvcs=false: VCS stamping explicitly disabled, GitVersion
			// falls all the way back to "(devel)".
			name: "vcs settings absent (-buildvcs=false)",
			bi: &debug.BuildInfo{
				Main:     debug.Module{Version: "(devel)"},
				Settings: []debug.BuildSetting{{Key: "GOARCH", Value: "amd64"}},
			},
			ok:             true,
			wantGitVersion: "(devel)",
			wantRevision:   "",
			wantCommitDate: "",
		},
		{
			name:           "ReadBuildInfo itself failed",
			bi:             nil,
			ok:             false,
			wantGitVersion: "",
			wantRevision:   "",
			wantCommitDate: "",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := infoFromBuildInfo(tt.bi, tt.ok)

			// The regression this test exists to catch: what a HUMAN is shown
			// must never be a bare blank, in ANY state. The raw field may be
			// empty (that is the design — Info mirrors what Go embedded); the
			// display layer is where the guarantee lives.
			if DisplayOrMarker(got.GitRevision) == "" {
				t.Fatal("rendered GitRevision regressed to a bare blank")
			}
			if DisplayOrMarker(got.GitCommitDate) == "" {
				t.Fatal("rendered GitCommitDate regressed to a bare blank")
			}
			if tt.wantRevision == "" && DisplayOrMarker(got.GitRevision) != notEmbeddedMarker {
				t.Errorf("un-embedded GitRevision rendered as %q, want notEmbeddedMarker",
					DisplayOrMarker(got.GitRevision))
			}

			if got.GitVersion != tt.wantGitVersion {
				t.Errorf("GitVersion = %q, want %q", got.GitVersion, tt.wantGitVersion)
			}
			if got.GitRevision != tt.wantRevision {
				t.Errorf("GitRevision = %q, want %q", got.GitRevision, tt.wantRevision)
			}
			if got.GitCommitDate != tt.wantCommitDate {
				t.Errorf("GitCommitDate = %q, want %q", got.GitCommitDate, tt.wantCommitDate)
			}
		})
	}
}

func TestTeal(t *testing.T) {
	t.Run("NO_COLOR disables", func(t *testing.T) {
		t.Setenv("NO_COLOR", "1")
		if got := teal("label"); got != "label" {
			t.Errorf("teal with NO_COLOR = %q, want plain %q", got, "label")
		}
	})
	t.Run("colored by default", func(t *testing.T) {
		t.Setenv("NO_COLOR", "")
		got := teal("label")
		if !strings.Contains(got, "label") || !strings.Contains(got, "\033[") {
			t.Errorf("teal without NO_COLOR = %q, want ANSI-wrapped label", got)
		}
	})
}

func TestStringAlignedAndComplete(t *testing.T) {
	out := Read().String()
	for _, label := range []string{
		"Git Version", "Git Revision", "Git Commit Date", "Go Build Date",
		"Go Arch", "Go OS", "Go Compiler", "Go Race Detector", "Go Version",
	} {
		if !strings.Contains(out, label) {
			t.Errorf("String() missing label %q\n%s", label, out)
		}
	}
}

// TestDisplayOrMarker covers the helper in isolation.
func TestDisplayOrMarker(t *testing.T) {
	if got := displayOrMarker(""); got != notEmbeddedMarker {
		t.Errorf("displayOrMarker(\"\") = %q, want %q", got, notEmbeddedMarker)
	}
	if got := displayOrMarker("d6ea4e62abcd"); got != "d6ea4e62abcd" {
		t.Errorf("displayOrMarker(non-empty) = %q, want passthrough", got)
	}
}

// TestNotEmbeddedMarker is the required positive/negative pair: an Info WITH
// vcs.revision/vcs.time populated (simulating a local, in-work-tree build)
// must never show the marker; an Info WITHOUT them (simulating
// `go install <mod>@<version>`, which builds from the module cache and so
// never carries vcs.revision/vcs.time — see the package doc) must show it in
// every human-facing renderer, and must NOT show it in the raw struct or in
// JSON, which stay exactly what Read() produced.
func TestNotEmbeddedMarker(t *testing.T) {
	withVCS := Info{
		GitVersion:    "v0.0.0-20260804120754-d6ea4e62abcd",
		GitRevision:   "d6ea4e62abcd1234567890",
		GitCommitDate: "2026.08.04.12.07.54.-0400",
		BuildDate:     "2026.08.04.12.07.54.-0400",
		Arch:          "amd64",
		OS:            "linux",
		Compiler:      "gc",
		RaceDetector:  "false",
		GoVersion:     "go1.26.5",
	}
	// A module-download install (`go install <mod>@v0.0.10`): a real semver
	// in GitVersion, but Go embeds no vcs.* settings at all.
	withoutVCS := withVCS
	withoutVCS.GitVersion = "v0.0.10"
	withoutVCS.GitRevision = ""
	withoutVCS.GitCommitDate = ""

	t.Run("String: marker only without vcs data", func(t *testing.T) {
		if strings.Contains(withVCS.String(), notEmbeddedMarker) {
			t.Errorf("String() with vcs data unexpectedly carries the marker:\n%s", withVCS.String())
		}
		if !strings.Contains(withoutVCS.String(), notEmbeddedMarker) {
			t.Errorf("String() without vcs data is missing the marker:\n%s", withoutVCS.String())
		}
	})

	t.Run("YAML: marker only without vcs data", func(t *testing.T) {
		if strings.Contains(withVCS.YAML(), notEmbeddedMarker) {
			t.Errorf("YAML() with vcs data unexpectedly carries the marker:\n%s", withVCS.YAML())
		}
		if !strings.Contains(withoutVCS.YAML(), notEmbeddedMarker) {
			t.Errorf("YAML() without vcs data is missing the marker:\n%s", withoutVCS.YAML())
		}
	})

	t.Run("raw Info fields stay genuinely empty, not synthesized", func(t *testing.T) {
		if withoutVCS.GitRevision != "" {
			t.Errorf("raw GitRevision = %q, want empty (marker belongs to the display layer only)", withoutVCS.GitRevision)
		}
		if withoutVCS.GitCommitDate != "" {
			t.Errorf("raw GitCommitDate = %q, want empty (marker belongs to the display layer only)", withoutVCS.GitCommitDate)
		}
	})

	t.Run("JSON stays raw, no marker leaks into machine-readable output", func(t *testing.T) {
		b, err := json.Marshal(withoutVCS)
		if err != nil {
			t.Fatalf("json.Marshal: %v", err)
		}
		var m map[string]any
		if err := json.Unmarshal(b, &m); err != nil {
			t.Fatalf("json.Unmarshal: %v", err)
		}
		if m["revision"] != "" {
			t.Errorf(`JSON "revision" = %v, want "" (raw data, no marker)`, m["revision"])
		}
		if m["commit-date"] != "" {
			t.Errorf(`JSON "commit-date" = %v, want "" (raw data, no marker)`, m["commit-date"])
		}
	})
}

// TestCompatAccessors covers the go-build/v2 drop-in accessors.
func TestCompatAccessors(t *testing.T) {
	t.Run("Get aliases Read", func(t *testing.T) {
		if Get() != Read() {
			t.Error("Get() != Read()")
		}
	})
	t.Run("Text equals String", func(t *testing.T) {
		if Text() != Read().String() {
			t.Error("Text() != Read().String()")
		}
	})
	t.Run("YAML has keys", func(t *testing.T) {
		out := YAML()
		for _, k := range []string{"version:", "revision:", "go-version:"} {
			if !strings.Contains(out, k) {
				t.Errorf("YAML() missing key %q\n%s", k, out)
			}
		}
	})
	t.Run("JSONString is valid JSON", func(t *testing.T) {
		var m map[string]any
		if err := json.Unmarshal([]byte(JSONString()), &m); err != nil {
			t.Fatalf("JSONString() not valid JSON: %v", err)
		}
		if _, ok := m["go-version"]; !ok {
			t.Errorf("JSONString() missing go-version key: %v", m)
		}
	})
}

// TestApplyInjectedPrecedence pins the rule that makes -X injection safe to
// add to a package that spent its life advertising it did none: an injected
// value may only ever FILL a gap Go left, never override what Go embedded.
// Reverting that condition is what this test catches.
func TestApplyInjectedPrecedence(t *testing.T) {
	const (
		embedded = "1111111111111111111111111111111111111111"
		injected = "2222222222222222222222222222222222222222"
	)
	tests := []struct {
		name         string
		in           Info
		rev, ctime   string
		wantRevision string
		wantDate     string
	}{
		{
			// The work-tree case. Go stamped a revision, so injection is
			// ignored even when present — a local build behaves exactly as it
			// did before injection existed.
			name:         "embedded wins over injected",
			in:           Info{GitRevision: embedded, GitCommitDate: "2026.01.01.00.00.00.+0000"},
			rev:          injected,
			ctime:        "2026-08-24T23:20:03Z",
			wantRevision: embedded,
			wantDate:     "2026.01.01.00.00.00.+0000",
		},
		{
			// The module-download case this feature exists for.
			name:         "injected fills the gap Go left",
			in:           Info{},
			rev:          injected,
			ctime:        "2026-08-24T23:20:03Z",
			wantRevision: injected,
			wantDate:     "2026.08.24.23.20.03.+0000",
		},
		{
			// A binary built with no -X at all: unchanged, still empty, so the
			// display layer renders the not-embedded marker as before.
			name:         "no injection leaves the gap for the marker",
			in:           Info{},
			wantRevision: "",
			wantDate:     "",
		},
		{
			// "unknown" is what the ldflags placeholder expands to when
			// resolution failed. Accepting it would convert a known-unknown
			// into a confident wrong answer.
			name:         "the unknown sentinel is not a revision",
			in:           Info{},
			rev:          "unknown",
			ctime:        "unknown",
			wantRevision: "",
			wantDate:     "",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := applyInjected(tt.in, tt.rev, tt.ctime)
			if got.GitRevision != tt.wantRevision {
				t.Errorf("GitRevision = %q, want %q", got.GitRevision, tt.wantRevision)
			}
			if got.GitCommitDate != tt.wantDate {
				t.Errorf("GitCommitDate = %q, want %q", got.GitCommitDate, tt.wantDate)
			}
		})
	}
}
