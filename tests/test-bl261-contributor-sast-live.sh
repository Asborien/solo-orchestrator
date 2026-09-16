#!/usr/bin/env bash
# tests/test-bl261-contributor-sast-live.sh
#
# BL-261 — the contributor pre-commit hook's SAST arm was PERMANENTLY INERT in
# the framework checkout: the emitted hook `--config`s `.semgrep/soif-dom-sinks.yml`
# by repo-relative path (# BL-131-DOM-SINKS), a file only init.sh lays in
# GENERATED projects, so semgrep exited 7 on every commit here and the hook
# printed `SAST NOT ENFORCED` — honestly (# BL-112-SAST-NOTRUN), but forever.
#
# The fix: `scripts/install-contributor-hooks.sh` lays `.semgrep/soif-dom-sinks.yml`
# as a RELATIVE SYMLINK to the tracked template (# BL-261-CONTRIB-SEMGREP-CONFIG),
# so the hook text — and with it the `# BL-194-HOOK-SEMGREP-POLICY` parity that
# `tests/test-bl147-ci-template-integrity.sh` derives — is untouched, and there is
# one source of truth, not a second copy for `## BL-175:` to lose track of.
#
# Static (no semgrep needed):
#   L0  the installed hook still names the repo-relative config (parity untouched)
#   L1  after install the config resolves, is a symlink, is RELATIVE, and is
#       byte-identical to the template
#   L2  the summary says LIVE with semgrep on PATH and INERT without it — and
#       INERT names the reason
#   L3  re-running the installer is idempotent
#   L4  a REGULAR file at the path is somebody's own work: refused, untouched
#   M1  mutation — delete the laying block from a copy of the installer:
#       the config is absent and the summary says INERT (L1/L2 measure the
#       laying, not a pre-existing file)
# Live (semgrep + registry reachable, else LOUD SKIP — never a silent pass):
#   L5  a staged .html with a DOM sink is BLOCKED by the installed hook and the
#       output does NOT say NOT ENFORCED — the arm RUNS here now
#   L6  a clean .html commits with the [OK] SAST receipt, not NOT ENFORCED
#   M2  mutation — remove the laid config: the same sink commit prints
#       NOT ENFORCED and is not blocked (coverage cannot vanish silently)
#
# Hermetic: throwaway git repos under a temp dir shaped like a framework
# checkout root (./.git + scripts/lib/hook-templates.sh + templates/semgrep/),
# named branch, configured identity, no remotes. bash 3.2 safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/install-contributor-hooks.sh"
TEMPLATES="$REPO_ROOT/scripts/lib/hook-templates.sh"
GATE="$REPO_ROOT/scripts/pre-commit-gate.sh"
RULESET="$REPO_ROOT/templates/semgrep/soif-dom-sinks.yml"

PASSED=0
FAILED=0
SKIPPED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }
skip_() { echo "  [SKIP] $1 — $2"; SKIPPED=$((SKIPPED + 1)); }

TOPTMP="$(mktemp -d)"
trap 'chmod -R u+rwX "$TOPTMP" 2>/dev/null; rm -rf "$TOPTMP"' EXIT INT TERM
newtmp() { mktemp -d "$TOPTMP/caseXXXXXX"; }
_num() { case "$1" in ''|*[!0-9]*) printf '0\n' ;; *) printf '%s\n' "$1" ;; esac }

# mk_fw <dir> — a throwaway FRAMEWORK-checkout-shaped repo: the installer
# refuses anything else (needs ./.git and ./scripts/lib/hook-templates.sh).
mk_fw() {
  local d="$1"
  mkdir -p "$d/scripts/lib" "$d/templates/semgrep"
  ( cd "$d" && git init --quiet --initial-branch=main . 2>/dev/null || git init --quiet . )
  ( cd "$d" && git symbolic-ref HEAD refs/heads/main 2>/dev/null )
  ( cd "$d" && git config user.email t@example.invalid && git config user.name "Fixture" )
  cp "$GATE" "$d/scripts/pre-commit-gate.sh"
  cp "$TEMPLATES" "$d/scripts/lib/hook-templates.sh"
  cp "$RULESET" "$d/templates/semgrep/soif-dom-sinks.yml"
  cp "$INSTALLER" "$d/installer.sh"
  printf 'echo hi\n' > "$d/a.sh"
  ( cd "$d" && git add -A && git commit -q -m "chore: fixture base" >/dev/null 2>&1 )
}

