package spec

import (
	"strings"
	"testing"
)

// THE PORTABILITY INVARIANT. A manifest is the author's declaration and travels
// between machines and operating systems, so it must not be able to name a
// destination. Absolute paths belong in the RECEIPT, which records what one
// install wrote on one machine and must be absolute because you cannot
// uninstall a relative path.
//
// Without this check a manifest can bake in ~/.local/share/... — which reads as
// harmless on the machine it was written on and precludes macOS entirely.
func TestComponentRelMustBeRelative(t *testing.T) {
	err := ValidateComponents([]Component{
		{Name: "demod", Role: RoleDaemon, Rel: "/home/tester/.local/share/demo/bin/demod"},
	})
	if err == nil {
		t.Fatal("want an error for an absolute rel, got nil")
	}
	if !strings.Contains(err.Error(), "absolute") {
		t.Errorf("error should say the path is absolute, got: %v", err)
	}
	if !strings.Contains(err.Error(), "receipt") {
		t.Errorf("error should say where absolute paths DO belong, got: %v", err)
	}
}

func TestComponentRelMustNotEscape(t *testing.T) {
	err := ValidateComponents([]Component{
		{Name: "demod", Role: RoleDaemon, Rel: "../../etc/passwd"},
	})
	if err == nil {
		t.Fatal("want an error for a rel escaping the app directory")
	}
	if !strings.Contains(err.Error(), "escapes") {
		t.Errorf("error should say the path escapes, got: %v", err)
	}
}

func TestValidComponentsPass(t *testing.T) {
	err := ValidateComponents([]Component{
		{Name: "demod", Role: RoleDaemon, Rel: "bin/demod", Args: []string{"--serve"}},
		{Name: "demo", Role: RoleCLI, Rel: "bin/demo"},
		{Name: "demo-ui", Role: RoleGUI},
		{Name: "helper", Role: RoleHelper, Rel: "libexec/helper"},
	})
	if err != nil {
		t.Fatalf("valid components rejected: %v", err)
	}
}

func TestComponentNameRules(t *testing.T) {
	for _, tc := range []struct {
		name string
		cs   []Component
		want string
	}{
		{"missing name", []Component{{Role: RoleCLI}}, "name is required"},
		{"name is a path", []Component{{Name: "bin/demo", Role: RoleCLI}}, "basename"},
		{"duplicate", []Component{
			{Name: "demo", Role: RoleCLI}, {Name: "demo", Role: RoleGUI},
		}, "duplicate"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := ValidateComponents(tc.cs)
			if err == nil {
				t.Fatalf("want an error, got nil")
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error = %v, want it to mention %q", err, tc.want)
			}
		})
	}
}

func TestUnknownRoleIsRejected(t *testing.T) {
	err := ValidateComponents([]Component{{Name: "demo", Role: Role("service")}})
	if err == nil {
		t.Fatal("want an error for an unknown role")
	}
	// The message must name the supported set; "unknown role" alone sends the
	// reader to the source.
	for _, want := range []string{"cli", "daemon", "gui", "helper"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error should list %q as a valid role, got: %v", want, err)
		}
	}
}

// A CLI MAY ALSO BE A SERVICE, and this is the case the first real consumer
// exposed. mountbridge ships ONE binary that is both: its launcher blurb reads
// "(daemon + CLI; try: mountbridge doctor)". An earlier revision of this package
// refused unit fields on anything but RoleDaemon, which made that
// undescribable — RoleCLI put it on PATH and generated no unit, RoleDaemon
// generated the unit and kept it off PATH, and neither was true of it.
//
// So "is this a name a person types" and "does this have a service unit" are
// independent. This test pins that they stay independent.
func TestCLIMayAlsoDeclareAUnit(t *testing.T) {
	c := Component{Name: "mountbridge", Role: RoleCLI, Rel: "bin/mountbridge", Instanced: true}
	if err := ValidateComponents([]Component{c}); err != nil {
		t.Fatalf("a cli that is also a service must validate: %v", err)
	}
	if !c.HasUnit() {
		t.Error("HasUnit() = false for a cli declaring instanced")
	}
	if !c.Role.OnPath() {
		t.Error("OnPath() = false — declaring a unit must not take it off PATH")
	}
	if got, want := c.UnitName(), "mountbridge@.service"; got != want {
		t.Errorf("UnitName() = %q, want %q", got, want)
	}
}

