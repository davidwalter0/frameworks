package spec

import (
	"fmt"
	"runtime"
)

// Platform names the operating system whose filesystem conventions an install
// follows.
//
// WHY THIS TYPE EXISTS AT ALL. Before it, this package had zero `runtime.GOOS`
// branches and zero per-OS files, while [Spec.LayoutFor] hardcoded
// "share/applications" and "share/icons/hicolor" — XDG shapes, unconditionally.
// The library did not CHOOSE Linux; it had no concept of platform, so a macOS
// consumer could only get the Linux answer or write its own resolver. Both
// happened: cross-bridge carries cmd/installer/installer_{darwin,linux}.go
// precisely because this package could not express the difference.
//
// An unknown platform is an ERROR, never a silent fallback to Linux. A wrong
// layout does not fail at install time — it succeeds, puts files where nothing
// looks for them, and is diagnosed weeks later as "the app doesn't start".
type Platform string

const (
	// PlatformLinux uses the XDG Base Directory layout.
	PlatformLinux Platform = "linux"

	// PlatformDarwin uses the macOS layout: ~/Library/Application Support for
	// data, ~/Library/Preferences for config, ~/Library/LaunchAgents for units.
	PlatformDarwin Platform = "darwin"
)

// CurrentPlatform reports the platform this binary is running on.
//
// Callers that are RENDERING for another host — building a package on Linux
// that installs on macOS — must pass the target platform explicitly rather than
// using this. That is the whole reason [Spec.LayoutForPlatform] takes a
// Platform instead of reading runtime.GOOS itself.
func CurrentPlatform() Platform {
	return Platform(runtime.GOOS)
}

// Valid reports whether p is a platform this package can resolve a layout for.
func (p Platform) Valid() bool {
	switch p {
	case PlatformLinux, PlatformDarwin:
		return true
	}
	return false
}

// ParsePlatform validates a platform name.
//
// The error names the supported set rather than saying "unsupported", because
// the caller's next question is always "then what IS supported" and making them
// read the source for it is a discourtesy repeated at every call site.
func ParsePlatform(s string) (Platform, error) {
	p := Platform(s)
	if !p.Valid() {
		return "", fmt.Errorf(
			"spec: unsupported platform %q (supported: %q, %q)",
			s, PlatformLinux, PlatformDarwin)
	}
	return p, nil
}

// String implements fmt.Stringer.
func (p Platform) String() string { return string(p) }
