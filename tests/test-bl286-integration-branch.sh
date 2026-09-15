#!/usr/bin/env bash
# tests/test-bl286-integration-branch.sh
#
# `## BL-286:` — THE TDD GATE'S BRANCH AXIS RESOLVED ITS BASE AS THE LITERAL
# `main`, SO ON A PROJECT WHOSE TRUNK IS NOT `main` IT EXEMPTED EVERY COMMIT.
#
# `_tdd_triggers` (scripts/pre-commit-gate.sh) asks "did a test ride EARLIER on
# this branch", which needs the branch's OWN base. That base was `main`. Where
# the integration branch is something else — `preview`, `develop`, `trunk` —
# the range `main...HEAD` stops meaning "this branch" and becomes the whole
# divergence between `main` and the real trunk. A test almost always rides in
# that divergence, so `b_test > 0`, the classifier returns EXEMPT, and the gate
# never fires. It is installed, it reports healthy, and it is inert.
#
# This FAILS OPEN, which is the reason it outranks a merely wrong number. An
# UNRESOLVABLE base already skips the axis and falls through to fire — correct,
# and unchanged by the fix. A resolvable-but-WRONG base is the dangerous shape,
# and it is the common one, because `main` usually exists even where it is not
# the trunk.
#
# CASES
#   M0   the `# BL-286-INTEGRATION-BRANCH` marker occurs exactly once.
#   A0   the fixture builds and the gate runs (honest-outcome control).
#   A1   KEY PRESENT AND VALID — impl-only `feat:` on a branch cut from the
#        real trunk, with a test sitting in the main..trunk divergence, must
#        BLOCK. THE discriminator: on unfixed code the divergence test exempts
#        it and the gate allows.
#   A2   key present, a test rode earlier on THIS branch → ALLOW. Proves the
#        axis still WORKS against the resolved base rather than being disabled.
#   A3   key present, a test staged alongside the impl → ALLOW (control).
#   B1-B5  KEY ABSENT — the compatibility guarantee. Each drives the same
#        fixture twice at the same path, once with the shipped script and once
#        with a reconstruction of the pre-fix script, and requires the combined
#        stdout+stderr to be BYTE-IDENTICAL and the rc equal. Absent manifest,
#        manifest without the key, key `null`, key `""`, and an unresolvable
#        base.
#   C1   BASE UNRESOLVABLE — a key naming a branch that exists nowhere must
#        fail CLOSED and fire, with no quiet fall-back to `main`, even though
#        `main` resolves and carries a test in the divergence.
#   MP1-MP3  mutants. Each is named with the case that kills it.
#
# The pre-fix reconstruction (`mk_prefix`) is built by reverse-mutating the
# shipped file and is asserted to have landed before any B case trusts it —
# without that assertion B would compare the script against itself and pass
# vacuously.
#
# REGISTRATION: no init.sh, not an aggregator → BOTH lists.
# Hermetic: mktemp fixtures, local git identity, no network. bash-3.2 safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$REPO_ROOT/scripts/pre-commit-gate.sh"

MARKER="# BL-286-INTEGRATION-BRANCH"

PASSED=0
FAILED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }

TOPTMP="$(mktemp -d)"
trap 'rm -rf "$TOPTMP"' EXIT INT TERM