// A gui is launched by the desktop and a helper by the payload, so a unit for
// either names something nothing would start. Refused, not ignored.
func TestUnitFieldsRefusedOnGUIAndHelper(t *testing.T) {
	for _, tc := range []struct {
		name string
		c    Component
		want string
	}{
		{"unit on a gui", Component{Name: "demo", Role: RoleGUI, Unit: "demo.service"}, "unit"},
		{"instanced on a gui", Component{Name: "demo", Role: RoleGUI, Instanced: true}, "instanced"},
		{"unit on a helper", Component{Name: "h", Role: RoleHelper, Unit: "h.service"}, "unit"},
		{"instanced on a helper", Component{Name: "h", Role: RoleHelper, Instanced: true}, "instanced"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := ValidateComponents([]Component{tc.c})
			if err == nil {
				t.Fatalf("want an error, got nil")
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error = %v, want it to mention %q", err, tc.want)
			}
		})
	}
}

// Args are the generated unit's ExecStart arguments, so they are meaningless
// without a unit. A silently dropped Args is a setting someone believed was in
// effect — the error names what to do instead.
func TestArgsWithoutAUnitAreRefused(t *testing.T) {
	err := ValidateComponents([]Component{
		{Name: "demo", Role: RoleCLI, Args: []string{"-x"}},
	})
	if err == nil {
		t.Fatal("want an error for args on a component with no unit")
	}
	if !strings.Contains(err.Error(), "args") {
		t.Errorf("error = %v, want it to mention args", err)
	}
	// And they are fine once the component actually has one.
	if err := ValidateComponents([]Component{
		{Name: "demo", Role: RoleCLI, Instanced: true, Args: []string{"-x"}},
	}); err != nil {
		t.Errorf("args alongside a declared unit must validate: %v", err)
	}
}

// RoleDaemon still implies a unit without declaring anything — that is what the
// role means.
func TestDaemonImpliesAUnit(t *testing.T) {
	c := Component{Name: "demod", Role: RoleDaemon}
	if !c.HasUnit() {
		t.Error("a daemon must have a unit without declaring one")
	}
	if c.Role.OnPath() {
		t.Error("a daemon must not be on PATH")
	}
	for _, r := range []Role{RoleGUI, RoleHelper} {
		if (Component{Name: "x", Role: r}).HasUnit() {
			t.Errorf("role %q must not imply a unit", r)
		}
	}
}

func TestUnitName(t *testing.T) {
	for _, tc := range []struct {
		name string
		c    Component
		want string
	}{
		{"plain", Component{Name: "demod", Role: RoleDaemon}, "demod.service"},
		{"instanced", Component{Name: "mountbridge", Role: RoleDaemon, Instanced: true}, "mountbridge@.service"},
		{"explicit", Component{Name: "demod", Role: RoleDaemon, Unit: "other.service"}, "other.service"},
		{"explicit without suffix", Component{Name: "demod", Role: RoleDaemon, Unit: "other"}, "other.service"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.c.UnitName(); got != tc.want {
				t.Errorf("UnitName() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestRelPathDefaultsToName(t *testing.T) {
	if got := (Component{Name: "demo"}).RelPath(); got != "demo" {
		t.Errorf("RelPath() = %q, want %q", got, "demo")
	}
	if got := (Component{Name: "demo", Rel: "bin/demo"}).RelPath(); got != "bin/demo" {
		t.Errorf("RelPath() = %q, want %q", got, "bin/demo")
	}
}

// Only cli is on PATH — the file-hierarchy(7) rule, in one place.
func TestOnlyCLIIsOnPath(t *testing.T) {
	for r, want := range map[Role]bool{
		RoleCLI: true, RoleDaemon: false, RoleGUI: false, RoleHelper: false,
	} {
		if got := r.OnPath(); got != want {
			t.Errorf("Role(%s).OnPath() = %v, want %v", r, got, want)
		}
	}
}

// Components must be reached by the whole-spec Validate, not only by a direct
// call — otherwise the check exists and never runs.
func TestSpecValidateReachesComponents(t *testing.T) {
	s := testSpec()
	s.Components = append(s.Components,
		Component{Name: "bad", Role: RoleCLI, Rel: "/absolute/path"})
	err := s.Validate()
	if err == nil {
		t.Fatal("Spec.Validate must reject an invalid component")
	}
	if !strings.Contains(err.Error(), "absolute") {
		t.Errorf("Spec.Validate error = %v, want the component failure", err)
	}
}
