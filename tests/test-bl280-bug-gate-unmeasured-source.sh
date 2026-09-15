#!/usr/bin/env bash
# tests/test-bl280-bug-gate-unmeasured-source.sh
#
# BL-280. `scripts/test-gate.sh` check_phase_gate() counted open bugs from
# GitHub Issues whenever `gh auth status` succeeded, and treated the result as
# a measurement in every case. Two defects, both permissive, same four lines.
#
#   ARM 1 (false CLEAR) — `gh issue list --label SEV-1` on a repository that
#     has no such label returns an EMPTY LIST at rc 0. Not an error. The gate
#     read 0, set has_bugs=true on the strength of an authenticated CLI, and
#     printed four all-clears having measured nothing. Same outcome in a
#     repository with no GitHub remote at all (rc 1, empty stdout, sanitized
#     to 0), and in a repository that adopted SEV-1/2/3 but not `fix-now` /
#     `deferred` — the two arms that AND those labels with SEV-2 both BLOCK,
#     so both were silently satisfied.
#
#   ARM 2 (false MAGNITUDE) — no --limit, so every count saturated at gh's
#     default of 30. This one canNOT flip a verdict: every threshold in the
#     function is `-gt 0` and saturation never yields 0 from a nonzero truth.
#     What it corrupts is the number the operator triages against.
#
# WHAT THIS SUITE PROVES
#   P0  the fixture's `gh` shim is the one the gate calls. FAIL-CLOSED: if the
#       shim is not resolved, every arm-1 case below would pass for the wrong
#       reason — no `gh` means the GitHub block is skipped entirely and the
#       honest no-source warning appears without the fix having done anything.
#   R0  control: the real gate still runs and still clears a clean project.
#   R1  arm 1, no SEV labels + no BUGS.md -> honest no-source warning, and NO
#       all-clear line. RED on main.
#   R2  arm 1, no GitHub remote (every gh query fails) -> same. RED on main.
#   R3  arm 1, SEV-* present but `fix-now` / `deferred` absent -> the two
#       blocking SEV-2 arms report NOT MEASURED. RED on main.
#   R3b arm 1, SEV-2/SEV-3/fix-now/deferred present but SEV-1 absent -> the
#       SEV-1 arm reports NOT MEASURED, no `[OK] No open SEV-1 bugs`. RED on
#       main. Added after adversarial review: the first cut's R3 only ever
#       exercised the two SEV-2 lines, so the SEV-1 and SEV-3 lines of the
#       same block could be deleted and the suite stayed 13/0.
#   R3c the SEV-3 analogue of R3b. RED on main.
#   R4  arm 2, 257 open issues -> the gate prints 257. RED on main (30).
#   R5  a BUGS.md project is not broken by the fix (control half) and is told
#       what GitHub contributed (discriminator half). RED on main.
#   R6  structural: every `gh issue list` in the file carries --limit, and the
#       label probe does not use `gh label list` — whose own default limit is
#       30, which would rebuild arm 2 inside the fix for it. RED on main.
#   R7  control: with BUGS.md present, a partly-adopted vocabulary still reads
#       [OK] — BUGS.md counted those severities. Passes on main by
#       construction; it exists to bound the fix's blast radius.
#   R8  every label present, every `gh issue list` exits 1 with empty stdout,
#       no BUGS.md -> every arm reports NOT MEASURED and none reads [OK]. RED
#       on main, and RED on the first cut of this fix, which sanitised a
#       failed query to 0 one step after a label probe that had succeeded.
#   MT1 strip --limit            -> R4 must flip red.
#   MT2 reinstate has_bugs=true  -> R1 must flip red.
#   MT3 drop the BUGS.md guard   -> R7 must flip red.
#   MT4 strip --limit            -> R6's own predicate must report 4 of 4, and
#       must still report 0 on the real file (it is comment-blind otherwise).
#   MT5 delete the SEV-1 PARTIAL-VOCAB line -> R3b must flip red.
#   MT6 delete the SEV-3 PARTIAL-VOCAB line -> R3c must flip red.
#   MT7 force every captured query status to 0 (the sanitise-to-zero the
#       first cut shipped) -> R8 must flip red.
#
# Hermetic: a PATH-shimmed `gh`, mktemp scratch, no network, no real gh.
# Runs on bash 3.2.57 (macOS) and 5.x.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$REPO_ROOT/scripts/test-gate.sh"

PASSED=0
FAILED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }

# ── PREREQUISITES — FAIL, never SKIP ─────────────────────────────────
# A suite that skips on a missing tool reports green having run nothing,
# which is the defect class this entry is about.
prereq_ok=1
command -v jq  >/dev/null 2>&1 || { fail_ PREREQ "jq is required — the gate pipes gh output through it"; prereq_ok=0; }
[ -f "$GATE" ]                 || { fail_ PREREQ "scripts/test-gate.sh not found at $GATE"; prereq_ok=0; }
if [ "$prereq_ok" -eq 0 ]; then
  echo
  echo "  Passed: $PASSED   Failed: $FAILED"
  exit 1