[ -f "$GATE" ] || { echo "  [FAIL] setup — $GATE not found"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  [FAIL] setup — jq is required"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }

# mk_proj <dir> <manifest-json> [trunk]
# A sponsored-POC scratch project — the NON-bypassable tier, so a firing TDD
# gate HARD-BLOCKS (rc 1) rather than warns, which is what makes "fired" and
# "did not fire" distinguishable by exit status alone. current_phase=1 keeps
# the BL-006 message check short-circuited so the TDD arm alone decides.
#
# Topology, which is the whole fixture:
#   main    — README only, NO test
#   <trunk> — cut from main, adds tests/regression.sh   ← the divergence test
#   feature — cut from <trunk>, nothing committed yet
# So `main...HEAD` carries a test and `<trunk>...HEAD` does not. Pass trunk=""
# to build a main-only project (no second branch, HEAD stays on main).
mk_proj() {
  # `${3-preview}`, NOT `${3:-preview}`: the B cases pass an EMPTY trunk to ask
  # for a main-only project, and `:-` would substitute the default for it and
  # silently build the two-branch topology instead.
  local d="$1" manifest="$2" trunk="${3-preview}"
  rm -rf "$d"
  mkdir -p "$d/.claude" "$d/scripts/lib" || return 1
  (
    cd "$d" || exit 1
    git init -q || exit 1
    git symbolic-ref HEAD refs/heads/main || exit 1
    git config user.email "bl286@test.invalid" || exit 1
    git config user.name  "BL-286 Test" || exit 1
    git config commit.gpgsign false || exit 1
    echo "# scratch" > README.md
    git add README.md || exit 1
    git commit -q -m "chore: init" || exit 1
    if [ -n "$trunk" ]; then
      git checkout -q -b "$trunk" || exit 1
      mkdir -p tests
      printf 'assert 1 == 1\n' > tests/regression.sh
      git add tests/regression.sh || exit 1
      git commit -q -m "test: a test that rode on the real trunk" || exit 1
      git checkout -q -b feature || exit 1
    fi
  ) || return 1
  if [ -n "$manifest" ]; then
    printf '%s\n' "$manifest" > "$d/.claude/manifest.json"
    jq empty "$d/.claude/manifest.json" >/dev/null 2>&1 || return 1
  fi
  cat > "$d/.claude/phase-state.json" <<'PS'
{"current_phase":1,"track":"full","deployment":"organizational","poc_mode":"sponsored_poc","phases":{}}
PS
  cat > "$d/.claude/process-state.json" <<'PRS'
{"phase2_init":{"steps_completed":[],"verified":false},"build_loop":{"feature":null,"step":0,"steps_completed":[]},"uat_session":{},"phase3_validation":{},"phase4_release":{}}
PRS
  cp "$GATE" "$d/scripts/" || return 1
  cp "$REPO_ROOT/scripts/process-checklist.sh" "$d/scripts/" || return 1
  cp "$REPO_ROOT/scripts/lib/helpers.sh" \
     "$REPO_ROOT/scripts/lib/helpers-core.sh" \
     "$REPO_ROOT/scripts/lib/helpers-full.sh" \
     "$REPO_ROOT/scripts/lib/tdd-classify.sh" "$d/scripts/lib/" || return 1
  chmod +x "$d/scripts/pre-commit-gate.sh" "$d/scripts/process-checklist.sh"
  return 0
}

MANIFEST_BASE='"frameworkVersion":"test","host":"other","mode":"personal","deployment":"organizational","enforcement_level":"strict"'

# stage_impl <dir> — one implementation file, no test.
stage_impl() {
  mkdir -p "$1/src" && printf 'export const add = (a, b) => a + b;\n' > "$1/src/add.ts" \
    && ( cd "$1" && git add src/add.ts )
}

# run_gate <dir> <subject> → GATE_OUT, GATE_RC
run_gate() {
  local d="$1" subject="$2"
  printf '%s\n' "$subject" > "$d/.git/COMMIT_EDITMSG"
  GATE_OUT="$( cd "$d" && bash scripts/pre-commit-gate.sh --terminal-mode --tdd-only 2>&1 )"
  GATE_RC=$?
  return 0
}

# run_gate_to <dir> <subject> <outfile> — combined stdout+stderr to <outfile>;
# echoes the rc. Used by the B cases, which compare BYTES, so the gate must run
# from the same cwd at the same script path in both halves.
run_gate_to() {
  local d="$1" subject="$2" out="$3"
  printf '%s\n' "$subject" > "$d/.git/COMMIT_EDITMSG"
  rm -f "$d/.claude/tdd-warn-ledger.jsonl"
  ( cd "$d" && bash scripts/pre-commit-gate.sh --terminal-mode --tdd-only ) > "$out" 2>&1
  printf '%s\n' "$?"
}

# mk_prefix <outfile> — reconstruct the PRE-FIX script: drop the marker block
# and restore the literal `main` base resolution. Returns 1 if the reverse
# mutation did not land, because a B case comparing the shipped file against
# itself would pass for the wrong reason.
mk_prefix() {
  local out="$1" mark_ln end_ln
  mark_ln="$(grep -n "${MARKER}" "$GATE" | head -1 | cut -d: -f1)"
  end_ln="$(grep -n '^  \[ -n "\$_ib" \] || _ib="main"$' "$GATE" | head -1 | cut -d: -f1)"
  [ -n "$mark_ln" ] && [ -n "$end_ln" ] && [ "$end_ln" -gt "$mark_ln" ] || return 1
  # the blank line separating the resolution from `local base=""` goes too
  {
    head -n $((mark_ln - 1)) "$GATE"
    tail -n +$((end_ln + 2)) "$GATE"
  } | sed \
      -e 's|git rev-parse --verify --quiet "\$_ib"|git rev-parse --verify --quiet main|' \
      -e 's|base="\$_ib"|base="main"|' \
      -e 's|git rev-parse --verify --quiet "origin/\$_ib"|git rev-parse --verify --quiet origin/main|' \
      -e 's|base="origin/\$_ib"|base="origin/main"|' > "$out"
  bash -n "$out" 2>/dev/null || return 1
  [ "$(grep -c '_ib' "$out")" -eq 0 ] || return 1
  [ "$(grep -c "${MARKER}" "$out")" -eq 0 ] || return 1
  [ "$(grep -c '^    base="main"$' "$out")" -eq 1 ] || return 1
  [ "$(grep -c '^    base="origin/main"$' "$out")" -eq 1 ] || return 1
  [ "$(grep -c '^  if git rev-parse --verify --quiet main >/dev/null 2>&1; then$' "$out")" -eq 1 ] || return 1
  [ "$(grep -c '^  elif git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then$' "$out")" -eq 1 ] || return 1
  return 0
}

PREFIX="$TOPTMP/pre-fix-gate.sh"
PREFIX_OK=0
if mk_prefix "$PREFIX"; then
  PREFIX_OK=1
fi

# compat_case <label> <manifest> <mode> <want-rc> <description>
# Drives one fixture through the shipped script and the pre-fix reconstruction
# at the SAME path from the SAME cwd, and requires byte-identical combined
# output and an equal rc. <want-rc> pins what today's behaviour actually IS, so
# the case cannot pass on two vacuous halves agreeing with each other.
compat_case() {
  local label="$1" manifest="$2" mode="$3" want_rc="$4" desc="$5" trunk=""
  if [ "$PREFIX_OK" -ne 1 ]; then
    fail_ "$label" "the pre-fix reconstruction did not build — nothing to compare against"
    return 0
  fi
  local d="$TOPTMP/$label"
  if ! mk_proj "$d" "$manifest" "$trunk"; then
    fail_ "$label" "fixture setup failed"
    return 0
  fi
  case "$mode" in
    impl)
      stage_impl "$d" || { fail_ "$label" "could not stage the impl file"; return 0; } ;;
    branch-test)
      # a test rides EARLIER on a branch cut from main, then impl-only is
      # staged — so `main...HEAD` is non-empty and carries that test
      mkdir -p "$d/tests"
      printf 'assert 2 == 2\n' > "$d/tests/add.test.sh"
      ( cd "$d" && git checkout -q -b feature && git add tests/add.test.sh \
          && git commit -q -m "test: add cases" ) \
        || { fail_ "$label" "could not commit the earlier branch test"; return 0; }
      stage_impl "$d" || { fail_ "$label" "could not stage the impl file"; return 0; } ;;
  esac
  local fixed_out="$TOPTMP/$label.fixed" pre_out="$TOPTMP/$label.pre" fixed_rc pre_rc
  fixed_rc="$(run_gate_to "$d" "feat: add" "$fixed_out")"
  cp "$PREFIX" "$d/scripts/pre-commit-gate.sh" || { fail_ "$label" "could not install the pre-fix script"; return 0; }
  pre_rc="$(run_gate_to "$d" "feat: add" "$pre_out")"
  if [ "$fixed_rc" != "$want_rc" ]; then
    fail_ "$label" "$desc: today's behaviour here is rc=$want_rc and the shipped gate answered rc=$fixed_rc — this fixture is not exercising what the case claims"
  elif [ "$fixed_rc" = "$pre_rc" ] && cmp -s "$fixed_out" "$pre_out"; then
    pass "$label — $desc: byte-identical output and rc ($fixed_rc) with and without the fix"
  else
    fail_ "$label" "$desc: behaviour CHANGED for a keyless project — rc fixed=$fixed_rc pre-fix=$pre_rc; first difference: $(diff "$pre_out" "$fixed_out" 2>/dev/null | head -3 | tr '\n' ' ')"
  fi
  return 0
}

