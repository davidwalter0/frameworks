// Package pins inspects how consumer repos pin a shared Dart package
// dependency (by git tag, git SHA, or local path) and classifies each pin
// against the dependency's latest released semver tag.
//
// It exists because Renovate/Dependabot handle pub git-ref dependencies
// poorly: a consumer silently lagging a tag — or still on a raw SHA or a
// relative path — is exactly the drift that broke consumers during the
// desktop_kit v0.1.x rollout.
package pins

import (
	"fmt"
	"os/exec"
	"sort"
	"strings"

	"golang.org/x/mod/semver"
	"gopkg.in/yaml.v3"
)

// PinKind is how a consumer references the dependency.
type PinKind string

// The recognised dependency reference shapes.
const (
	KindTag     PinKind = "tag"     // git ref that is a valid semver tag (vX.Y.Z)
	KindSHA     PinKind = "sha"     // git ref that looks like a raw commit hash
	KindRef     PinKind = "ref"     // git ref that is neither semver nor a SHA (branch, other tag)
	KindPath    PinKind = "path"    // local path dependency — unvendored
	KindMissing PinKind = "missing" // dependency not found in the pubspec
)

// Pin is one consumer's resolved dependency reference.
type Pin struct {
	Kind PinKind
	Ref  string // the tag / sha / ref / path value (empty for KindMissing)
	URL  string // git URL when Kind is a git form
}

// Status classifies a Pin against the latest released tag.
type Status string

// Drift classifications, from healthy to needs-attention.
const (
	StatusConverged Status = "converged" // pinned to the latest semver tag
	StatusLagging   Status = "LAGGING"   // pinned to an older semver tag
	StatusSHA       Status = "SHA-PIN"   // raw commit pin — version invisible
	StatusRefPin    Status = "REF-PIN"   // branch/non-semver ref — mutable pin
	StatusPath      Status = "PATH-DEP"  // local path — unvendored, unpinned
	StatusMissing   Status = "MISSING"   // dependency absent from pubspec
)

// Consumer is one repo to audit.
type Consumer struct {
	Name    string `yaml:"name"`
	Pubspec string `yaml:"pubspec"` // absolute path to the consumer's pubspec.yaml
	Branch  string `yaml:"branch"`  // integration branch (informational)
}

// Config is the tool's input: the dependency to audit and the consumers.
type Config struct {
	Dep       string     `yaml:"dep"`      // pub package name, e.g. desktop_kit
	DepRepo   string     `yaml:"dep_repo"` // local path to the dependency repo (tag source)
	Consumers []Consumer `yaml:"consumers"`
}

// ParseConfig decodes the YAML config.
func ParseConfig(data []byte) (Config, error) {
	var c Config
	if err := yaml.Unmarshal(data, &c); err != nil {
		return Config{}, fmt.Errorf("parse config: %w", err)
	}
	if c.Dep == "" {
		return Config{}, fmt.Errorf("parse config: missing dep")
	}
	if len(c.Consumers) == 0 {
		return Config{}, fmt.Errorf("parse config: no consumers")
	}
	return c, nil
}

// ParsePubspecDep extracts how depName is referenced in a pubspec.yaml body.
func ParsePubspecDep(data []byte, depName string) (Pin, error) {
	var doc struct {
		Dependencies map[string]yaml.Node `yaml:"dependencies"`
	}
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return Pin{}, fmt.Errorf("parse pubspec: %w", err)
	}
	node, ok := doc.Dependencies[depName]
	if !ok {
		return Pin{Kind: KindMissing}, nil
	}
	var dep struct {
		Path string `yaml:"path"`
		Git  struct {
			URL string `yaml:"url"`
			Ref string `yaml:"ref"`
		} `yaml:"git"`
	}
	if err := node.Decode(&dep); err != nil {
		// A plain version constraint ("^1.0.0") decodes as a scalar, not a map.
		return Pin{Kind: KindRef, Ref: strings.TrimSpace(node.Value)}, nil
	}
	switch {
	case dep.Path != "":
		return Pin{Kind: KindPath, Ref: dep.Path}, nil
	case dep.Git.URL != "":
		return Pin{Kind: classifyGitRef(dep.Git.Ref), Ref: dep.Git.Ref, URL: dep.Git.URL}, nil
	default:
		return Pin{Kind: KindMissing}, nil
	}
}

