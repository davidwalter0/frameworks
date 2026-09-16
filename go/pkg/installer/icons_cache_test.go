// Tests for the icon-cache advice. The defect these pin (mgmt todo 724536d3,
// reported from zplay as "the icon isn't loaded") shipped because NOTHING
// asserted the printed text: the install succeeded, every file landed in the
// right place, and the one sentence telling the operator what to do next said
// the opposite of the truth.
//
// So the load-bearing assertions here are about the MESSAGE, not about files.
package installer

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestIconNamesFromRels(t *testing.T) {
	tests := []struct {
		name string
		rels []string
		want []string
	}{
		{
			name: "strips directory and extension",
			rels: []string{"256x256/apps/com.example.App.png"},
			want: []string{"com.example.App"},
		},
		{
			name: "dedupes the same name across sizes, preserving first-seen order",
			rels: []string{
				"48x48/apps/com.example.App.png",
				"256x256/apps/com.example.App.png",
				"scalable/apps/com.example.App.svg",
			},
			want: []string{"com.example.App"},
		},
		{
			name: "keeps distinct names",
			rels: []string{"256x256/apps/a.png", "256x256/apps/b.png"},
			want: []string{"a", "b"},
		},
		{
			name: "a dotted AppID keeps every component but the extension",
			rels: []string{"scalable/apps/io.github.davidwalter0.zplay.svg"},
			want: []string{"io.github.davidwalter0.zplay"},
		},
		{name: "no rels yields no names", rels: nil, want: nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := iconNamesFromRels(tt.rels)
			if len(got) != len(tt.want) {
				t.Fatalf("iconNamesFromRels(%v) = %v, want %v", tt.rels, got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("iconNamesFromRels(%v)[%d] = %q, want %q", tt.rels, i, got[i], tt.want[i])
				}
			}
		})
	}
}

// themeWithCache builds a theme directory, optionally with an icon-theme.cache
// whose bytes contain the given names. The real cache is a binary hash table
// with the names in a string section; a byte-substring test is what the
// production code uses, so a synthetic blob carrying the names is a faithful
// stand-in for the property under test.
func themeWithCache(t *testing.T, cache bool, listed ...string) string {
	t.Helper()
	theme := filepath.Join(t.TempDir(), "hicolor")
	if err := os.MkdirAll(filepath.Join(theme, "256x256", "apps"), 0o755); err != nil {
		t.Fatal(err)
	}
	if cache {
		blob := append([]byte("\x01\x00\x00\x00binary-header\x00"), []byte(strings.Join(listed, "\x00"))...)
		if err := os.WriteFile(filepath.Join(theme, "icon-theme.cache"), blob, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return theme
}

func TestIconCacheStaleDirections(t *testing.T) {
	const name = "com.example.App"

	tests := []struct {
		desc      string
		cache     bool
		listed    []string
		phase     iconPhase
		wantStale bool
		why       string
	}{
		{
			desc: "install, no cache at all", cache: false,
			phase: iconInstall, wantStale: false,
			why: "with no cache GTK scans the directories, so nothing is required",
		},
		{
			desc: "install, cache does not list the icon", cache: true, listed: []string{"other.App"},
			phase: iconInstall, wantStale: true,
			why: "this is the reported defect: the icon is invisible until a rebuild",
		},
		{
			desc: "install, cache already lists the icon", cache: true, listed: []string{name},
			phase: iconInstall, wantStale: false,
			why: "a cache that already knows the name resolves it; asking for a rebuild would be noise",
		},
		{
			desc: "uninstall, cache still lists the removed icon", cache: true, listed: []string{name},
			phase: iconUninstall, wantStale: true,
			why: "the lookup would resolve to files uninstall just deleted",
		},
		{
			desc: "uninstall, cache does not list it", cache: true, listed: []string{"other.App"},
			phase: iconUninstall, wantStale: false,
			why: "nothing to correct — the direction is the OPPOSITE of install, not the same test",
		},
		{
			desc: "uninstall, no cache", cache: false,
			phase: iconUninstall, wantStale: false,
			why: "removeWrittenIconTheme deletes our own cache; absence is the success case",
		},
	}

	for _, tt := range tests {
		t.Run(tt.desc, func(t *testing.T) {
			theme := themeWithCache(t, tt.cache, tt.listed...)
			stale, cachePath := iconCacheStale(theme, []string{name}, tt.phase)
			if stale != tt.wantStale {
				t.Errorf("iconCacheStale() = %v, want %v — %s", stale, tt.wantStale, tt.why)
			}
			if want := filepath.Join(theme, "icon-theme.cache"); cachePath != want {
				t.Errorf("cache path = %q, want %q", cachePath, want)
			}
		})
	}
}

// TestRefreshIconCacheRequiredNotOptional is the regression pin. The shipped
// text called the rebuild "optional; otherwise it updates at next login"; both
// halves were false, and the printed line was the only mechanism left after the
// exec was removed at go/v0.1.2.
func TestRefreshIconCacheRequiredNotOptional(t *testing.T) {
	theme := themeWithCache(t, true, "someone.else.App")
	var buf bytes.Buffer
	refreshIconCache(theme, []string{"com.example.App"}, iconInstall, progress{w: &buf})
	out := buf.String()

	if !strings.Contains(out, "REQUIRED") {
		t.Errorf("a stale cache must be reported as REQUIRED; got:\n%s", out)
	}
	if !strings.Contains(out, "gtk-update-icon-cache") {
		t.Errorf("the exact command must be printed; got:\n%s", out)
	}
	for _, forbidden := range []string{"optional", "next login"} {
		if strings.Contains(out, forbidden) {
			t.Errorf("output still claims %q — that was the defect, and both halves are false "+
				"once a cache exists; got:\n%s", forbidden, out)
		}
	}
}

// TestRefreshIconCacheSilentWhenNothingNeeded is the other half, and it is what
// keeps the fix from degenerating back into an unconditional notice. A notice
// printed on every install trains the reader to skip it, which is how the false
// "optional" line survived unread for as long as it did.
func TestRefreshIconCacheSilentWhenNothingNeeded(t *testing.T) {
	for _, tt := range []struct {
		desc   string
		cache  bool
		listed []string
	}{
		{desc: "no cache present", cache: false},
		{desc: "cache already lists the icon", cache: true, listed: []string{"com.example.App"}},
	} {
		t.Run(tt.desc, func(t *testing.T) {
			theme := themeWithCache(t, tt.cache, tt.listed...)
			var buf bytes.Buffer
			refreshIconCache(theme, []string{"com.example.App"}, iconInstall, progress{w: &buf})
			if out := buf.String(); out != "" {
				t.Errorf("expected no advice when no rebuild is needed, got:\n%s", out)
			}
		})
	}
}

// TestRefreshIconCacheUninstallNeverRecreatesIndexTheme guards the reason
// uninstall takes a different path at all: recreating index.theme here would
// resurrect the file removeWrittenIconTheme just deleted.
func TestRefreshIconCacheUninstallNeverRecreatesIndexTheme(t *testing.T) {
	theme := themeWithCache(t, true, "com.example.App")
	var buf bytes.Buffer
	refreshIconCache(theme, []string{"com.example.App"}, iconUninstall, progress{w: &buf})

	if _, err := os.Stat(filepath.Join(theme, "index.theme")); err == nil {
		t.Error("uninstall recreated index.theme, orphaning the file it had just removed")
	}
	if out := buf.String(); out != "" {
		t.Errorf("with no index.theme there is nothing to refresh, got:\n%s", out)
	}
}
