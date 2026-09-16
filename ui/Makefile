# frameworks/ui — Dart/Flutter half of the framework.
# Check-suite entrypoints (Dart flavour of the polyglot suite):
#   lint/vet -> analyze   test -> test (CHUNKED)   cov -> cov
#
# This gate did not exist until 2026-07-29. It was added because the tranche-0
# copy landed 220 Dart files here while the repo's CI covered only go/, so the
# check suite was silently reporting a pass for a language it never ran. That is
# a PROJECT gap, not an ecosystem gap, and the Build Tools convention requires
# closing it rather than recording a skip.
.PHONY: all check get analyze test test-only cov fmt fmt-check clean packages vuln deps-guard

# Flutter is frequently NOT on PATH in these workspaces. Prefer whatever
# resolves on PATH; fall back to the common $(HOME)/flutter install layout
# so a fresh clone still has a sane default to override with `?=`.
FLUTTER ?= $(or $(shell command -v flutter 2>/dev/null),$(HOME)/flutter/bin/flutter)
DART    ?= $(or $(shell command -v dart 2>/dev/null),$(HOME)/flutter/bin/dart)

# Every package under pkg/ that has a pubspec. cmd/ joins this list once ui0
# exists; it is empty today.
PACKAGES := $(dir $(wildcard pkg/*/pubspec.yaml))

# Packages that MUST stay state-management agnostic. This is deliberately a
# subset of PACKAGES rather than all of it: desktop_kit is the widget tier and
# has to compose under any state solution, but the app-shell tier (ui/pkg/app_kit,
# not yet built) is expected to carry Riverpod by design. A blanket guard would
# make that tier unlandable.
#
# NOTE: the shape of this guard is itself an open decision — mgmt todo bd91e7e9
# proposes INVERTING it (require Riverpod 3, forbid provider and riverpod 2.x)
# as part of standardizing the family. That is a design decision, not a copy
# fix, so this restores the kit's semantics unchanged and leaves the inversion
# to that todo. Restoring a dropped guard and changing what it guards are two
# different changes.
AGNOSTIC_PACKAGES := pkg/desktop_kit/

# Dependencies that must never appear in an agnostic package's pubspec.
FORBIDDEN_DEPS := flutter_riverpod|riverpod|provider|flex_color_scheme|package_info_plus

# CHUNKING IS OPTIONAL AND, ON THE SUITES MEASURED SO FAR, COUNTERPRODUCTIVE.
#
# An earlier revision of this file declared chunking MANDATORY on the strength of
# a reported deadlock: "`flutter test` with 48 files in ONE invocation deadlocks,
# 4 runs out of 4". Re-measured 2026-07-30 against the kit's own 98-file suite,
# that DOES NOT REPRODUCE:
#
#   whole suite, one invocation : 64s / 73s / 97s across three runs,
#                                 1,818 tests, all passed, peak RSS 468MB
#   chunked at 24, 19 invocations: ~250s, peak RSS 418-461MB per chunk
#
# So one invocation is roughly 4x FASTER for about 2% less peak memory. The
# earlier "chunking is 2.5-3.8x faster" figure compared chunks against
# one-invocation-PER-FILE, which nobody runs; against the whole suite it is
# simply slower. The "~640MB + 96MB x concurrency" model also overestimates —
# it predicts 736MB at concurrency 1 and the whole run peaked at 468MB.
#
# WHAT IS STILL OPEN, so this is not over-corrected in turn: kit todo b4749c15
# records a genuine OOM at ~2,656 tests. The kit's suite is 1,818. voicelab is
# larger and was not re-measured. So a big enough suite may still need chunking —
# CHUNK is kept for that case, and for bisecting a hang, not as a default.
#
# Set CHUNK to a number to opt in: `make test CHUNK=24`. Unset (default), the
# suite runs in one invocation.
CHUNK ?=

all: check

## the gate. cov is reported, not thresholded — no threshold is defined yet.
##
## `get` FIRST, and not merely for convenience. `dart format` reads each
## package's language version from its .dart_tool/package_config.json; with no
## such file it falls back to the NEWEST language version, which selects a
## different formatter style. In a fresh worktree — which is exactly where a
## release gate runs — that turns fmt-check into "152 of 219 files changed": a
## whole-tree reflow presented as a lint failure, whose obvious "fix" is to
## commit the reflow.
##
## Measured here 2026-08-07 on the integration worktree, which had no
## .dart_tool: fmt-check alone reported 152 changed and exited 2; after
## `make get`, 0 changed. Same defect and same fix as textloom's root Makefile.
##
## `deps-guard` and `vuln` were RESTORED here 2026-08-07. Both existed in the
## kit's own Makefile and neither survived the copy into frameworks, so from
## tranche 0 until now the Dart half had no dependency guard and no
## vulnerability stage — a silent capability regression introduced by the move
## itself, not by any code change.
check: get fmt-check deps-guard analyze test vuln

## list the packages this gate covers (sanity check when adding a package)
packages:
	@echo "PACKAGES:           $(PACKAGES)"
	@echo "AGNOSTIC_PACKAGES:  $(AGNOSTIC_PACKAGES)"

## fail if a state-management dependency leaks into a package that must stay
## agnostic. Carried over from the kit's Makefile unchanged; see the
## AGNOSTIC_PACKAGES comment for why it is scoped rather than global.
deps-guard:
	@set -e; for p in $(AGNOSTIC_PACKAGES); do \
	  if [ ! -f "$$p/pubspec.yaml" ]; then \
	    echo "deps-guard: ERROR $$p has no pubspec.yaml — AGNOSTIC_PACKAGES is stale"; \
	    exit 1; \
	  fi; \
	  if grep -Eq '^[[:space:]]*($(FORBIDDEN_DEPS))[[:space:]]*:' "$$p/pubspec.yaml"; then \
	    echo "deps-guard: ERROR forbidden state-management dependency in $$p"; \
	    grep -En '^[[:space:]]*($(FORBIDDEN_DEPS))[[:space:]]*:' "$$p/pubspec.yaml"; \
	    exit 1; \
	  fi; \
	  echo "deps-guard OK: $$p carries no state-management dependency"; \
	done

## vulnerability DETECTION over every package lockfile, gated by
## tools/osv-gate.sh (severity floor + fix-available).
##
## Lockfiles are passed EXPLICITLY with -L. Never `-r`: measured 2026-08-07 from
## inside a worktree, `osv-scanner scan source -r .` reports "No package sources
## found" and exits 0, because the primary checkout's .gitignore excludes
## .worktree/ and the git-root walk does not follow a worktree's .git-file
## indirection. Since work always happens in a worktree, `-r` would pass
## vacuously exactly where the gate runs.
##
## DETECTION ONLY. A finding here is a hypothesis, not a verdict — Dart has no
## govulncheck equivalent, so "is the vulnerable symbol actually reached?" has
## to be answered separately (ast, partially) and unresolved findings should be
## recorded as unresolved rather than accepted or bumped on faith.
vuln:
	@locks=""; for p in $(PACKAGES); do \
	  [ -f "$$p/pubspec.lock" ] && locks="$$locks $$p/pubspec.lock"; \
	done; \
	if [ -z "$$locks" ]; then \
	  echo "vuln: ERROR no pubspec.lock found under $(PACKAGES) — nothing scanned"; \
	  exit 1; \
	fi; \
	echo "--- osv-gate$$locks"; \
	tools/osv-gate.sh $$locks

## resolve dependencies for every package (offline-friendly)
get:
	@set -e; for p in $(PACKAGES); do \
	  echo "--- pub get $$p"; \
	  (cd $$p && $(FLUTTER) pub get --offline || $(FLUTTER) pub get); \
	done

## auto-format
fmt:
	$(DART) format .

## verify formatting without writing (gate)
fmt-check:
	$(DART) format --output=none --set-exit-if-changed .

## lint + static analysis, per package
analyze:
	@set -e; for p in $(PACKAGES); do \
	  echo "--- analyze $$p"; \
	  (cd $$p && $(FLUTTER) analyze); \
	done

## unit + widget tests. One invocation per package by default — measured faster
## and no worse on memory than chunking (see the CHUNK comment above).
## Pass CHUNK=<n> to split into n-file invocations when bisecting a hang or
## working around a suite large enough to OOM.
test:
	@set -e; for p in $(PACKAGES); do \
	  [ -d "$$p/test" ] || continue; \
	  if [ -n "$(CHUNK)" ]; then \
	    echo "--- test $$p (chunks of $(CHUNK))"; \
	    ( cd $$p && find test -name '*_test.dart' | sort | xargs -n $(CHUNK) $(FLUTTER) test ); \
	  else \
	    echo "--- test $$p"; \
	    ( cd $$p && $(FLUTTER) test ); \
	  fi; \
	done

## one file or directory, package-relative — the iteration loop while writing a
## test, which `test` (whole package, ~1850 tests) is too slow to serve:
##
##   make test-only PKG=pkg/desktop_kit ONLY=test/layout/adaptive_layout_test.dart
##
## Added because its absence was being answered with a bare `flutter test <file>`
## outside the build tool. A fallback with no closing obligation becomes the
## permanent path, so the target exists rather than the habit. Deliberately NOT
## part of `check`: it runs a subset by construction and must never be mistaken
## for the gate.
test-only:
	@[ -n "$(PKG)" ] || { echo "test-only: set PKG=<package dir>, e.g. PKG=pkg/desktop_kit"; exit 1; }
	@[ -d "$(PKG)/test" ] || { echo "test-only: $(PKG) has no test/ directory"; exit 1; }
	cd $(PKG) && $(FLUTTER) test $(ONLY)

## coverage per package, summary to stdout. Runs the suite WHOLE, so it is not
## part of `check`: on a package with more than ~24 test files this can hit the
## deadlock above. Use it per-package and expect it to be slow.
##
## The `|| true` this used to carry on the test run was the same defect the Go
## Makefile had in `lint` and `cov`: a gate target that reports success without
## its work having succeeded. A coverage number produced by a failing suite is
## worse than no number, because it looks like evidence.
##
## lcov's absence is genuinely different and is NOT a failure: the profile is
## still written and usable, only the human summary is missing. That is an
## ecosystem gap, recorded; the test failure above is a project gap, fatal.
cov:
	@set -e; for p in $(PACKAGES); do \
	  [ -d "$$p/test" ] || continue; \
	  echo "--- cov $$p"; \
	  (cd $$p && $(FLUTTER) test --coverage) || { \
	    echo "ERROR: tests failed during coverage run in $$p" >&2; exit 1; }; \
	  if command -v lcov >/dev/null 2>&1 && [ -f "$$p/coverage/lcov.info" ]; then \
	    lcov --summary $$p/coverage/lcov.info; \
	  else \
	    echo "    (lcov not installed; profile at $$p/coverage/lcov.info)"; \
	  fi; \
	done

clean:
	@set -e; for p in $(PACKAGES); do \
	  (cd $$p && $(FLUTTER) clean >/dev/null 2>&1 || true); \
	done
	rm -rf coverage