// classifyGitRef buckets a git ref string into tag / sha / other-ref.
func classifyGitRef(ref string) PinKind {
	if ref == "" {
		return KindRef // implicit HEAD — mutable
	}
	if semver.IsValid(ref) {
		return KindTag
	}
	if isHexSHA(ref) {
		return KindSHA
	}
	return KindRef
}

// isHexSHA reports whether ref looks like an abbreviated or full commit hash.
func isHexSHA(ref string) bool {
	if n := len(ref); n < 7 || n > 40 {
		return false
	}
	for _, r := range ref {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') && (r < 'A' || r > 'F') {
			return false
		}
	}
	return true
}

// LatestSemverTag returns the highest valid semver tag (vX.Y.Z…) in tags,
// ignoring non-semver tags (e.g. fonts-v1.0.0, dictionary-v0.1.0).
func LatestSemverTag(tags []string) string {
	valid := tags[:0:0]
	for _, t := range tags {
		if semver.IsValid(t) {
			valid = append(valid, t)
		}
	}
	if len(valid) == 0 {
		return ""
	}
	sort.Slice(valid, func(i, j int) bool { return semver.Compare(valid[i], valid[j]) < 0 })
	return valid[len(valid)-1]
}

// Classify maps a Pin + the latest released tag to a drift Status.
func Classify(p Pin, latest string) Status {
	switch p.Kind {
	case KindTag:
		if latest != "" && semver.Compare(p.Ref, latest) < 0 {
			return StatusLagging
		}
		return StatusConverged
	case KindSHA:
		return StatusSHA
	case KindRef:
		return StatusRefPin
	case KindPath:
		return StatusPath
	default:
		return StatusMissing
	}
}

// RepoTags lists tag names in the git repo at dir (local tags — run
// `git fetch --tags` beforehand for remote truth; the CLI does).
func RepoTags(dir string) ([]string, error) {
	out, err := exec.Command("git", "-C", dir, "tag", "--list").Output()
	if err != nil {
		return nil, fmt.Errorf("git -C %s tag --list: %w", dir, err)
	}
	var tags []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			tags = append(tags, line)
		}
	}
	return tags, nil
}

// FetchTags refreshes dir's tags from its origin. Best-effort network step —
// callers may proceed with local tags when offline.
func FetchTags(dir string) error {
	if out, err := exec.Command("git", "-C", dir, "fetch", "--tags", "--quiet", "origin").CombinedOutput(); err != nil {
		return fmt.Errorf("git -C %s fetch --tags: %v: %s", dir, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// Row is one line of the drift report.
type Row struct {
	Consumer string
	Pin      Pin
	Status   Status
}

// Drifted reports whether any row needs attention.
func Drifted(rows []Row) bool {
	for _, r := range rows {
		if r.Status != StatusConverged {
			return true
		}
	}
	return false
}

// RenderTable formats rows as an aligned text table with a latest-tag header.
func RenderTable(rows []Row, dep, latest string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s latest release: %s\n\n", dep, latestOr(latest))
	fmt.Fprintf(&b, "%-22s %-10s %-44s %s\n", "Consumer", "Status", "Pinned ref", "Kind")
	fmt.Fprintf(&b, "%s\n", strings.Repeat("─", 88))
	for _, r := range rows {
		ref := r.Pin.Ref
		if ref == "" {
			ref = "—"
		}
		fmt.Fprintf(&b, "%-22s %-10s %-44s %s\n", r.Consumer, r.Status, ref, r.Pin.Kind)
	}
	return b.String()
}

func latestOr(latest string) string {
	if latest == "" {
		return "(no semver tags)"
	}
	return latest
}
