package pins

import (
	"strings"
	"testing"
)

func TestParsePubspecDep(t *testing.T) {
	tests := []struct {
		name     string
		yaml     string
		wantKind PinKind
		wantRef  string
		wantURL  string
	}{
		{
			name: "git tag pin",
			yaml: `
dependencies:
  flutter:
    sdk: flutter
  desktop_kit:
    git:
      url: git@github.com:davidwalter0/ui-kit-private.git
      ref: v0.1.1
`,
			wantKind: KindTag, wantRef: "v0.1.1",
			wantURL: "git@github.com:davidwalter0/ui-kit-private.git",
		},
		{
			name: "git sha pin",
			yaml: `
dependencies:
  desktop_kit:
    git:
      url: git@github.com:davidwalter0/ui-kit-private.git
      ref: b3dbc952e63775b94cbd21d7be65ab395f4b0cb0
`,
			wantKind: KindSHA, wantRef: "b3dbc952e63775b94cbd21d7be65ab395f4b0cb0",
			wantURL: "git@github.com:davidwalter0/ui-kit-private.git",
		},
		{
			name: "git branch ref pin",
			yaml: `
dependencies:
  desktop_kit:
    git:
      url: git@github.com:davidwalter0/ui-kit-private.git
      ref: main
`,
			wantKind: KindRef, wantRef: "main",
			wantURL: "git@github.com:davidwalter0/ui-kit-private.git",
		},
		{
			name: "git implicit HEAD (no ref)",
			yaml: `
dependencies:
  desktop_kit:
    git:
      url: git@github.com:davidwalter0/ui-kit-private.git
`,
			wantKind: KindRef, wantRef: "",
			wantURL: "git@github.com:davidwalter0/ui-kit-private.git",
		},
		{
			name: "path dep",
			yaml: `
dependencies:
  desktop_kit:
    path: ../../../ui-kit-private
`,
			wantKind: KindPath, wantRef: "../../../ui-kit-private",
		},
		{
			name: "missing dep",
			yaml: `
dependencies:
  flutter:
    sdk: flutter
`,
			wantKind: KindMissing,
		},
		{
			name: "plain hosted constraint",
			yaml: `
dependencies:
  desktop_kit: ^0.1.0
`,
			wantKind: KindRef, wantRef: "^0.1.0",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ParsePubspecDep([]byte(tt.yaml), "desktop_kit")
			if err != nil {
				t.Fatalf("ParsePubspecDep: %v", err)
			}
			if got.Kind != tt.wantKind || got.Ref != tt.wantRef || got.URL != tt.wantURL {
				t.Errorf("got %+v, want kind=%s ref=%q url=%q", got, tt.wantKind, tt.wantRef, tt.wantURL)
			}
		})
	}
}

func TestParsePubspecDepMalformed(t *testing.T) {
	if _, err := ParsePubspecDep([]byte("\t: bad"), "desktop_kit"); err == nil {
		t.Fatal("expected error on malformed YAML")
	}
}

func TestLatestSemverTag(t *testing.T) {
	tests := []struct {
		name string
		tags []string
		want string
	}{
		{"picks highest", []string{"v0.1.0", "v0.1.1"}, "v0.1.1"},
		{"ignores non-semver", []string{"fonts-v1.0.0", "dictionary-v0.1.0", "v0.1.1"}, "v0.1.1"},
		{"orders numerically not lexically", []string{"v0.10.0", "v0.9.0"}, "v0.10.0"},
		{"empty", nil, ""},
		{"only non-semver", []string{"fonts-v1.0.0"}, ""},
		{"prerelease sorts below release", []string{"v0.2.0-rc.1", "v0.1.1"}, "v0.2.0-rc.1"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := LatestSemverTag(tt.tags); got != tt.want {
				t.Errorf("LatestSemverTag(%v) = %q, want %q", tt.tags, got, tt.want)
			}
		})
	}
}