fi

# ── FIXTURE ──────────────────────────────────────────────────────────
# mk_gh <bindir> <labels> <count> <mode>
#   labels : space-separated label names this repository "has"
#   count  : issues any `gh issue list` would match, before --limit
#   mode   : "ok"        every call answers as gh does against a real repo
#            "norepo"    the repo cannot be resolved: `repo view`, every
#                        label probe and every query fail, as with no
#                        GitHub remote
#            "queryfail" the repo resolves and the label probes answer, but
#                        every `gh issue list` exits 1 with empty stdout —
#                        the shape of a rate limit or a network drop
#                        between the probe and the query
mk_gh() {
  mkdir -p "$1"
  {
    echo '#!/usr/bin/env bash'
    echo "LABELS=\"$2\""
    echo "COUNT=\"$3\""
    echo "MODE=\"$4\""
  } > "$1/gh"
  cat >> "$1/gh" <<'SHIM'
case "$1" in
  auth)
    # The operator is logged in. This is all the old code checked.
    exit 0 ;;
  repo)
    # `gh repo view --json name`: rc 0 with a body when the directory maps
    # to a repository, rc 1 when it does not.
    [ "$MODE" = "norepo" ] && { echo 'none of the git remotes configured for this repository point to a known GitHub host' >&2; exit 1; }
    echo '{"name":"proj"}'; exit 0 ;;
  api)
    [ "$MODE" = "norepo" ] && { echo '{"message":"Not Found","status":"404"}' >&2; exit 1; }
    lbl="${2##*/}"
    for l in $LABELS; do
      [ "$l" = "$lbl" ] && { echo "$lbl"; exit 0; }
    done
    echo '{"message":"Not Found","status":"404"}' >&2; exit 1 ;;
  issue)
    [ "$MODE" = "norepo" ] && exit 1
    [ "$MODE" = "queryfail" ] && exit 1
    # gh's real behaviour: default 30, honour --limit when given.
    lim=30; prev=""
    for a in "$@"; do
      [ "$prev" = "--limit" ] && lim="$a"
      prev="$a"
    done
    n="$COUNT"; [ "$n" -gt "$lim" ] && n="$lim"
    printf '['
    i=0
    while [ "$i" -lt "$n" ]; do
      [ "$i" -gt 0 ] && printf ','
      printf '{"number":%d}' "$((i + 1))"
      i=$((i + 1))
    done
    printf ']\n' ;;
  *) exit 1 ;;
esac
SHIM
  chmod +x "$1/gh"
}

# run_gate <labels> <count> <mode> <bugs_md:yes|no> [gate-path]
# Echoes the gate's combined output. Exit code is deliberately not asserted:
# the feature-completeness section downstream warns on a bare fixture, so
# rc 2 is reached on main AND on the fix. The operator-visible LINES are what
# discriminate, and asserting rc here would be an assertion that cannot fail.
RCFILE="$(mktemp)"
run_gate() {
  T=$(mktemp -d)
  mkdir -p "$T/proj/.claude" "$T/bin"
  mk_gh "$T/bin" "$1" "$2" "$3"
  if [ "$4" = "yes" ]; then
    printf '# BUGS\n\n| # | SEV | Status | Feature |\n|---|---|---|---|\n' > "$T/proj/BUGS.md"
  fi
  # `rich`: a fixture the downstream feature-completeness section does NOT warn
  # on, so the exit code becomes a discriminating assertion — see R11/R12.
  if [ "${6:-}" = "rich" ]; then
    printf '# Features\n\n## Login\n\nShipped.\n' > "$T/proj/FEATURES.md"
    printf '{"features_completed":["Login"],"features_since_last_test":0,"test_interval":3,"testing_required":false}\n' > "$T/proj/.claude/build-progress.json"
  fi
  # The rc travels through a file: callers capture stdout with $( ), which is
  # a subshell, so a variable set here would never reach them.
  ( cd "$T/proj" && PATH="$T/bin:$PATH" bash "${5:-$GATE}" --check-phase-gate 2>&1 </dev/null ); printf '%s' "$?" > "$RCFILE"
  rm -rf "$T"
}

