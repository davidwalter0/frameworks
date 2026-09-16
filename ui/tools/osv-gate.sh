#!/usr/bin/env bash
#
# osv-gate.sh — a severity + fixability gate over osv-scanner for Dart lockfiles.
#
# WHY THIS EXISTS. osv-scanner (v2.3.8) has neither --fail-on-severity nor
# --ignore-unfixed. It exits non-zero when it finds ANYTHING, which is too blunt
# to gate on: a lockfile carrying one unfixable advisory would be permanently
# red, and a permanently-red gate gets muted. A muted gate is indistinguishable
# from no gate.
#
# So this wrapper reproduces the --fail-on high --ignore-unfixed behaviour:
#   FAIL  on findings that are at/above the severity floor AND have a fix
#   REPORT everything else, and exit 0
#
# WHAT IT REPLACES. The kit's own `vuln` target ran
# `osv-scanner --lockfile=pubspec.lock || true` — the `|| true` made it a
# reporter, never a gate. That target was also dropped entirely when
# desktop_kit was copied into frameworks, so the Dart half had no vulnerability
# stage at all until this script.
#
# TARGET LOCKFILES EXPLICITLY. Never use `-r`. Measured in this repo
# 2026-08-07, from inside .worktree/chore/copy-hygiene:
#   osv-scanner scan source -L pkg/desktop_kit/pubspec.lock  -> 48 packages scanned
#   osv-scanner scan source -r .                             -> "No package sources
#                                                               found", EXIT 0
# The primary checkout's .gitignore excludes .worktree/, and osv-scanner's
# git-root walk does not understand a worktree's .git-FILE indirection, so it
# inherits that exclusion and matches its own root. Since substantive work
# always happens inside a worktree, an `-r` gate would pass vacuously in exactly
# the place it is normally run.
#
# COUNTS ARE NOT STABLE. osv-scanner queries osv.dev live; runs minutes apart
# return different totals. Gate on the mechanism (severity + fixability), never
# on a recorded number.
#
# Usage:
#   osv-gate.sh <lockfile> [<lockfile>...]
#   SEVERITY_FLOOR=7.0 osv-gate.sh pkg/desktop_kit/pubspec.lock
#   OSV_GATE_JSON=fixture.json osv-gate.sh      # classify a captured report
#
# Env:
#   SEVERITY_FLOOR  CVSS base score at/above which a FIXABLE finding blocks.
#                   Default 7.0 (the CVSS v3 floor for HIGH).
#   OSV_GATE_JSON   Read a previously captured osv-scanner JSON report instead
#                   of running a scan. This is what makes the FAILURE path
#                   testable — see tools/testdata/.
set -uo pipefail

SEVERITY_FLOOR="${SEVERITY_FLOOR:-7.0}"

die() { printf 'osv-gate: %s\n' "$*" >&2; exit 1; }

# --- Tool presence is its OWN branch. -----------------------------------------
# A missing tool and a real finding are two different conditions and must never
# share an exit path: `(scan && ok) || fail` reports "vulnerable" when the
# scanner is merely absent, and the opposite arrangement passes green when it
# cannot run at all.
command -v jq >/dev/null 2>&1 || die "jq is required. install: apt install jq"

report=""
cleanup() { [ -n "$report" ] && rm -f "$report"; }
trap cleanup EXIT

if [ -n "${OSV_GATE_JSON:-}" ]; then
  [ -f "$OSV_GATE_JSON" ] || die "OSV_GATE_JSON=$OSV_GATE_JSON does not exist"
  report="$(mktemp)"; cp "$OSV_GATE_JSON" "$report"
  printf 'osv-gate: classifying captured report %s (no scan run)\n' "$OSV_GATE_JSON"
else
  [ "$#" -gt 0 ] || die "usage: osv-gate.sh <lockfile> [<lockfile>...]"
  command -v osv-scanner >/dev/null 2>&1 || die \
    "osv-scanner is required. install a PINNED version:
       go install github.com/google/osv-scanner/v2/cmd/osv-scanner@v2.3.8"

  args=()
  for f in "$@"; do
    [ -f "$f" ] || die "lockfile not found: $f"
    args+=(-L "$f")
  done

  report="$(mktemp)"
  osv-scanner scan source "${args[@]}" --format json >"$report" 2>/dev/null
  rc=$?
  # 0 = clean, 1 = findings present. Anything else is the scanner failing to
  # run, which must not be mistaken for a clean result.
  if [ "$rc" -gt 1 ]; then
    die "osv-scanner exited $rc (scan failed; this is NOT a clean result)"
  fi
fi

jq -e . "$report" >/dev/null 2>&1 || die "osv-scanner did not emit valid JSON"

# --- Flatten to one row per vulnerability. ------------------------------------
# Severity comes from the package's `groups[].max_severity` (a CVSS base score
# as a string) for the group containing this id. Fixability is the presence of
# any `affected[].ranges[].events[].fixed`.
rows="$(jq -c '
  [ .results[]?                                        as $r
    | $r.packages[]?                                   as $p
    | $p.vulnerabilities[]?                            as $v
    | { source:   ($r.source.path // "?"),
        pkg:      ($p.package.name // "?"),
        version:  ($p.package.version // "?"),
        id:       ($v.id // "?"),
        severity: ( [ $p.groups[]? | select((.ids // []) | index($v.id)) | .max_severity ]
                    | map(select(. != null and . != "")) | first // "" ),
        fixed:    ( [ $v.affected[]?.ranges[]?.events[]? | select(has("fixed")) | .fixed ]
                    | first // null ) } ]
' "$report")"

total="$(jq 'length' <<<"$rows")"

if [ "$total" -eq 0 ]; then
  printf 'osv-gate: no advisories. PASS\n'
  exit 0
fi

blocking="$(jq -c --argjson floor "$SEVERITY_FLOOR" '
  map(select(.fixed != null and ((.severity | tonumber? ) // 0) >= $floor))' <<<"$rows")"
other="$(jq -c --argjson floor "$SEVERITY_FLOOR" '
  map(select((.fixed == null) or (((.severity | tonumber?) // 0) < $floor)))' <<<"$rows")"

nblock="$(jq 'length' <<<"$blocking")"
nother="$(jq 'length' <<<"$other")"

if [ "$nother" -gt 0 ]; then
  printf '\nosv-gate: %d advisory/advisories reported, not blocking (no fix available, or below CVSS %s):\n' \
    "$nother" "$SEVERITY_FLOOR"
  jq -r '.[] | "  \(.id)  \(.pkg)@\(.version)  sev=\(if .severity == "" then "?" else .severity end)  fix=\(.fixed // "none")"' <<<"$other"
  printf '  ^ these do NOT fail the gate. An unexplained red scan is indistinguishable\n'
  printf '    from an ignored one, so they are surfaced rather than filtered silently.\n'
fi

if [ "$nblock" -gt 0 ]; then
  printf '\nosv-gate: %d FIXABLE advisory/advisories at or above CVSS %s:\n' "$nblock" "$SEVERITY_FLOOR"
  jq -r '.[] | "  \(.id)  \(.pkg)@\(.version)  sev=\(.severity)  fixed-in=\(.fixed)  [\(.source)]"' <<<"$blocking"
  printf '\n  Remediation:  osv-scanner fix --lockfile <path>\n'
  printf '  FAIL\n'
  exit 1
fi

printf '\nosv-gate: no fixable advisory at or above CVSS %s. PASS\n' "$SEVERITY_FLOOR"
exit 0