echo "=== M0 — the marker ==="
n="$(grep -c "${MARKER}" "$GATE" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
if [ "$n" = "1" ]; then
  pass "M0 — '$MARKER' occurs exactly once in pre-commit-gate.sh"
else
  fail_ "M0" "'$MARKER' occurs $n times in pre-commit-gate.sh (need exactly 1)"
fi

echo "=== A — the key is present and valid ==="

A_MANIFEST="{$MANIFEST_BASE,\"integration_branch\":\"preview\"}"

PA="$TOPTMP/a1"
if ! mk_proj "$PA" "$A_MANIFEST" preview; then
  fail_ "A0" "fixture setup failed"
else
  # A0 — the topology the whole suite rests on, asserted rather than assumed.
  a_main="$( cd "$PA" && git diff --name-status main...HEAD | grep -c 'tests/' )"
  a_trunk="$( cd "$PA" && git diff --name-status preview...HEAD | grep -c 'tests/' )"
  if [ "$a_main" -gt 0 ] && [ "$a_trunk" -eq 0 ]; then
    pass "A0 — the fixture diverges as designed: main...HEAD carries a test, preview...HEAD does not"
  else
    fail_ "A0" "fixture topology is wrong (tests in main...HEAD=$a_main, in preview...HEAD=$a_trunk)"
  fi

  if ! stage_impl "$PA"; then
    fail_ "A1" "could not stage the impl file"
  else
    run_gate "$PA" "feat: add"
    if [ "$GATE_RC" -ne 0 ]; then
      pass "A1 — with integration_branch=preview, a test-less feat: on a branch cut from preview is BLOCKED (rc=$GATE_RC)"
    else
      fail_ "A1" "the gate ALLOWED a test-less feat: (rc=$GATE_RC) — the branch axis measured main...HEAD, saw the divergence test, and exempted the commit; the gate is inert on this project"
    fi
  fi
