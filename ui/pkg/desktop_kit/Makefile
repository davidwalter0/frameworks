# desktop_kit — shared Flutter desktop UI components.
#
# THE GATE FOR THIS PACKAGE IS ../../Makefile (frameworks/ui), NOT THIS FILE.
# `make -C ui check` drives every package under ui/pkg/ and is what CI runs.
# This Makefile is retained for per-package convenience (`make analyze` while
# working inside the package) and deliberately no longer defines a `check`
# target, so there is exactly one gate rather than two that can disagree.
#
# WHAT WAS REMOVED, 2026-08-07, and why. As copied from the kit this file's
# `check` depended on `analyze-example`, `test-example` and `orgsupport-check`,
# which run `cd example` and `$(MAKE) -C tools/orgsupport`. NEITHER DIRECTORY
# WAS COPIED — the tranche-0 copy deliberately excluded them — so the target
# did not merely carry dead references, it FAILED on a missing directory for
# anyone who ran it. Upstream has since retired example/ outright (kit 936e0bf),
# so these are gone there too and this is not a divergence to reconcile later.
#
# `deps-guard` and `vuln` moved UP to frameworks/ui/Makefile rather than being
# deleted: they were dropped entirely in the copy, which left the Dart half with
# no dependency guard and no vulnerability stage. They now run over every
# package from the one gate.
.PHONY: all get fmt fmt-check analyze test cov cov-html clean

FLUTTER ?= flutter
DART    ?= dart

all: analyze

## resolve dependencies (offline-friendly: cache first, then network)
get:
	$(FLUTTER) pub get --offline || $(FLUTTER) pub get

## auto-format sources
fmt:
	$(DART) format .

## verify formatting without writing (CI gate)
fmt-check:
	$(DART) format --output=none --set-exit-if-changed .

## lint + static analysis
analyze:
	$(FLUTTER) analyze

## unit + widget tests
## test: the whole suite, or only TEST_ARGS (paths/flags), e.g.
##   make test TEST_ARGS=test/settings/settings_category_list_test.dart
TEST_ARGS ?=
test:
	$(FLUTTER) test $(TEST_ARGS)

## coverage profile + summary to stdout
cov:
	$(FLUTTER) test --coverage
	@if command -v lcov >/dev/null 2>&1; then \
		lcov --summary coverage/lcov.info; \
	else \
		echo "lcov not installed; raw profile at coverage/lcov.info"; \
	fi

## HTML coverage report
cov-html:
	$(FLUTTER) test --coverage
	genhtml coverage/lcov.info -o coverage/html

# `vuln` and `deps-guard` intentionally do NOT live here any more — they are
# defined once in ../../Makefile and run over every package from the single
# gate. The versions this file used to carry are worth recording as removed
# rather than silently dropped:
#
#   vuln:       ran `osv-scanner --lockfile=pubspec.lock || true`. The `|| true`
#               made it a reporter that could not fail, and the `--lockfile=`
#               flag is the pre-v2 form. Replaced by ../../tools/osv-gate.sh,
#               which gates on severity + fix-availability and exits non-zero.
#   deps-guard: identical grep, replaced verbatim upstream in ../../Makefile so
#               it can be scoped (AGNOSTIC_PACKAGES) once the app-shell tier —
#               which is expected to carry Riverpod by design — lands.

clean:
	$(FLUTTER) clean || true
	rm -rf coverage .dart_tool build