# ── P0 — the shim is live ────────────────────────────────────────────
# Without this, R1/R2/R3 pass whenever `gh` is simply missing from PATH,
# which is a green reading from a check that never ran.
echo "P0: the fixture's gh shim resolves and reports an authenticated operator"
T0=$(mktemp -d); mk_gh "$T0/bin" "SEV-1" 0 ok
p0_ok=1
resolved=$( PATH="$T0/bin:$PATH" command -v gh 2>/dev/null )
[ "$resolved" = "$T0/bin/gh" ] || { fail_ P0 "gh resolved to '$resolved', not the shim at $T0/bin/gh"; p0_ok=0; }
if [ "$p0_ok" -eq 1 ]; then
  PATH="$T0/bin:$PATH" gh auth status >/dev/null 2>&1 \
    || { fail_ P0 "the shim did not answer 'gh auth status' with rc 0 — every arm-1 case would pass vacuously"; p0_ok=0; }
fi
if [ "$p0_ok" -eq 1 ]; then
  PATH="$T0/bin:$PATH" gh api "repos/{owner}/{repo}/labels/SEV-1" --jq '.name' >/dev/null 2>&1 \
    || { fail_ P0 "the shim reported a label it was told exists as absent"; p0_ok=0; }
fi
if [ "$p0_ok" -eq 1 ]; then
  if PATH="$T0/bin:$PATH" gh api "repos/{owner}/{repo}/labels/SEV-9" --jq '.name' >/dev/null 2>&1; then
    fail_ P0 "the shim reported a label it was NOT told exists as present — it cannot discriminate"
    p0_ok=0
  fi
fi
if [ "$p0_ok" -eq 1 ]; then
  # The repo preflight is the fix's first gate. A shim that cannot answer it
  # sends EVERY case down the "could not resolve" arm, and R1-R4 would then
  # pass having never reached the code they exist to test.
  PATH="$T0/bin:$PATH" gh repo view --json name >/dev/null 2>&1 \
    || { fail_ P0 "the shim did not answer 'gh repo view' with rc 0 — every case would read as an unresolvable repository"; p0_ok=0; }
fi
[ "$p0_ok" -eq 1 ] && pass "P0 (shim resolved, authenticates, resolves the repo, and answers both ways)"
rm -rf "$T0"

# ── R0 — CONTROL. The gate still runs and still clears a clean project ──
echo "R0: control — full vocabulary, no open issues, BUGS.md present"
out=$(run_gate "SEV-1 SEV-2 SEV-3 fix-now deferred" 0 ok yes)
r0_ok=1
for line in "No open SEV-1 bugs" "No open SEV-2 fix-now bugs" "No deferred SEV-2 bugs" "No open SEV-3 bugs"; do
  echo "$out" | grep -qF "$line" || { fail_ R0 "a clean project lost its all-clear: '$line' missing"; r0_ok=0; break; }
done
[ "$r0_ok" -eq 1 ] && pass "R0 (a genuinely clean project still reads clear)"

# ── R11/R12 — THE VERDICT, not only the lines. A review deleted `warnings=true`
# from all four NOT-MEASURED arms and this suite stayed 19/0: the gate printed
# four "NOT MEASURED — This is NOT a clean result" lines and then declared the
# phase gate CLEAR with exit 0. The header above explains why rc was not
# asserted (a bare fixture warns downstream on main and fix alike); a fixture
# the feature-completeness section is happy with turns rc into a real check.
echo "R11: enriched control — a clean project exits 0 (the fixture itself does not warn)"
out=$(run_gate "SEV-1 SEV-2 SEV-3 fix-now deferred" 0 ok yes "" rich); rc=$(cat "$RCFILE")
if [ "$rc" -eq 0 ]; then
  pass "R11 (rc=0 on the enriched clean fixture — so R12's rc is discriminating)"
else
  fail_ R11 "the enriched clean fixture does not exit 0 (rc=$rc) — R12 cannot discriminate; output: $(echo "$out" | grep -E 'WARN|FAIL' | head -2 | tr '\n' '|')"
fi
# Which arm is which, measured: `norepo` with a BUGS.md is a NOTE (BUGS.md is a
# measured source, GitHub is merely not counted); no BUGS.md and no labels is
# the "No bug tracking source found" arm — a different warning. The four
# NOT-MEASURED arms are reached when the labels EXIST and the `gh issue list`
# query FAILS: GitHub's count is then unknown even with a BUGS.md present.
echo "R12: labels present, gh query fails — four arms NOT MEASURED — must NOT clear: rc 2, not 0"
out=$(run_gate "SEV-1 SEV-2 SEV-3 fix-now deferred" 0 queryfail yes "" rich); rc=$(cat "$RCFILE")
if [ "$rc" -eq 2 ] && echo "$out" | grep -q "NOT MEASURED"; then
  pass "R12 (NOT MEASURED is a warning arm: rc=2, 'User attestation required' — never a clear)"
else
  fail_ R12 "an unmeasured bug source cleared the gate (rc=$rc, want 2) — the four NOT-MEASURED arms are not raising warnings"
fi

