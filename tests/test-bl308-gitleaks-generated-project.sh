#!/usr/bin/env bash
# tests/test-bl308-gitleaks-generated-project.sh — a project born from init.sh
# passes the exact secret-detection scan its own generated CI runs (## BL-308:).
#
# The unit-lane sibling (tests/test-bl308-gitleaks-vendored-clean.sh) scans the
# shipped surface in THIS repo with `gitleaks dir`. This suite closes the gap
# between that and the operator's first pull request: it generates a project,
# then runs `gitleaks git --redact --exit-code 1` over the project's history,
# which is the step every generated ci.yml carries (`# BL-151` in
# templates/pipelines/ci/github/*.yml). Invokes init.sh, so it lives in the
# full lane only.
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
  echo "jq is required for tests/test-bl308-gitleaks-generated-project.sh" >&2; exit 2; }

# GITLEAKS-ABSENT IS A SKIP LOCALLY AND A FAILURE IN CI (the ## BL-288: posture).
HAVE_GITLEAKS=0
command -v gitleaks >/dev/null 2>&1 && HAVE_GITLEAKS=1
GITLEAKS_ABSENT_IS_FATAL=0
[ -n "${CI:-}" ] && GITLEAKS_ABSENT_IS_FATAL=1

TMPS=""
cleanup() { [ -n "$TMPS" ] && rm -rf $TMPS; return 0; }
trap cleanup EXIT INT TERM
newtmp() { local d; d=$(mktemp -d); TMPS="$TMPS $d"; printf '%s\n' "$d"; }

if [ "$HAVE_GITLEAKS" -eq 0 ]; then
  if [ "$GITLEAKS_ABSENT_IS_FATAL" -eq 1 ]; then
    fail_ "setup" "gitleaks is not installed and CI is set — this suite is a real scan of a real project; a green check credited with a scan that never ran is what it exists to prevent"
  else
    skip_ "the whole suite" "gitleaks not installed (install it to run BL-308's generated-project proof locally)"
  fi
else
  D="$(newtmp)"
  PROJ="$D/bl308proj"
  # The measured case: organizational, production, typescript/web, no remote.
  # "$BASH" so the installer runs under the interpreter running this suite.
  RC=0
  OUT="$( cd "$REPO_ROOT" && "$BASH" ./init.sh --non-interactive \
            --project bl308proj \
            --platform web \
            --deployment organizational \
            --gov-mode production \
            --language typescript \
            --git-host github \
            --visibility private \
            --project-dir "$PROJ" \
            --no-remote-creation 2>&1 )" || RC=$?
  if [ "$RC" -ne 0 ] || [ ! -d "$PROJ/.git" ]; then
    fail_ "setup" "init.sh rc=$RC or no repository at $PROJ; tail: $(echo "$OUT" | tail -5 | tr '\n' ';')"
  else
    # ── P1: the generated ci.yml still carries the scan this suite reproduces ─
    ci="$PROJ/.github/workflows/ci.yml"
    ci_hits=0
    [ -f "$ci" ] && ci_hits=$(grep -c 'gitleaks git --redact --exit-code 1' "$ci" || true)
    case "$ci_hits" in ''|*[!0-9]*) ci_hits=0 ;; esac
    if [ "$ci_hits" -ge 1 ]; then
      pass "P1: the generated ci.yml runs 'gitleaks git --redact --exit-code 1' — P2 reproduces that step"
    else
      fail_ "P1" "the generated ci.yml does not carry 'gitleaks git --redact --exit-code 1' (hits=$ci_hits) — P2 no longer reproduces what CI runs; update both"
    fi

    # ── P2: that scan, over the generated project's history, is clean ───────
    rc=0
    ( cd "$PROJ" && gitleaks git --no-banner --redact --exit-code 1 \
        --report-format json --report-path "$D/git.json" . ) >/dev/null 2>&1 || rc=$?
    [ -s "$D/git.json" ] || printf '[]\n' > "$D/git.json"
    n=$(jq -r 'length' "$D/git.json")
    commits=$(cd "$PROJ" && git rev-list --count HEAD)
    if [ "$rc" -eq 0 ] && [ "$n" -eq 0 ] && [ "$commits" -ge 1 ]; then
      pass "P2: gitleaks git over the generated project ($commits commit(s)) reports 0 findings, rc 0"
    else
      fail_ "P2" "rc=$rc findings=$n commits=$commits — the project's first PR is red at secret detection: $(jq -r '.[] | "\(.RuleID) \(.File):\(.StartLine) \(.Match)"' "$D/git.json" | tr '\n' ';')"
    fi
  fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed, $SKIPPED skipped"
[ "$FAILED" -eq 0 ]
