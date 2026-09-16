package main

import (
	"strings"
	"testing"
)

func TestParseOptionsDefaults(t *testing.T) {
	opts, err := parseOptions(nil)
	if err != nil {
		t.Fatal(err)
	}
	if opts.Offline {
		t.Error("Offline should default false — the fetch is the point")
	}
	// Resolved at parse time from the executable, so assert the shape rather
	// than a literal path.
	if !strings.HasSuffix(opts.Config, "consumers.yaml") {
		t.Errorf("Config default should end in consumers.yaml: got %q", opts.Config)
	}
}

func TestParseOptionsOverrides(t *testing.T) {
	opts, err := parseOptions([]string{"--config", "/tmp/c.yaml", "--offline"})
	if err != nil {
		t.Fatal(err)
	}
	if opts.Config != "/tmp/c.yaml" {
		t.Errorf("--config: got %q", opts.Config)
	}
	if !opts.Offline {
		t.Error("--offline was not set")
	}
}

func TestParseOptionsRejectsUnknownFlag(t *testing.T) {
	if _, err := parseOptions([]string{"--nope"}); err == nil {
		t.Fatal("an unknown flag must be an error, not silently ignored")
	}
}