fi

PA2="$TOPTMP/a2"
if ! mk_proj "$PA2" "$A_MANIFEST" preview; then
  fail_ "A2" "fixture setup failed"
else
  mkdir -p "$PA2/tests"
  printf 'assert 2 == 2\n' > "$PA2/tests/add.test.sh"
  if ! ( cd "$PA2" && git add tests/add.test.sh && git commit -q -m "test: add cases" ) \
     || ! stage_impl "$PA2"; then
    fail_ "A2" "could not build the earlier-test history"
  else
    run_gate "$PA2" "feat: add"
    if [ "$GATE_RC" -eq 0 ]; then
      pass "A2 — a test that rode earlier on THIS branch still exempts (rc=0): the axis works against the resolved base, it is not disabled"
    else
      fail_ "A2" "a commit whose test rode earlier on the branch was BLOCKED (rc=$GATE_RC) — the branch axis no longer sees its own history: $(printf '%s' "$GATE_OUT" | grep -E 'FAIL|BLOCK' | head -1)"
    fi
  fi
fi

PA3="$TOPTMP/a3"
if ! mk_proj "$PA3" "$A_MANIFEST" preview; then
  fail_ "A3" "fixture setup failed"
else
  mkdir -p "$PA3/tests"
  printf 'assert 2 == 2\n' > "$PA3/tests/add.test.sh"
  if ! stage_impl "$PA3" || ! ( cd "$PA3" && git add tests/add.test.sh ); then
    fail_ "A3" "could not stage impl + test"
  else
    run_gate "$PA3" "feat: add"
    if [ "$GATE_RC" -eq 0 ]; then
      pass "A3 — a test STAGED alongside the impl still exempts (rc=0)"
    else
      fail_ "A3" "a commit staging impl AND test was BLOCKED (rc=$GATE_RC) — the staged axis is misreading: $(printf '%s' "$GATE_OUT" | grep -E 'FAIL|BLOCK' | head -1)"
    fi
  fi
fi

echo "=== B — the key is absent: BYTE-IDENTICAL to the pre-fix behaviour ==="
if [ "$PREFIX_OK" -eq 1 ]; then
  pass "B0 — the pre-fix reconstruction built and the reverse mutation landed (no _ib, literal main restored)"
else
  fail_ "B0" "could not reconstruct the pre-fix script — the compatibility guarantee is unmeasured, not met"
fi

