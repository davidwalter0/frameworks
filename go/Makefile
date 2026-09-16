MODULE  := github.com/davidwalter0/frameworks/go
COV_OUT := coverage.out

# No cgo anywhere in this module. The installer must be a single static
# binary that runs on a host with no toolchain, which is the whole point of
# the go:embed payload pattern it replaces.
export CGO_ENABLED := 0

GO := go

.PHONY: all build install check deps lint vet vuln test cov cov-html tidy fmt fmt-check clean

all: build

# Every binary lands in bin/ — never the repo root.
build:
	@mkdir -p bin
	@if ls cmd/*/ >/dev/null 2>&1; then \
		for d in cmd/*/; do \
			n=$$(basename $$d); \
			echo "building bin/$$n"; \
			$(GO) build -o bin/$$n ./$$d || exit 1; \
		done; \
	else \
		echo "no cmd/ entrypoints yet; building all packages"; \
		$(GO) build ./...; \
	fi

install:
	@for d in cmd/*/; do $(GO) install ./$$d || exit 1; done

# The check suite, in the order the checkpoint gate runs it. First failure
# stops the commit.
#
# `deps` runs FIRST so a missing instrument is reported as a missing
# instrument, once, rather than as whatever the stage that needed it happens to
# say. Its exit codes are distinct: 1 = a required prerequisite is absent,
# 2 = the manifest itself is unreadable (the check never ran, which is not the
# same as the check failing).
check: deps fmt-check lint vet vuln test cov

# Environment prerequisites and the POLICY for each one's absence live in
# ../deps.yaml, not in shell scattered through this file. See go/pkg/deps.
#
# BOOTSTRAP: `go` and `make` are NOT in the manifest and cannot be — a Go
# program cannot check whether Go is installed. They are checked here, inline,
# and nowhere else.
# BUILT, NOT `go run` — and this is load-bearing, not a style preference.
#
# `go run` does NOT propagate a program's exit status: it prints "exit status
# N" and exits 1 itself. Measured: a program calling os.Exit(2) reports rc=1
# under `go run` and rc=2 when built. deps' whole contract is that its three
# exit codes are distinguishable (0 ok / 1 a required tool is missing / 2 the
# manifest is unreadable, i.e. the check never ran), so invoking it through
# `go run` would collapse 2 into 1 and reintroduce exactly the conflation this
# package exists to remove.
#
# gen-icon is invoked with `go run` elsewhere in the family and that is fine —
# it does not encode meaning in its exit status.
DEPS_BIN := bin/deps
$(DEPS_BIN): cmd/deps/main.go $(wildcard pkg/deps/*.go)
	@$(GO) build -o $@ ./cmd/deps

deps: $(DEPS_BIN)
	@command -v $(GO) >/dev/null 2>&1 || { \
		echo "ERROR: no Go toolchain on PATH — run: eval \"\$$(go-version path)\"" >&2; exit 1; }
	@$(DEPS_BIN) --dir .. --profile check

fmt:
	$(GO) fmt ./...

fmt-check:
	@out=$$(gofmt -l . 2>/dev/null); \
	if [ -n "$$out" ]; then echo "gofmt drift in:"; echo "$$out"; exit 1; \
	else echo "fmt-check OK"; fi

# A GATE TARGET MUST NOT PASS WITHOUT RUNNING ITS TOOL.
#
# This previously fell back to `go vet` and exited 0 when golangci-lint was
# absent — so a host without the linter reported lint as PASSED while no linter
# ran. Two things made that worse than it looks: `check` already runs `vet` as
# its own target, so the fallback was a pure no-op; and the message went to
# stdout without failing, which in CI log volume is invisible.
#
# A missing instrument is a PROJECT gap (the language supports it, this host
# does not have it), not an ecosystem gap. The check-suite convention requires
# failing loudly on the first and only recording the second.
#
# The presence check that used to live here is now declared in ../deps.yaml as
# policy `required`, and enforced by the `deps` target above. The reasoning is
# unchanged — only its location, and the fact that it is now stated once for
# the whole repo instead of once per stage.
lint:
	golangci-lint run ./...

vet:
	$(GO) vet ./...

# Likewise declared `required` in ../deps.yaml. A gate must not report a pass
# it never computed.
vuln:
	govulncheck ./...

# make test [pkg=./path/to/package] [fn=TestName]
pkg ?= ./...
test:
ifdef fn
	$(GO) test -run '$(fn)' $(pkg)
else
	$(GO) test $(pkg)
endif

# Minimum total coverage. `cov` fails below it. Raise deliberately; never lower
# it to make a red gate green — that is the same class of defect as the lint
# fallback this Makefile used to carry.
COV_MIN ?= 70

# THIS TARGET PREVIOUSLY COULD NOT FAIL.
#
# It ran `go test ... | grep | sed | awk | sort | (subshell)` as ONE pipeline.
# make's shell has no `pipefail`, so a pipeline's exit status is its LAST
# command's — the subshell that prints the table, which always succeeds.
# A genuine TEST FAILURE was therefore swallowed and `cov` reported green.
# Verified: `(exit 1) | grep x | sort | (echo ok)` exits 0.
#
# So the test run is now a SEPARATE statement whose status propagates, and the
# formatting pipeline only ever consumes a file that already exists.
cov:
	@$(GO) test -coverprofile=$(COV_OUT) ./... > $(COV_OUT).log 2>&1 || { \
		echo "ERROR: tests failed during coverage run" >&2; \
		cat $(COV_OUT).log >&2; rm -f $(COV_OUT).log; exit 1; }
	@grep -E 'coverage:|no test files' $(COV_OUT).log | \
		sed 's/\t/ /g; s|.*$(MODULE)/||; s|^ok *$(MODULE)|.|' | \
		awk '{ pkg=$$1; cov="0.0%"; for(i=1;i<=NF;i++) if($$i ~ /%/) cov=$$i; printf "%-45s %s\n", pkg, cov }' | \
		sort | \
		(echo ""; printf "%-45s %s\n" "Package" "Coverage"; \
		 printf "%-45s %s\n" "─────────────────────────────────────────────" "────────"; \
		 cat; \
		 printf "%-45s %s\n" "─────────────────────────────────────────────" "────────"; \
		 printf "%-45s %s\n" "TOTAL" "$$($(GO) tool cover -func=$(COV_OUT) 2>/dev/null | tail -1 | awk '{print $$NF}')")
	@rm -f $(COV_OUT).log
	@total=$$($(GO) tool cover -func=$(COV_OUT) 2>/dev/null | tail -1 | awk '{print $$NF}' | tr -d '%'); \
	if [ -z "$$total" ]; then \
		echo "ERROR: could not read a coverage total from $(COV_OUT)" >&2; exit 1; fi; \
	awk -v t="$$total" -v m="$(COV_MIN)" 'BEGIN{ \
		if (t+0 < m+0) { printf "ERROR: coverage %.1f%% is below the %s%% floor\n", t, m > "/dev/stderr"; exit 1 } \
		else { printf "coverage %.1f%% >= %s%% floor\n", t, m } }'

cov-html:
	$(GO) test -coverprofile=$(COV_OUT) ./...
	$(GO) tool cover -html=$(COV_OUT)

tidy:
	$(GO) mod tidy

clean:
	rm -rf bin $(COV_OUT)