# ── R1 — arm 1. No SEV labels, no BUGS.md: nothing was measured ──────
echo "R1: no SEV label and no BUGS.md — the gate must not report zero bugs"
out=$(run_gate "" 0 ok no)
r1_ok=1
if echo "$out" | grep -qF "No open SEV-1 bugs"; then
  fail_ R1 "the gate reported 'No open SEV-1 bugs' from a source that has no SEV-1 label — an unmeasured source read as zero"
  r1_ok=0
fi
if [ "$r1_ok" -eq 1 ] && ! echo "$out" | grep -qF "No bug tracking source found"; then
  fail_ R1 "the gate did not fall through to its own no-source arm: $(echo "$out" | grep -E '\[(OK|WARN|FAIL)\]' | head -2 | tr '\n' ' ')"
  r1_ok=0
fi
[ "$r1_ok" -eq 1 ] && pass "R1 (no SEV vocabulary is reported as no source, not as no bugs)"

# ── R2 — arm 1, the other route in. No GitHub remote at all ──────────
echo "R2: gh authenticated but this is not a GitHub project — same honesty"
out=$(run_gate "" 0 norepo no)
r2_ok=1
if echo "$out" | grep -qF "No open SEV-1 bugs"; then
  fail_ R2 "a repository gh cannot even resolve produced an all-clear"
  r2_ok=0
fi
if [ "$r2_ok" -eq 1 ] && ! echo "$out" | grep -qF "No bug tracking source found"; then
  fail_ R2 "no honest no-source warning when every gh query failed"
  r2_ok=0
fi
# The scope note must name the real cause. The first cut printed "no
# SEV-1/SEV-2/SEV-3 label exists in this repository" here, which is what the
# label probes report when there is no repository for them to probe.
if [ "$r2_ok" -eq 1 ] && ! echo "$out" | grep -qF "could not resolve a GitHub repository, so its issues were NOT counted"; then
  fail_ R2 "the operator is not told that no GitHub repository could be resolved: $(echo "$out" | grep -F 'GitHub Issues' | head -1)"
  r2_ok=0
fi
if [ "$r2_ok" -eq 1 ] && echo "$out" | grep -qF "no SEV-1/SEV-2/SEV-3 label exists in this repository"; then
  fail_ R2 "an unresolvable repository was reported as a repository with no SEV labels — the wrong cause"
  r2_ok=0
fi
[ "$r2_ok" -eq 1 ] && pass "R2 (a repository gh cannot resolve is not a zero count, and is named as such)"

# ── R3 — arm 1, partial vocabulary. The blocking pair ────────────────
echo "R3: SEV-* adopted but fix-now/deferred absent — the two BLOCKING arms"
out=$(run_gate "SEV-1 SEV-2 SEV-3" 0 ok no)
r3_ok=1
if echo "$out" | grep -qF "No open SEV-2 fix-now bugs"; then
  fail_ R3 "the fix-now arm reported clear though no 'fix-now' label exists — and that arm BLOCKS"
  r3_ok=0
fi
if [ "$r3_ok" -eq 1 ] && echo "$out" | grep -qF "No deferred SEV-2 bugs"; then
  fail_ R3 "the deferred arm reported clear though no 'deferred' label exists — and that arm BLOCKS"
  r3_ok=0
fi
if [ "$r3_ok" -eq 1 ]; then
  n=$(echo "$out" | grep -cF "NOT MEASURED")
  [ "$n" -ge 2 ] || { fail_ R3 "expected both SEV-2 arms to report NOT MEASURED, saw $n such line(s)"; r3_ok=0; }
fi
[ "$r3_ok" -eq 1 ] && pass "R3 (an arm whose labels are absent says so instead of clearing)"

# ── R3b / R3c — the single-severity lines of the same block ──────────
# R3 covers the two SEV-2 lines of BL-280-PARTIAL-VOCAB and nothing else:
# with SEV-1 and SEV-3 both present in its fixture, the lines that clear
# sev1_measurable and sev3_measurable never fire, and deleting either left
# the suite at 13/0 (adversarial review, MY-MT-A / MY-MT-B). These two
# cases make each of those lines load-bearing on its own.
echo "R3b: SEV-1 absent, everything else present, no BUGS.md — the SEV-1 arm must not clear"
out=$(run_gate "SEV-2 SEV-3 fix-now deferred" 0 ok no)
r3b_ok=1
if echo "$out" | grep -qF "No open SEV-1 bugs"; then
  fail_ R3b "the SEV-1 arm reported clear though no 'SEV-1' label exists"
  r3b_ok=0
fi
if [ "$r3b_ok" -eq 1 ] && ! echo "$out" | grep -F "SEV-1 bugs" | grep -qF "NOT MEASURED"; then
  fail_ R3b "the SEV-1 arm did not report NOT MEASURED: $(echo "$out" | grep -F 'SEV-1' | head -1)"
  r3b_ok=0