# run_installer <dir> [PATH] -> stdout+stderr; echoes rc on the last line
run_installer() {
  local d="$1" p="${2:-$PATH}" out rc=0
  out="$( cd "$d" && PATH="$p" bash "$d/installer.sh" 2>&1 )" || rc=$?
  printf '%s\n__RC=%s\n' "$out" "$rc"
}
rc_of() { printf '%s\n' "$1" | sed -n 's/^__RC=//p' | tail -1; }

# path_without <tool> — this PATH minus every directory that holds <tool>
# (mirror the real PATH, do not append a /usr/bin safety net — `## BL-233:`).
path_without() {
  local IFS=: d out=""
  for d in $PATH; do
    [ -n "$d" ] || continue
    [ -x "$d/$1" ] && continue
    out="${out:+$out:}$d"
  done
  printf '%s\n' "$out"
}

CFG='.semgrep/soif-dom-sinks.yml'

echo "=== L0 — the hook text is untouched: parity with CI is not this fix's to spend ==="
L0="$(newtmp)"; mk_fw "$L0"
l0="$(run_installer "$L0")"
if [ "$(rc_of "$l0")" = "0" ] && grep -qF -- "--config=$CFG" "$L0/.git/hooks/pre-commit"; then
  pass "L0: the installed hook still --config's $CFG by repo-relative path (# BL-194-HOOK-SEMGREP-POLICY parity untouched)"
else
  fail_ "L0" "installer rc=$(rc_of "$l0") or the hook no longer names $CFG"
fi

