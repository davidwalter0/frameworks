package spec

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"

	"github.com/davidwalter0/frameworks/go/pkg/deps"
	"gopkg.in/yaml.v3"
)

// ManifestName is the conventional filename, at a repo root beside deps.yaml's
// successor and — after an install — inside the installed tree.
const ManifestName = "manifest.yaml"

// InstalledManifestDir is where an install records its own manifest and
// receipt, relative to the app directory. A leading dot keeps it out of the
// way of the payload's own entries.
const InstalledManifestDir = ".install"

// Manifest is the on-disk declaration a repo edits, and the SAME document an
// install writes into the tree it created.
//
// One file, three sections, because they are three genuinely different
// questions about one component:
//
//	spec:      what this application IS            (identity, layout, launchers, icons)
//	requires:  what BUILDING or CHECKING it needs  (tools on the developer's host)
//	ships:     what the ARTIFACT needs             (libraries on the user's machine)
//
// The split that matters is `requires` versus `ships`. Both are dependencies
// and both reuse [deps.Policy], which is why they belong in one file — but
// jq's absence breaks a gate on a developer's laptop, while libgtk-3-0's
// absence breaks the installed application on a stranger's. Collapsing them
// would force one policy vocabulary to mean two things; separating them into
// two FILES is what let them drift, which is the state this type replaces.
//
// WHY THIS EXISTS RATHER THAN A GO LITERAL. Until now a consumer declared its
// Spec as a Go struct compiled into its installer, and its build tools as YAML
// beside it. Two hand-maintained lists, two formats, one shared vocabulary, no
// link — the same shape as the hook tables that were deleted from the rule
// tree after each disagreed with what it described. A Spec buried in Go is
// also invisible to everything that is not that binary: the deb packager
// cannot read its ships list, `deps verify` cannot see it, and a reviewer
// cannot diff it without reading Go.
//
// Note what is NOT here, and cannot be. Payload, Icons, SystemIndexTheme,
// Home, ConfigHome, PathEnv and Prefix are `yaml:"-"`. They are supplied at
// the CALL SITE — embedded bytes, host reads, environment — and a manifest
// that appeared to declare them would be claiming to fix values it cannot
// know. The manifest is the DECLARATIVE half of a Spec; the injected half
// stays injected.
type Manifest struct {
	// Spec is the application declaration. Its own fields carry the yaml
	// names, so this section IS a Spec rather than a parallel description of
	// one — there is no second struct to fall out of step.
	Spec Spec `yaml:"spec" json:"spec"`

	// Requires are host tools needed to build or check, with the policy for
	// each one's absence. Identical in shape to deps.yaml's `requires:`, which
	// is what this section absorbs.
	Requires []deps.Tool `yaml:"requires,omitempty" json:"requires,omitempty"`
}

// Ships returns the artifact's own dependencies. They live on the Spec (as
// [Spec.Requires], keyed `ships:` in yaml) because they are a property of the
// application, not of the repo that builds it — an installed manifest must
// carry them, and it does not carry the build tools.
func (m Manifest) Ships() []Dependency { return m.Spec.Requires }

// Load parses a manifest from bytes. Strict: an unknown field is an error
// rather than a silent drop, so a typo in a key name fails loudly instead of
// leaving a declaration that reads as present and is not.
func Load(b []byte) (Manifest, error) {
	var m Manifest
	dec := yaml.NewDecoder(bytes.NewReader(b))
	dec.KnownFields(true)
	if err := dec.Decode(&m); err != nil {
		return Manifest{}, fmt.Errorf("manifest: %w", err)
	}
	return m, nil
}

// LoadFile reads and parses a manifest from disk.
func LoadFile(path string) (Manifest, error) {
	b, err := os.ReadFile(path) //nolint:gosec // caller-supplied manifest path
	if err != nil {
		return Manifest{}, fmt.Errorf("manifest: %w", err)
	}
	m, err := Load(b)
	if err != nil {
		return Manifest{}, fmt.Errorf("%s: %w", filepath.Base(path), err)
	}
	return m, nil
}

// Marshal renders the manifest back to YAML. Used to write the manifest INTO
// an installed tree, so what is installed is the same document that drove the
// install rather than a summary of it.
func (m Manifest) Marshal() ([]byte, error) {
	b, err := yaml.Marshal(m)
	if err != nil {
		return nil, fmt.Errorf("manifest: %w", err)
	}
	return b, nil
}

// Validate checks both halves: the Spec (identity, layout, ships) and the
// build-tool policies.
func (m Manifest) Validate() error {
	if err := m.Spec.Validate(); err != nil {
		return err
	}
	for i, t := range m.Requires {
		where := fmt.Sprintf("requires[%d]", i)
		if t.Name != "" {
			where = fmt.Sprintf("requires[%d] (%s)", i, t.Name)
		}
		if t.Name == "" {
			return fmt.Errorf("manifest: %s: tool name is empty", where)
		}
		if !t.Policy.Valid() {
			return fmt.Errorf("manifest: %s: unknown policy %q", where, t.Policy)
		}
		if t.Why == "" {
			return fmt.Errorf("manifest: %s: %q is empty — a prerequisite nobody can explain cannot be safely removed", where, "why")
		}
	}
	return nil
}

// --- enum <-> string, so a manifest reads as words rather than iota ---------
//
// CleanMode and DesktopNaming are iota constants, and their zero values are
// the DEFAULTS (CleanAppDir, DesktopByAppID). Serialized as integers a
// manifest would say `clean-mode: 1`, which is unreadable and, worse, silently
// wrong if the constant order ever changes. These four methods pin the wire
// format to the names, so the constant order becomes an implementation detail
// again.

const (
	cleanAppDirName  = "app-dir"
	cleanSubdirsName = "subdirs"

	desktopByAppIDName    = "by-app-id"
	desktopByBasenameName = "by-basename"
)

// MarshalYAML renders the mode as its name.
func (c CleanMode) MarshalYAML() (any, error) {
	switch c {
	case CleanAppDir:
		return cleanAppDirName, nil
	case CleanSubdirs:
		return cleanSubdirsName, nil
	}
	return nil, fmt.Errorf("spec: unknown CleanMode %d", int(c))
}

// UnmarshalYAML accepts the mode's name.
func (c *CleanMode) UnmarshalYAML(n *yaml.Node) error {
	var s string
	if err := n.Decode(&s); err != nil {
		return err
	}
	switch s {
	case cleanAppDirName:
		*c = CleanAppDir
	case cleanSubdirsName:
		*c = CleanSubdirs
	default:
		return fmt.Errorf("spec: unknown clean-mode %q (want %q or %q)",
			s, cleanAppDirName, cleanSubdirsName)
	}
	return nil
}

// MarshalYAML renders the naming rule as its name.
func (d DesktopNaming) MarshalYAML() (any, error) {
	switch d {
	case DesktopByAppID:
		return desktopByAppIDName, nil
	case DesktopByBasename:
		return desktopByBasenameName, nil
	}
	return nil, fmt.Errorf("spec: unknown DesktopNaming %d", int(d))
}

// UnmarshalYAML accepts the naming rule's name.
func (d *DesktopNaming) UnmarshalYAML(n *yaml.Node) error {
	var s string
	if err := n.Decode(&s); err != nil {
		return err
	}
	switch s {
	case desktopByAppIDName:
		*d = DesktopByAppID
	case desktopByBasenameName:
		*d = DesktopByBasename
	default:
		return fmt.Errorf("spec: unknown desktop-naming %q (want %q or %q)",
			s, desktopByAppIDName, desktopByBasenameName)
	}
	return nil
}