func TestClassify(t *testing.T) {
	tests := []struct {
		name   string
		pin    Pin
		latest string
		want   Status
	}{
		{"converged tag", Pin{Kind: KindTag, Ref: "v0.1.1"}, "v0.1.1", StatusConverged},
		{"lagging tag", Pin{Kind: KindTag, Ref: "v0.1.0"}, "v0.1.1", StatusLagging},
		{"tag newer than latest stays converged", Pin{Kind: KindTag, Ref: "v0.2.0"}, "v0.1.1", StatusConverged},
		{"tag with no releases", Pin{Kind: KindTag, Ref: "v0.1.0"}, "", StatusConverged},
		{"sha", Pin{Kind: KindSHA, Ref: "b3dbc95"}, "v0.1.1", StatusSHA},
		{"branch ref", Pin{Kind: KindRef, Ref: "main"}, "v0.1.1", StatusRefPin},
		{"path", Pin{Kind: KindPath, Ref: "../x"}, "v0.1.1", StatusPath},
		{"missing", Pin{Kind: KindMissing}, "v0.1.1", StatusMissing},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Classify(tt.pin, tt.latest); got != tt.want {
				t.Errorf("Classify(%+v, %q) = %s, want %s", tt.pin, tt.latest, got, tt.want)
			}
		})
	}
}

func TestIsHexSHA(t *testing.T) {
	tests := []struct {
		ref  string
		want bool
	}{
		{"b3dbc95", true},
		{"b3dbc952e63775b94cbd21d7be65ab395f4b0cb0", true},
		{"main", false},
		{"v0.1.1", false},
		{"abc", false},                   // too short
		{strings.Repeat("a", 41), false}, // too long
		{"deadbeeg", false},              // non-hex char
	}
	for _, tt := range tests {
		if got := isHexSHA(tt.ref); got != tt.want {
			t.Errorf("isHexSHA(%q) = %v, want %v", tt.ref, got, tt.want)
		}
	}
}

func TestParseConfig(t *testing.T) {
	good := `
dep: desktop_kit
dep_repo: /home/x/ui-kit-private
consumers:
  - name: notekeep
    pubspec: /home/x/notekeep/app/pubspec.yaml
    branch: main
`
	c, err := ParseConfig([]byte(good))
	if err != nil {
		t.Fatalf("ParseConfig: %v", err)
	}
	if c.Dep != "desktop_kit" || len(c.Consumers) != 1 || c.Consumers[0].Name != "notekeep" {
		t.Errorf("unexpected config: %+v", c)
	}
	for name, bad := range map[string]string{
		"missing dep":  "consumers:\n  - name: a\n    pubspec: /p\n",
		"no consumers": "dep: desktop_kit\n",
		"malformed":    "\t: nope",
	} {
		if _, err := ParseConfig([]byte(bad)); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
}

func TestDriftedAndRenderTable(t *testing.T) {
	rows := []Row{
		{Consumer: "notekeep", Pin: Pin{Kind: KindTag, Ref: "v0.1.1"}, Status: StatusConverged},
		{Consumer: "nh", Pin: Pin{Kind: KindPath, Ref: "../kit"}, Status: StatusPath},
	}
	if !Drifted(rows) {
		t.Error("Drifted: want true with a PATH-DEP row")
	}
	if Drifted(rows[:1]) {
		t.Error("Drifted: want false when all converged")
	}
	out := RenderTable(rows, "desktop_kit", "v0.1.1")
	for _, want := range []string{"desktop_kit latest release: v0.1.1", "notekeep", "converged", "PATH-DEP", "../kit"} {
		if !strings.Contains(out, want) {
			t.Errorf("RenderTable missing %q in:\n%s", want, out)
		}
	}
	if out2 := RenderTable(nil, "desktop_kit", ""); !strings.Contains(out2, "(no semver tags)") {
		t.Errorf("RenderTable empty-latest header missing: %s", out2)
	}
}