fi
if [ "$r3b_ok" -eq 1 ] && ! echo "$out" | grep -qF "No open SEV-3 bugs"; then
  fail_ R3b "SEV-3 IS present in this fixture and must still read [OK] — the case is not isolating SEV-1"
  r3b_ok=0
fi
[ "$r3b_ok" -eq 1 ] && pass "R3b (an absent SEV-1 label is NOT MEASURED, not zero)"

echo "R3c: SEV-3 absent, everything else present, no BUGS.md — the SEV-3 arm must not clear"
out=$(run_gate "SEV-1 SEV-2 fix-now deferred" 0 ok no)
r3c_ok=1
if echo "$out" | grep -qF "No open SEV-3 bugs"; then
  fail_ R3c "the SEV-3 arm reported clear though no 'SEV-3' label exists"
  r3c_ok=0
fi
if [ "$r3c_ok" -eq 1 ] && ! echo "$out" | grep -F "SEV-3 bugs" | grep -qF "NOT MEASURED"; then
  fail_ R3c "the SEV-3 arm did not report NOT MEASURED: $(echo "$out" | grep -F 'SEV-3' | head -1)"
  r3c_ok=0
fi
if [ "$r3c_ok" -eq 1 ] && ! echo "$out" | grep -qF "No open SEV-1 bugs"; then
  fail_ R3c "SEV-1 IS present in this fixture and must still read [OK] — the case is not isolating SEV-3"
  r3c_ok=0
fi
[ "$r3c_ok" -eq 1 ] && pass "R3c (an absent SEV-3 label is NOT MEASURED, not zero)"

# ── R4 — arm 2. The number the operator triages against ──────────────
echo "R4: 257 open SEV-1 issues — the gate must print 257, not gh's default 30"
out=$(run_gate "SEV-1 SEV-2 SEV-3 fix-now deferred" 257 ok no)
if echo "$out" | grep -qF "SEV-1 bugs open: 257"; then
  pass "R4 (the count is the true count)"
elif echo "$out" | grep -qF "SEV-1 bugs open: 30"; then
  fail_ R4 "the count saturated at gh's default limit: 257 open issues reported as 30"
else
  fail_ R4 "no SEV-1 count line at all: $(echo "$out" | grep -E 'SEV-1' | head -1)"
fi

# ── R5 — the BUGS.md project: unbroken, and told what was counted ────
echo "R5: a BUGS.md project keeps its all-clears and learns GitHub's scope"
out=$(run_gate "" 0 ok yes)
r5_ok=1
# control half — true on main by construction. If the fix ever starts
# blocking BUGS.md projects, this is what catches it.
echo "$out" | grep -qF "No open SEV-1 bugs" \
  || { fail_ R5 "the fix broke a BUGS.md project — its all-clear is gone"; r5_ok=0; }
# discriminator half
if [ "$r5_ok" -eq 1 ]; then
  echo "$out" | grep -qF "no SEV-1/SEV-2/SEV-3 label exists in this repository" \
    || { fail_ R5 "the operator is not told that GitHub Issues contributed nothing to these counts"; r5_ok=0; }
fi
[ "$r5_ok" -eq 1 ] && pass "R5 (unchanged verdict, stated scope)"

# ── R6 — structural. The two traps must stay shut ────────────────────
echo "R6: every gh issue list carries --limit, and the probe is not gh label list"
r6_ok=1
# COMMENT-BLIND PREDICATES ARE THE HOUSE TRAP (BL-258 #7: a script accused on
# the strength of the words "exit 1" inside a comment). A first cut of this
# case counted 3 violations that were all prose in the fix's own comments.
# `code_lines` drops whole-line comments before matching.
code_lines() { grep -n "$1" "${2:-$GATE}" | grep -v ':[[:space:]]*#'; }
count_unlimited() { code_lines 'gh issue list' "${1:-$GATE}" | grep -vc -- '--limit'; }
count_queries()   { code_lines 'gh issue list' "${1:-$GATE}" | grep -c .; }

unlimited=$(count_unlimited)
[ "$unlimited" -eq 0 ] \
  || { fail_ R6 "$unlimited 'gh issue list' call(s) carry no --limit and will saturate at 30"; r6_ok=0; }
total=$(count_queries)
[ "$total" -gt 0 ] \
  || { fail_ R6 "no 'gh issue list' call found at all — this case would pass vacuously"; r6_ok=0; }
if [ "$r6_ok" -eq 1 ] && code_lines 'gh label list' | grep -q .; then
  fail_ R6 "the label probe uses 'gh label list', whose own default limit is 30 — arm 2 rebuilt inside the fix for it"
  r6_ok=0
fi
[ "$r6_ok" -eq 1 ] && pass "R6 ($total queries, all limited; no gh label list)"