compat_case b1 ""                                            impl        1 "no manifest at all, main-trunk project, impl-only feat:"
compat_case b2 "{$MANIFEST_BASE}"                            branch-test 0 "a manifest with no integration_branch key, test earlier on the branch"
compat_case b3 "{$MANIFEST_BASE,\"integration_branch\":null}" impl        1 "integration_branch: null"
compat_case b4 "{$MANIFEST_BASE,\"integration_branch\":\"\"}"   impl        1 "integration_branch: empty string"

# b5 — no `main` anywhere. mk_proj always creates main, so rename it away.
if [ "$PREFIX_OK" -ne 1 ]; then
  fail_ "b5" "the pre-fix reconstruction did not build — nothing to compare against"
else
  PB5="$TOPTMP/b5"
  if ! mk_proj "$PB5" "{$MANIFEST_BASE}" ""; then
    fail_ "b5" "fixture setup failed"
  elif ! ( cd "$PB5" && git branch -m main trunk ) || ! stage_impl "$PB5"; then
    fail_ "b5" "could not build the no-main fixture"
  elif ( cd "$PB5" && git rev-parse --verify --quiet main >/dev/null 2>&1 ); then
    fail_ "b5" "the fixture still resolves 'main' — the unresolvable-base case is not being exercised"
  else
    b5_fixed_rc="$(run_gate_to "$PB5" "feat: add" "$TOPTMP/b5.fixed")"
    cp "$PREFIX" "$PB5/scripts/pre-commit-gate.sh"
    b5_pre_rc="$(run_gate_to "$PB5" "feat: add" "$TOPTMP/b5.pre")"
    if [ "$b5_fixed_rc" = "$b5_pre_rc" ] && cmp -s "$TOPTMP/b5.fixed" "$TOPTMP/b5.pre" && [ "$b5_fixed_rc" -ne 0 ]; then
      pass "b5 — an UNRESOLVABLE base still fails CLOSED and fires (rc=$b5_fixed_rc), byte-identically with and without the fix"
    else
      fail_ "b5" "unresolvable base: rc fixed=$b5_fixed_rc pre-fix=$b5_pre_rc (must be equal AND non-zero); first difference: $(diff "$TOPTMP/b5.pre" "$TOPTMP/b5.fixed" 2>/dev/null | head -3 | tr '\n' ' ')"
    fi
  fi
fi

echo "=== C — the key names a branch that resolves nowhere ==="
PC="$TOPTMP/c1"
C_MANIFEST="{$MANIFEST_BASE,\"integration_branch\":\"no-such-trunk\"}"
if ! mk_proj "$PC" "$C_MANIFEST" preview; then
  fail_ "C1" "fixture setup failed"
elif ! stage_impl "$PC"; then
  fail_ "C1" "could not stage the impl file"
else
  run_gate "$PC" "feat: add"
  if [ "$GATE_RC" -ne 0 ]; then
    pass "C1 — an unresolvable key fails CLOSED and the gate fires (rc=$GATE_RC); it does not quietly fall back to main"
  else
    fail_ "C1" "the gate ALLOWED (rc=$GATE_RC) — an unresolvable integration_branch fell back to a base that resolves, re-opening the fail-open"
  fi
fi

echo "=== MP — mutation proof ==="

# MP1 — the pre-fix code IS the mutation: restore the literal `main`. A1's
# fixture must go back to being allowed. A1 is the case that catches this.
if [ "$PREFIX_OK" -ne 1 ]; then
  fail_ "MP1 (MUTATION)" "the pre-fix reconstruction did not build"
else
  PM1="$TOPTMP/mp1"
  if ! mk_proj "$PM1" "$A_MANIFEST" preview || ! stage_impl "$PM1"; then
    fail_ "MP1 (MUTATION)" "fixture setup failed"
  else
    cp "$PREFIX" "$PM1/scripts/pre-commit-gate.sh"
    run_gate "$PM1" "feat: add"
    if [ "$GATE_RC" -eq 0 ]; then
      pass "MP1 (MUTATION) — with the literal 'main' restored, the test-less feat: is ALLOWED again (rc=0): A1 is the case that stops it"
    else
      fail_ "MP1 (MUTATION)" "restoring the literal 'main' changed nothing (rc=$GATE_RC) — A1 may be passing for another reason"
    fi
  fi
fi

