// Command example-installer is a worked example of a self-extracting
// installer built on the shared frameworks/go/pkg/installer package,
// packaging a sample desktop app ("voicelab").
//
// It replaces the per-repo fork at
// github.com/davidwalter0/voicelab/cmd/installer (285 lines); see
// go/docs/installer-consumer-report.org for the migration notes and the
// behavioural diff against that fork. The fork is not deleted by this
// change — it retires only after the packaged output here is verified
// against a real install (copy-first migration).
package main

import "github.com/davidwalter0/frameworks/go/pkg/installer"

// version is stamped at build time via -ldflags "-X main.version=...".
var version = "dev"

// appID must equal the GTK APPLICATION_ID (ui/voicelab-ui/linux/CMakeLists.txt),
// the .desktop Icon=/StartupWMClass values, and the hicolor icon basename —
// see installer.Spec.AppID.
const appID = "com.davidwalter0.exampleUi"

var spec = installer.Spec{
	AppID:         appID,
	DisplayName:   "voicelab",
	ShareSubdir:   "voicelab",
	DesktopSource: "voicelab-ui.desktop",
	Launchers: []installer.Launcher{
		{Target: "bin/vl", Name: "vl", Blurb: "(try: vl --help)"},
		{Target: "voicelab-ui", Name: "voicelab-ui", Blurb: "(or launch 'Voice Lab' from your menu)"},
	},
	// CleanMode, DesktopNaming and IconRels are left at their package
	// defaults (CleanAppDir, DesktopByAppID, DefaultIconRels(appID)) — see
	// installer-consumer-report.org for why each default is a deliberate
	// improvement over the fork rather than an oversight.
}

func main() {
	installer.Run(spec, payload, version)
}
