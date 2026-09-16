package installer

import (
	"github.com/davidwalter0/frameworks/go/pkg/spec"
)

// The Spec and its supporting types now live in pkg/spec. What remains here are
// ALIASES, not new types.
//
// WHY THE MOVE. frameworks briefly carried two Spec types — this package's, and
// pkg/spec's (absorbed from installkit with the deployment targets). Neither was
// a superset, and D-0005 had already rejected that state by name: "two Specs,
// two prefix defaults, two uninstall models in every adopting repo,
// permanently." The direction was decided by the import graph rather than
// preference: pkg/spec imports nothing internal and is what pkg/instruct and
// pkg/target already build on, while this package touches only pkg/instruct.
//
// WHY ALIASES RATHER THAN A CLEAN BREAK. `type Spec = spec.Spec` declares no new
// type — installer.Spec and spec.Spec are the SAME type, so this is genuinely
// one Spec with two names, not the two-Specs state that was just removed. The
// three live consumers (voicelab, waterworks, beacon-sim) keep compiling untouched,
// which turns their migration into a rename they can take when they bump rather
// than a break they must absorb on our schedule.
//
// These aliases are the migration surface and are expected to be deleted once
// those three have moved. They are not a permanent second API.

// Spec is [spec.Spec]. See that type for the full field set: this package uses
// the desktop-application half, while pkg/target uses the deployment half.
type Spec = spec.Spec

// Launcher is [spec.Launcher] — one bin/ symlink the install creates.
type Launcher = spec.Launcher

// CleanMode is [spec.CleanMode] — how much of a previous install is removed.
type CleanMode = spec.CleanMode

// DesktopNaming is [spec.DesktopNaming] — the installed .desktop basename.
type DesktopNaming = spec.DesktopNaming

// Layout is [spec.Layout] — every directory an install touches.
type Layout = spec.Layout

// Component is [spec.Component] — one installable piece of an application.
type Component = spec.Component

// Role is [spec.Role] — what a component IS, from which the platform derives
// where it goes.
type Role = spec.Role

// Platform is [spec.Platform] — the OS whose filesystem conventions apply.
type Platform = spec.Platform

// Env is [spec.Env] — the environment paths are derived FROM.
type Env = spec.Env

// Overrides is [spec.Overrides] — explicit destinations that win over the
// platform defaults.
type Overrides = spec.Overrides

// The constants keep their unqualified names so existing consumers read the
// same. Each still means what its documentation in pkg/spec says, including the
// findings behind the defaults.
const (
	// CleanAppDir removes the entire app directory (the default).
	CleanAppDir = spec.CleanAppDir
	// CleanSubdirs removes only Spec.CleanSubdirs.
	CleanSubdirs = spec.CleanSubdirs

	// DesktopByAppID names the entry "<AppID>.desktop" (the default, and the
	// Wayland-correct one).
	DesktopByAppID = spec.DesktopByAppID
	// DesktopByBasename keeps the payload's own basename.
	DesktopByBasename = spec.DesktopByBasename
)

// Icon-rel builders, re-exported so a consumer constructing a Spec needs only
// this package.
var (
	// DefaultIconRels is [spec.DefaultIconRels].
	DefaultIconRels = spec.DefaultIconRels
	// IconRels is [spec.IconRels].
	IconRels = spec.IconRels
	// PNGIconRels is [spec.PNGIconRels].
	PNGIconRels = spec.PNGIconRels
	// ScalableIconRel is [spec.ScalableIconRel].
	ScalableIconRel = spec.ScalableIconRel
)