# ── R7 — CONTROL. BUGS.md measures the severities GitHub cannot ──────
echo "R7: control — partial vocabulary WITH BUGS.md still reads [OK]"
out=$(run_gate "SEV-1 SEV-2 SEV-3" 0 ok yes)
r7_ok=1
echo "$out" | grep -qF "No open SEV-2 fix-now bugs" \
  || { fail_ R7 "BUGS.md counted this severity, so the arm must stay [OK]: $(echo "$out" | grep -F 'fix-now' | head -1)"; r7_ok=0; }
if [ "$r7_ok" -eq 1 ]; then
  echo "$out" | grep -qF "No deferred SEV-2 bugs" \
    || { fail_ R7 "the deferred arm went unmeasurable though BUGS.md is present"; r7_ok=0; }
fi
[ "$r7_ok" -eq 1 ] && pass "R7 (the BUGS.md guard keeps the fix off the common path)"

# ── R8 — the probe succeeded, the query did not ──────────────────────
# Every label exists, so GitHub IS a source; then every `gh issue list`
# exits 1 with empty stdout. The first cut of this fix piped that into
# `jq length`, got nothing, sanitised nothing to 0, and printed four
# all-clears — main's defect, one step later. A failed query is not a
# measurement of zero.
echo "R8: all five labels present, every issue query fails, no BUGS.md — nothing was measured"
out=$(run_gate "SEV-1 SEV-2 SEV-3 fix-now deferred" 0 queryfail no)
r8_ok=1
for line in "No open SEV-1 bugs" "No open SEV-2 fix-now bugs" "No deferred SEV-2 bugs" "No open SEV-3 bugs"; do
  if echo "$out" | grep -qF "$line"; then
    fail_ R8 "a failed query read as an all-clear: '$line'"
    r8_ok=0; break
  fi
done
if [ "$r8_ok" -eq 1 ]; then
  n=$(echo "$out" | grep -cF "NOT MEASURED")
  [ "$n" -eq 4 ] || { fail_ R8 "expected all four arms to report NOT MEASURED, saw $n such line(s)"; r8_ok=0; }
fi
if [ "$r8_ok" -eq 1 ] && ! echo "$out" | grep -qF "query failed"; then
  fail_ R8 "the arms are unmeasured but the operator is not told the QUERY failed: $(echo "$out" | grep -F 'NOT MEASURED' | head -1)"
  r8_ok=0
fi
[ "$r8_ok" -eq 1 ] && pass "R8 (a failed query is NOT MEASURED on every arm, never zero)"

# ── MUTANTS ──────────────────────────────────────────────────────────
mutant_dir() { MT=$(mktemp -d); cp -R "$REPO_ROOT/scripts" "$MT/scripts"; echo "$MT"; }
sum_of()  { cksum < "$1" | awk '{print $1"-"$2}'; }
mutated() { [ "$(sum_of "$1/scripts/test-gate.sh")" != "$2" ]; }
# A mutant whose edit matched nothing leaves the file byte-identical, and every
# assertion downstream then measures the UNMUTATED script — a pass that proves
# nothing. Measured: against main both MT1 and MT2 did exactly that, because
# the text they rewrite only exists once the fix is applied. Every mutant below
# must now show a changed checksum before it is allowed to conclude anything.

echo "MT1: --limit stripped from the queries → R4 must flip red"
M=$(mutant_dir); before=$(sum_of "$M/scripts/test-gate.sh")
perl -0pi -e 's/ --limit 1000 --json number/ --json number/g' "$M/scripts/test-gate.sh"
if ! mutated "$M" "$before"; then
  fail_ MT1 "the mutation changed NOTHING — --limit is not on these queries to strip"
elif grep -q -- '--limit 1000 --json number' "$M/scripts/test-gate.sh"; then
  fail_ MT1 "mutation only partly landed — --limit is still on some queries"
elif ! bash -n "$M/scripts/test-gate.sh" 2>/dev/null; then
  fail_ MT1 "mutant does not parse"
else
  out=$(run_gate "SEV-1 SEV-2 SEV-3 fix-now deferred" 257 ok no "$M/scripts/test-gate.sh")
  if echo "$out" | grep -qF "SEV-1 bugs open: 30"; then
    pass "MT1 killed by R4 (removing --limit re-saturates the count at 30)"
  else
    fail_ MT1 "mutant survived — R4 does not actually depend on --limit: $(echo "$out" | grep -F 'SEV-1 bugs open' | head -1)"
  fi
fi
rm -rf "$M"

echo "MT2: has_bugs=true reinstated on the no-vocabulary branch → R1 must flip red"
M=$(mutant_dir); before=$(sum_of "$M/scripts/test-gate.sh")
mt2_base=$(grep -c 'has_bugs=true' "$M/scripts/test-gate.sh")
perl -0pi -e 's/(      gh_scope_note="GitHub Issues: no SEV-1)/      has_bugs=true\n$1/' "$M/scripts/test-gate.sh"
if ! mutated "$M" "$before"; then
  fail_ MT2 "the mutation changed NOTHING — the no-vocabulary branch this reinstates has_bugs on does not exist here"
