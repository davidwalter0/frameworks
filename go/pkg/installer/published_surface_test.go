package installer_test

import (
	"testing"

	"github.com/davidwalter0/frameworks/go/pkg/installer"
)

// TestSpecValidateIsReachableFromInstaller pins a published method that the
// Spec merge silently removed.
//
// installer.Spec is a type ALIAS for spec.Spec, so this package cannot define
// methods on it — every method comes from pkg/spec, and renaming one there
// deletes it from the surface consumers compile against. When the desktop half
// merged into pkg/spec its validator arrived as ValidateDesktop; nothing inside
// this module called Spec.Validate, so `go build ./...` stayed green across all
// three in-tree consumers and the break surfaced only in mountbridge' own test
// suite, which opens with spec.Validate().
//
// The lesson this test encodes: for an aliased type, "the module builds" and
// "the published surface is intact" are different claims, and only the second
// one is what a consumer depends on. Compiling consumers is not enough either —
// `go build` does not compile _test.go files, which is exactly where the call
// lived.
func TestSpecValidateIsReachableFromInstaller(t *testing.T) {
	s := installer.Spec{
		AppID:       "com.example.app",
		ShareSubdir: "app",
		Launchers:   []installer.Launcher{{Target: "app", Name: "app"}},
	}
	if err := s.Validate(); err != nil {
		t.Fatalf("installer.Spec.Validate() on a valid spec: %v", err)
	}
}

// TestSpecValidateStillRejectsAnInvalidSpec guards the other direction: a
// Validate that always returned nil would satisfy the test above while
// silently accepting anything.
func TestSpecValidateStillRejectsAnInvalidSpec(t *testing.T) {
	var s installer.Spec // no ShareSubdir, no Launchers
	if err := s.Validate(); err == nil {
		t.Fatal("installer.Spec.Validate() accepted an empty spec; it must not")
	}
}
