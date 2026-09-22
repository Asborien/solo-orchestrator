#!/usr/bin/env bash
# tests/test-bl308-gitleaks-vendored-clean.sh — the shipped source must scan
# clean under the gitleaks rules the generated CI runs (## BL-308:).
#
# Every project born from init.sh carries copies of scripts/ and templates/,
# and its generated CI runs `gitleaks git --redact --exit-code 1` over its
# whole history. A declaration in a vendored script that LOOKS like a
# credential therefore turns every new project's first pull request red at
# the secret-detection step, before any governance step runs. Measured on
# 2026-09-22: a compound `local` in scripts/check-gate.sh declared a variable
# whose name ended in the word the `generic-api-key` rule keys on, assigned
# it an empty string, and declared the next variable on the same line; the
# rule read that as name=value, and a project's first PR failed with
# "leaks found: 1". (The shape is described rather than quoted so this file
# does not trip the same rule.)
#
# G1 pins the shipped surface clean. C1/C2 pin that the scanner is LIVE over
# the same surface — a planted AWS-shaped key and a planted generic-shaped key
# must each be found — so the fix cannot be "disable the rule" or an
# allowlist wide enough to swallow a real credential.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }
skip_() { echo "  [SKIP] $1 — $2"; SKIPPED=$((SKIPPED + 1)); }

command -v jq >/dev/null 2>&1 || {
  echo "jq is required for tests/test-bl308-gitleaks-vendored-clean.sh" >&2; exit 2; }

# GITLEAKS-ABSENT IS A SKIP LOCALLY AND A FAILURE IN CI (the ## BL-288: posture).
# Every case here is a real scan; a green check credited with a scan that
# never ran is exactly what a project's red first PR would then contradict.
HAVE_GITLEAKS=0
command -v gitleaks >/dev/null 2>&1 && HAVE_GITLEAKS=1
GITLEAKS_ABSENT_IS_FATAL=0
[ -n "${CI:-}" ] && GITLEAKS_ABSENT_IS_FATAL=1

TMPS=""
cleanup() { [ -n "$TMPS" ] && rm -rf $TMPS; return 0; }
trap cleanup EXIT INT TERM
newtmp() { local d; d=$(mktemp -d); TMPS="$TMPS $d"; printf '%s\n' "$d"; }

# The surface init.sh ships into every project is drawn from these. docs/ is
# deliberately NOT here: init.sh copies named files out of it, and the design
# notes beside them carry planted AKIA fixtures that never leave this repo.
SHIPPED_SURFACE="scripts templates init.sh"

# Assembled from halves so this file does not itself carry a scanner-shaped
# literal. BASE32-VALIDITY IS LOAD-BEARING for the AWS plant: the
# `aws-access-token` rule requires [A-Z2-7] after `AKIA`. The generic plant
# needs letters AND digits, because the `generic-api-key` rule allowlists a
# secret that is letters only.
AWS_PLANT="AKIAQZ7X4M2N""PLKJ3HRD"
GENERIC_PLANT="b7Kq2mZ9xV4t""R8pL3nW6yH1s"

# scan_dir DIR REPORT — `gitleaks dir` with the default rules, no config, no
# ignore file, exactly what a generated project's CI has. Prints the finding
# count from the JSON report; rc is gitleaks' own.
scan_dir() {
  local dir="$1" report="$2" rc=0
  gitleaks dir "$dir" --no-banner --redact --exit-code 1 \
    --report-format json --report-path "$report" >/dev/null 2>&1 || rc=$?
  [ -s "$report" ] || printf '[]\n' > "$report"
  return "$rc"
}
findings() { jq -r 'length' "$1"; }
rule_hits() { jq -r --arg r "$2" '[.[] | select(.RuleID == $r)] | length' "$1"; }
describe()  { jq -r '.[] | "\(.RuleID) \(.File):\(.StartLine) \(.Match)"' "$1"; }

# mk_surface DIR — the shipped surface, copied, so plants never touch the tree.
mk_surface() {
  local d="$1" p
  for p in $SHIPPED_SURFACE; do
    cp -R "$REPO_ROOT/$p" "$d/$p" || return 1
  done
}