# MP2 — delete the `_ib` fallback so an ABSENT key leaves the base empty. The
# axis is then skipped on every keyless project and the gate fires where it
# used to exempt. b2 is the case that catches this.
MP2_SCRIPT="$TOPTMP/mp2-gate.sh"
if ! grep -v '^  \[ -n "\$_ib" \] || _ib="main"$' "$GATE" > "$MP2_SCRIPT" \
   || ! bash -n "$MP2_SCRIPT" 2>/dev/null \
   || [ "$(grep -c '^  \[ -n "\$_ib" \] || _ib="main"$' "$MP2_SCRIPT")" -ne 0 ] \
   || [ "$(diff "$GATE" "$MP2_SCRIPT" 2>/dev/null | grep -c '^[<>]')" -ne 1 ]; then
  fail_ "MP2 (MUTATION) setup" "the dropped-fallback mutation did not apply cleanly"
else
  PM2="$TOPTMP/mp2"
  if ! mk_proj "$PM2" "{$MANIFEST_BASE}" ""; then
    fail_ "MP2 (MUTATION)" "fixture setup failed"
  else
    mkdir -p "$PM2/tests"
    printf 'assert 2 == 2\n' > "$PM2/tests/add.test.sh"
    if ! ( cd "$PM2" && git checkout -q -b feature && git add tests/add.test.sh \
             && git commit -q -m "test: add cases" ) \
       || ! stage_impl "$PM2"; then
      fail_ "MP2 (MUTATION)" "could not build the earlier-test history"
    else
      mp2_base_rc="$(run_gate_to "$PM2" "feat: add" "$TOPTMP/mp2.base")"
      cp "$MP2_SCRIPT" "$PM2/scripts/pre-commit-gate.sh"
      mp2_mut_rc="$(run_gate_to "$PM2" "feat: add" "$TOPTMP/mp2.mut")"
      if [ "$mp2_base_rc" != "$mp2_mut_rc" ] || ! cmp -s "$TOPTMP/mp2.base" "$TOPTMP/mp2.mut"; then
        pass "MP2 (MUTATION) — dropping the '_ib' fallback changes a KEYLESS project's outcome (rc $mp2_base_rc → $mp2_mut_rc): b2 is the case that stops it"
      else
        fail_ "MP2 (MUTATION)" "dropping the fallback changed nothing (rc=$mp2_mut_rc both ways) — b2 may be passing for another reason"
      fi
    fi
  fi
fi

# MP3 — add a permissive fall-back to `main` when the key does not resolve.
# That re-opens exactly the fail-open this entry is about, on the branch where
# the base is unresolvable. C1 is the case that catches this.
MP3_SCRIPT="$TOPTMP/mp3-gate.sh"
mp3_anchor="$(grep -n '^  if \[ -n "\$base" \]; then$' "$GATE" | head -1 | cut -d: -f1)"
if [ -z "$mp3_anchor" ]; then
  fail_ "MP3 (MUTATION) setup" "could not locate the base guard"
else
  {
    head -n $((mp3_anchor - 1)) "$GATE"
    printf '%s\n' '  [ -n "$base" ] || base="main"'
    tail -n +"$mp3_anchor" "$GATE"
  } > "$MP3_SCRIPT"
  if ! bash -n "$MP3_SCRIPT" 2>/dev/null \
     || [ "$(diff "$GATE" "$MP3_SCRIPT" 2>/dev/null | grep -c '^[<>]')" -ne 1 ]; then
    fail_ "MP3 (MUTATION) setup" "the permissive-fallback mutation did not apply cleanly"
  else
    PM3="$TOPTMP/mp3"
    if ! mk_proj "$PM3" "$C_MANIFEST" preview || ! stage_impl "$PM3"; then
      fail_ "MP3 (MUTATION)" "fixture setup failed"
    else
      cp "$MP3_SCRIPT" "$PM3/scripts/pre-commit-gate.sh"
      run_gate "$PM3" "feat: add"
      if [ "$GATE_RC" -eq 0 ]; then
        pass "MP3 (MUTATION) — a fall-back to 'main' on an unresolvable key ALLOWS the test-less feat: again (rc=0): C1 is the case that stops it"
      else
        fail_ "MP3 (MUTATION)" "the permissive fall-back changed nothing (rc=$GATE_RC) — C1 may be passing for another reason"
      fi
    fi
  fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