echo "=== L1 — the config the hook names RESOLVES here, as a relative symlink to the template ==="
if [ -L "$L0/$CFG" ] && [ -f "$L0/$CFG" ] && cmp -s "$L0/$CFG" "$L0/templates/semgrep/soif-dom-sinks.yml"; then
  tgt="$(readlink "$L0/$CFG")"
  case "$tgt" in
    /*) fail_ "L1" "symlink target is ABSOLUTE ($tgt) — a moved checkout would dangle it" ;;
    *)  pass "L1: $CFG is a symlink -> $tgt, relative, resolving, byte-identical to templates/semgrep/soif-dom-sinks.yml" ;;
  esac
else
  fail_ "L1" "after install: exists=$([ -e "$L0/$CFG" ] && echo 1 || echo 0) symlink=$([ -L "$L0/$CFG" ] && echo 1 || echo 0) resolves=$([ -f "$L0/$CFG" ] && echo 1 || echo 0)"
fi

echo "=== L2 — the summary reports the arm as it STANDS: LIVE with semgrep on PATH, INERT without, and says why ==="
L2="$(newtmp)"; mk_fw "$L2"
mkdir -p "$L2/stubbin"
printf '#!/bin/sh\necho "semgrep-stub 0.0"\n' > "$L2/stubbin/semgrep"; chmod +x "$L2/stubbin/semgrep"
l2a="$(run_installer "$L2" "$L2/stubbin:$PATH")"
NOSG="$(path_without semgrep)"
if PATH="$NOSG" command -v semgrep >/dev/null 2>&1; then
  fail_ "L2-isolation" "PATH minus semgrep still resolves semgrep — the INERT half cannot be measured"
  l2b=""
else
  l2b="$(run_installer "$L2" "$NOSG")"
fi
if printf '%s\n' "$l2a" | grep -qE 'SAST \(semgrep\) +LIVE' \
   && ! printf '%s\n' "$l2a" | grep -qE 'SAST \(semgrep\) +INERT'; then
  pass "L2a: with semgrep on PATH and the config laid, the summary says LIVE"
else
  fail_ "L2a" "summary with semgrep on PATH: $(printf '%s\n' "$l2a" | grep -E 'SAST \(semgrep\)' | head -1)"
fi
if [ -n "$l2b" ] && printf '%s\n' "$l2b" | grep -qE 'SAST \(semgrep\) +INERT' \
   && printf '%s\n' "$l2b" | grep -qiE 'not installed'; then
  pass "L2b: with semgrep OFF the PATH the summary says INERT and names the reason (not installed)"
elif [ -n "$l2b" ]; then
  fail_ "L2b" "summary without semgrep: $(printf '%s\n' "$l2b" | grep -E 'SAST \(semgrep\)' | head -1)"
fi

echo "=== L3 — idempotent: a second run refreshes, never fails ==="
l3="$(run_installer "$L0")"
if [ "$(rc_of "$l3")" = "0" ] && [ -L "$L0/$CFG" ] && cmp -s "$L0/$CFG" "$L0/templates/semgrep/soif-dom-sinks.yml"; then
  pass "L3: second install rc 0, symlink still resolves and matches the template"
else
  fail_ "L3" "second install rc=$(rc_of "$l3") symlink=$([ -L "$L0/$CFG" ] && echo 1 || echo 0)"
fi

echo "=== L4 — a REGULAR file at the path is somebody's own work: refuse, never overwrite ==="
L4="$(newtmp)"; mk_fw "$L4"
mkdir -p "$L4/.semgrep"
printf 'rules: []\n# hand-copied by a contributor\n' > "$L4/$CFG"
cp "$L4/$CFG" "$L4/own-copy.yml"
l4="$(run_installer "$L4")"
if [ "$(rc_of "$l4")" != "0" ] && [ ! -L "$L4/$CFG" ] && cmp -s "$L4/$CFG" "$L4/own-copy.yml" \
   && printf '%s\n' "$l4" | grep -qF "$CFG"; then
  pass "L4: installer rc $(rc_of "$l4") (non-zero), the regular file is byte-identical to before, and the refusal names the path"
else
  fail_ "L4" "rc=$(rc_of "$l4") (want non-zero) symlink-now=$([ -L "$L4/$CFG" ] && echo 1 || echo 0) unchanged=$(cmp -s "$L4/$CFG" "$L4/own-copy.yml" && echo 1 || echo 0) names-path=$(printf '%s\n' "$l4" | grep -cF "$CFG")"
fi

echo "=== M1 — mutation: delete the laying block; L1's file must VANISH and the summary must say INERT ==="
M1="$(newtmp)"; mk_fw "$M1"
m1_tmp="$(mktemp)"
m1_changed=$(awk -v n=0 '
  /^# BL-261-CONTRIB-SEMGREP-CONFIG-BEGIN/ { skip=1 }
  skip { n++; if ($0 ~ /^# BL-261-CONTRIB-SEMGREP-CONFIG-END/) { skip=0 }; next }
  { print }
  END { print n+0 > "/dev/stderr" }
' "$M1/installer.sh" 2>&1 >"$m1_tmp")
mv "$m1_tmp" "$M1/installer.sh"
m1_changed=$(_num "$m1_changed")
m1_parses=0; bash -n "$M1/installer.sh" >/dev/null 2>&1 && m1_parses=1
m1="$(run_installer "$M1" "$L2/stubbin:$PATH")"
if [ "$m1_changed" -gt 0 ] && [ "$m1_parses" -eq 1 ] && [ ! -e "$M1/$CFG" ] \
   && printf '%s\n' "$m1" | grep -qE 'SAST \(semgrep\) +INERT'; then
  pass "M1: with the laying block deleted ($m1_changed lines) the config is absent and the summary says INERT — L1/L2 measure the laying, not a pre-existing file"
else
  fail_ "M1" "changed=$m1_changed (0 = mutation never applied) parses=$m1_parses exists=$([ -e "$M1/$CFG" ] && echo 1 || echo 0) summary: $(printf '%s\n' "$m1" | grep -E 'SAST \(semgrep\)' | head -1)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# LIVE — the arm must actually RUN here now. Needs semgrep AND the registry
# (the hook passes p/owasp-top-ten and the browser pack unconditionally).
# ═════════════════════════════════════════════════════════════════════════════
LIVE=0
if command -v semgrep >/dev/null 2>&1; then
  PROBE="$(newtmp)"; printf 'const a = 1;\n' > "$PROBE/probe.js"
  if ( cd "$PROBE" && semgrep scan --config=p/owasp-top-ten \
        --config=r/javascript.browser.security.insecure-document-method \
        --metrics=off --severity=ERROR --error probe.js >/dev/null 2>&1 ); then
    LIVE=1
  else
    echo ""
    echo "#################################################################"
    echo "## semgrep is installed but the RULE REGISTRY is unreachable.  ##"
    echo "## L5/L6/M2 are SKIPPED, NOT PASSED. The static pins bind.     ##"
    echo "#################################################################"
    echo ""
  fi
else
  echo ""
  echo "#################################################################"
  echo "## semgrep IS NOT INSTALLED ON THIS HOST.                      ##"
  echo "## L5/L6/M2 are SKIPPED, NOT PASSED. The static pins bind.     ##"
  echo "## Install semgrep to exercise them: brew install semgrep      ##"
  echo "#################################################################"
  echo ""
fi

SINK='<!doctype html>\n<html><body><div id="o"></div>\n<script>\n  document.getElementById("o").innerHTML = location.hash;\n</script></body></html>\n'
CLEAN='<!doctype html>\n<html><body><div id="o"></div>\n<script>\n  document.getElementById("o").textContent = location.hash;\n</script></body></html>\n'

# commit_out <dir> <msg> -> output; echoes __RC=<rc> last
commit_out() {
  local d="$1" msg="$2" out rc=0
  out="$( cd "$d" && git commit -m "$msg" 2>&1 )" || rc=$?
  printf '%s\n__RC=%s\n' "$out" "$rc"
}

if [ "$LIVE" -eq 1 ]; then
  echo "=== L5 — a staged DOM sink is BLOCKED by the installed hook; the receipt is a scan, not NOT ENFORCED ==="
  L5="$(newtmp)"; mk_fw "$L5"
  l5i="$(run_installer "$L5")"
  printf "$SINK" > "$L5/index.html"
  ( cd "$L5" && git add index.html )
  l5="$(commit_out "$L5" "feat: page with a sink")"
  if [ "$(rc_of "$l5i")" = "0" ] && [ "$(rc_of "$l5")" != "0" ] \
     && printf '%s\n' "$l5" | grep -q '\[BLOCKED\]' \
     && ! printf '%s\n' "$l5" | grep -q 'SAST NOT ENFORCED'; then
    pass "L5: the sink commit is BLOCKED (rc $(rc_of "$l5")) with no 'SAST NOT ENFORCED' line — the arm RAN in a framework-shaped checkout"
  else
    fail_ "L5" "install rc=$(rc_of "$l5i") commit rc=$(rc_of "$l5") (want non-zero) blocked=$(printf '%s\n' "$l5" | grep -c '\[BLOCKED\]') notrun=$(printf '%s\n' "$l5" | grep -c 'SAST NOT ENFORCED')"
  fi

  echo "=== L6 — a clean file commits with the [OK] SAST receipt ==="
  printf "$CLEAN" > "$L5/index.html"
  ( cd "$L5" && git add index.html )
  l6="$(commit_out "$L5" "feat: page without a sink")"
  if [ "$(rc_of "$l6")" = "0" ] \
     && printf '%s\n' "$l6" | grep -qE '\[OK\].*(semgrep|SAST)' \
     && ! printf '%s\n' "$l6" | grep -q 'SAST NOT ENFORCED'; then
    pass "L6: the clean commit lands (rc 0) with an [OK] SAST receipt and no 'SAST NOT ENFORCED' line"
  else
    fail_ "L6" "commit rc=$(rc_of "$l6") (want 0) ok-receipt=$(printf '%s\n' "$l6" | grep -cE '\[OK\].*(semgrep|SAST)') notrun=$(printf '%s\n' "$l6" | grep -c 'SAST NOT ENFORCED')"
  fi

  echo "=== M2 — mutation: remove the laid config; the same sink must print NOT ENFORCED and NOT be blocked ==="
  M2="$(newtmp)"; mk_fw "$M2"
  m2i="$(run_installer "$M2")"
  rm -f "$M2/$CFG"
  printf "$SINK" > "$M2/index.html"
  ( cd "$M2" && git add index.html )
  m2="$(commit_out "$M2" "feat: page with a sink, config gone")"
  if [ "$(rc_of "$m2i")" = "0" ] && [ "$(rc_of "$m2")" = "0" ] \
     && printf '%s\n' "$m2" | grep -q 'SAST NOT ENFORCED' \
     && ! printf '%s\n' "$m2" | grep -q '\[BLOCKED\]'; then
    pass "M2: with $CFG removed the sink commit prints 'SAST NOT ENFORCED' and is not blocked — L5's block came from the laid config, and coverage cannot vanish silently"
  else
    fail_ "M2" "install rc=$(rc_of "$m2i") commit rc=$(rc_of "$m2") (want 0) notrun=$(printf '%s\n' "$m2" | grep -c 'SAST NOT ENFORCED') blocked=$(printf '%s\n' "$m2" | grep -c '\[BLOCKED\]')"
  fi
else
  skip_ "L5" "semgrep or the rule registry unavailable"
  skip_ "L6" "semgrep or the rule registry unavailable"
  skip_ "M2" "semgrep or the rule registry unavailable"
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed, $SKIPPED skipped"
[ "$FAILED" -eq 0 ]