elif [ "$(grep -c 'has_bugs=true' "$M/scripts/test-gate.sh")" -ne "$((mt2_base + 1))" ]; then
  fail_ MT2 "mutation landed in the wrong place — has_bugs=true count did not rise by exactly one"
elif ! bash -n "$M/scripts/test-gate.sh" 2>/dev/null; then
  fail_ MT2 "mutant does not parse"
else
  out=$(run_gate "" 0 ok no "$M/scripts/test-gate.sh")
  if echo "$out" | grep -qF "No open SEV-1 bugs"; then
    pass "MT2 killed by R1 (crediting gh as a source restores the fabricated all-clear)"
  else
    fail_ MT2 "mutant survived — R1 does not actually depend on has_bugs: $(echo "$out" | grep -E '\[(OK|WARN)\]' | head -2 | tr '\n' ' ')"
  fi
fi
rm -rf "$M"

echo "MT3: the BUGS.md guard dropped → R7 must flip red"
M=$(mutant_dir); before=$(sum_of "$M/scripts/test-gate.sh")
perl -0pi -e 's/      if \[ ! -f "BUGS\.md" \]; then\n/      if true; then\n/' "$M/scripts/test-gate.sh"
if ! mutated "$M" "$before"; then
  fail_ MT3 "the mutation changed NOTHING — there is no BUGS.md guard in this file to drop"
elif grep -q 'if \[ ! -f "BUGS.md" \]; then' "$M/scripts/test-gate.sh"; then
  fail_ MT3 "mutation only partly landed — a BUGS.md guard remains"
elif ! bash -n "$M/scripts/test-gate.sh" 2>/dev/null; then
  fail_ MT3 "mutant does not parse"
else
  out=$(run_gate "SEV-1 SEV-2 SEV-3" 0 ok yes "$M/scripts/test-gate.sh")
  if echo "$out" | grep -qF "NOT MEASURED"; then
    pass "MT3 killed by R7 (without the guard a BUGS.md project is told its bugs were not measured)"
  else
    fail_ MT3 "mutant survived — R7 does not actually depend on the BUGS.md guard"
  fi
fi
rm -rf "$M"

echo "MT4: --limit stripped → R6's predicate must report it, and must ignore comments"
M=$(mutant_dir); before=$(sum_of "$M/scripts/test-gate.sh")
perl -0pi -e 's/ --limit 1000 --json number/ --json number/g' "$M/scripts/test-gate.sh"
if ! mutated "$M" "$before"; then
  fail_ MT4 "the mutation changed NOTHING — there is no --limit here to strip, so the counts below would measure the unmutated file"
  rm -rf "$M"; M=""
fi
if [ -n "$M" ]; then
  mt4_before=$(count_queries "$M/scripts/test-gate.sh")
  mt4_after=$(count_unlimited "$M/scripts/test-gate.sh")
else
  mt4_before=0; mt4_after=0
fi
if [ -z "$M" ]; then
  :
elif [ "$mt4_before" -ne 4 ]; then
  fail_ MT4 "expected 4 code-level queries in the mutant, counted $mt4_before — the predicate is not seeing the calls"
elif [ "$mt4_after" -ne 4 ]; then
  fail_ MT4 "R6's predicate saw only $mt4_after of 4 unlimited calls — it cannot detect the regression it exists for"
elif [ "$(count_unlimited)" -ne 0 ]; then
  fail_ MT4 "R6's predicate reports violations on the REAL file too — it is counting comments, not code"
else
  pass "MT4 killed by R6 (4 of 4 stripped calls detected; 0 false positives on the real file)"
fi
rm -rf "$M"

# MT5 / MT6 delete ONE line each of the PARTIAL-VOCAB block — the exact
# deletions adversarial review made against the first cut, which survived
# them at 13/0. "Landed" here is a line count that dropped by exactly one
# and the target line gone; a regex that matched nothing would leave both
# unchanged and the case would then be measuring the real file.
echo "MT5: the SEV-1 PARTIAL-VOCAB line deleted → R3b must flip red"
M=$(mutant_dir); before=$(sum_of "$M/scripts/test-gate.sh")
mt5_lines=$(wc -l < "$M/scripts/test-gate.sh" | tr -d ' ')
perl -ni -e 'print unless /^\s*\[ "\$has_sev1" = true \] \|\| \{ sev1_measurable=false;/' "$M/scripts/test-gate.sh"
if ! mutated "$M" "$before"; then
  fail_ MT5 "the mutation changed NOTHING — there is no SEV-1 PARTIAL-VOCAB line here to delete"