if [ "$HAVE_GITLEAKS" -eq 0 ]; then
  if [ "$GITLEAKS_ABSENT_IS_FATAL" -eq 1 ]; then
    fail_ "setup" "gitleaks is not installed and CI is set — every case here is a real scan; a green check credited with a scan that never ran is what this suite exists to prevent"
  else
    skip_ "the whole suite" "gitleaks not installed (install it to run BL-308's proofs locally)"
  fi
else
  # ── G1: the shipped surface scans clean ──────────────────────────────────
  D="$(newtmp)"
  mkdir -p "$D/clean"
  if ! mk_surface "$D/clean"; then
    fail_ "G1 setup" "could not copy the shipped surface"
  else
    rc=0; scan_dir "$D/clean" "$D/clean.json" || rc=$?
    n=$(findings "$D/clean.json")
    if [ "$rc" -eq 0 ] && [ "$n" -eq 0 ]; then
      pass "G1: gitleaks reports 0 findings over $SHIPPED_SURFACE (rc 0)"
    else
      fail_ "G1" "rc=$rc findings=$n over the shipped surface — a project born from this tree fails its first PR at secret detection: $(describe "$D/clean.json" | tr '\n' ';')"
    fi
  fi

  # ── C1: the scanner is live over that surface — an AWS-shaped plant is found ─
  mkdir -p "$D/aws"
  if ! mk_surface "$D/aws"; then
    fail_ "C1 setup" "could not copy the shipped surface"
  else
    printf '\n# planted by the BL-308 control\nAWS_TEST_ID=%s\n' "$AWS_PLANT" >> "$D/aws/scripts/check-gate.sh"
    rc=0; scan_dir "$D/aws" "$D/aws.json" || rc=$?
    n=$(rule_hits "$D/aws.json" aws-access-token)
    if [ "$rc" -eq 1 ] && [ "$n" -eq 1 ]; then
      pass "C1: a planted AWS-shaped key in scripts/check-gate.sh is found (rc 1, aws-access-token x1)"
    else
      fail_ "C1" "rc=$rc aws-access-token hits=$n (want rc 1, 1 hit) — the scanner is not live over the surface G1 claims clean"
    fi
  fi

  # ── C2: the generic-api-key rule is live — the rule the defect tripped ─────
  mkdir -p "$D/generic"
  if ! mk_surface "$D/generic"; then
    fail_ "C2 setup" "could not copy the shipped surface"
  else
    printf '\n# planted by the BL-308 control\napi_key="%s"\n' "$GENERIC_PLANT" >> "$D/generic/scripts/check-gate.sh"
    rc=0; scan_dir "$D/generic" "$D/generic.json" || rc=$?
    # The plant, by rule AND line, so this stays a control of the rule's
    # liveness and not a second copy of G1's zero-count.
    n=$(jq -r --arg r generic-api-key '[.[] | select(.RuleID == $r and (.File | endswith("scripts/check-gate.sh")) and (.Match | startswith("api_key=")))] | length' "$D/generic.json")
    if [ "$rc" -eq 1 ] && [ "$n" -eq 1 ]; then
      pass "C2: a planted generic-shaped key in scripts/check-gate.sh is found (rc 1, generic-api-key on the planted line)"
    else
      fail_ "C2" "rc=$rc planted-line hits=$n (want rc 1, 1) — the rule the defect tripped is not live over the surface, so G1 proves nothing"
    fi
  fi

  # ── C3: no scanner config or ignore file is shipped ─────────────────────
  # G1 is a claim about the DEFAULT rules. A .gitleaks.toml or .gitleaksignore
  # at the repo root would be scanned by nothing here (the copies above carry
  # neither) and would make a green G1 disagree with a generated project.
  # If one is ever shipped on purpose, extend mk_surface to copy it and G1
  # tests the shipped config too.
  if [ ! -e "$REPO_ROOT/.gitleaks.toml" ] && [ ! -e "$REPO_ROOT/.gitleaksignore" ]; then
    pass "C3: no .gitleaks.toml or .gitleaksignore at the repo root — G1 ran the same default rules a generated project's CI runs"
  else
    fail_ "C3" "a scanner config or ignore file exists at the repo root; G1 scanned copies without it, so its verdict may not match a generated project — copy it in mk_surface and re-measure"
  fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed, $SKIPPED skipped"
[ "$FAILED" -eq 0 ]