elif [ "$(wc -l < "$M/scripts/test-gate.sh" | tr -d ' ')" -ne "$((mt5_lines - 1))" ]; then
  fail_ MT5 "mutation landed in the wrong place — the line count did not drop by exactly one"
elif grep -qF '= true ] || { sev1_measurable=false' "$M/scripts/test-gate.sh"; then
  fail_ MT5 "mutation only partly landed — the SEV-1 PARTIAL-VOCAB line is still present"
elif ! bash -n "$M/scripts/test-gate.sh" 2>/dev/null; then
  fail_ MT5 "mutant does not parse"
else
  out=$(run_gate "SEV-2 SEV-3 fix-now deferred" 0 ok no "$M/scripts/test-gate.sh")
  if echo "$out" | grep -qF "No open SEV-1 bugs"; then
    pass "MT5 killed by R3b (without its PARTIAL-VOCAB line the SEV-1 arm clears on an absent label)"
  else
    fail_ MT5 "mutant survived — R3b does not actually depend on the SEV-1 line: $(echo "$out" | grep -F 'SEV-1' | head -1)"
  fi
fi
rm -rf "$M"

echo "MT6: the SEV-3 PARTIAL-VOCAB line deleted → R3c must flip red"
M=$(mutant_dir); before=$(sum_of "$M/scripts/test-gate.sh")
mt6_lines=$(wc -l < "$M/scripts/test-gate.sh" | tr -d ' ')
perl -ni -e 'print unless /^\s*\[ "\$has_sev3" = true \] \|\| \{ sev3_measurable=false;/' "$M/scripts/test-gate.sh"
if ! mutated "$M" "$before"; then
  fail_ MT6 "the mutation changed NOTHING — there is no SEV-3 PARTIAL-VOCAB line here to delete"
elif [ "$(wc -l < "$M/scripts/test-gate.sh" | tr -d ' ')" -ne "$((mt6_lines - 1))" ]; then
  fail_ MT6 "mutation landed in the wrong place — the line count did not drop by exactly one"
elif grep -qF '= true ] || { sev3_measurable=false' "$M/scripts/test-gate.sh"; then
  fail_ MT6 "mutation only partly landed — the SEV-3 PARTIAL-VOCAB line is still present"
elif ! bash -n "$M/scripts/test-gate.sh" 2>/dev/null; then
  fail_ MT6 "mutant does not parse"
else
  out=$(run_gate "SEV-1 SEV-2 fix-now deferred" 0 ok no "$M/scripts/test-gate.sh")
  if echo "$out" | grep -qF "No open SEV-3 bugs"; then
    pass "MT6 killed by R3c (without its PARTIAL-VOCAB line the SEV-3 arm clears on an absent label)"
  else
    fail_ MT6 "mutant survived — R3c does not actually depend on the SEV-3 line: $(echo "$out" | grep -F 'SEV-3' | head -1)"
  fi
fi
rm -rf "$M"

# MT7 rewrites each `|| gh_<arm>_rc=$?` to `|| gh_<arm>_rc=0`: the query
# still fails, its status is discarded, the empty body sanitises to 0 — the
# first cut's behaviour, and main's, reinstated in one substitution.
echo "MT7: every captured query status forced to 0 → R8 must flip red"
M=$(mutant_dir); before=$(sum_of "$M/scripts/test-gate.sh")
mt7_base=$(grep -c '_rc=\$?' "$M/scripts/test-gate.sh")
perl -pi -e 's/\) \|\| gh_(\w+)_rc=\$\?\s*$/) || gh_$1_rc=0\n/' "$M/scripts/test-gate.sh"
if ! mutated "$M" "$before"; then
  fail_ MT7 "the mutation changed NOTHING — there is no query status capture here to discard"
elif [ "$mt7_base" -ne 4 ]; then
  fail_ MT7 "expected 4 status captures before mutating, found $mt7_base — the substitution is aimed at the wrong text"
elif [ "$(grep -c '_rc=\$?' "$M/scripts/test-gate.sh")" -ne 0 ]; then
  fail_ MT7 "mutation only partly landed — a status capture remains"
elif ! bash -n "$M/scripts/test-gate.sh" 2>/dev/null; then
  fail_ MT7 "mutant does not parse"
else
  out=$(run_gate "SEV-1 SEV-2 SEV-3 fix-now deferred" 0 queryfail no "$M/scripts/test-gate.sh")
  if echo "$out" | grep -qF "No open SEV-1 bugs"; then
    pass "MT7 killed by R8 (discarding the query status turns a failed query back into zero bugs)"
  else
    fail_ MT7 "mutant survived — R8 does not actually depend on the status capture: $(echo "$out" | grep -F 'SEV-1' | head -1)"
  fi
fi
rm -rf "$M"

echo
echo "  Passed: $PASSED   Failed: $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
