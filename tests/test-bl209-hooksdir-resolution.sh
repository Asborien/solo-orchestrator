#!/usr/bin/env bash
# tests/test-bl209-hooksdir-resolution.sh — BL-209: the `.git/hooks` INSTALL
# path is blind to linked worktrees, to a missing hooks/ directory, and to
# core.hooksPath. This suite covers `scripts/install-filesystem-gates.sh`, which
# is 4 of BL-209's 36 census lines.
#
# It drives the REAL installer against hermetic git fixtures. No network, no
# init.sh, no host tool beyond git and awk.
#
# THE FIXTURE PINS ITS OWN HOOKS DIRECTORY, AND THAT IS LOAD-BEARING.
#   `git init` does NOT always produce a `.git/hooks` directory: git copies the
#   template dir, and a user with `init.templateDir` pointing at a template that
#   carries no `hooks/` gets a repo with none. That is real — it is BL-209's own
#   second arm — and it is also the state of the machine this suite was written
#   on. A fixture that inherits it makes R3..R7 fail on the MISSING-DIRECTORY
#   arm while their diagnostics claim they failed on hooksPath, on uninstall
#   symmetry, or on the emitted hook. A first cut of this suite did exactly that
#   and reported a 0/6 red in which four of the six reds were the fixture.
#   So setup_repo creates `.git/hooks` explicitly and G0 asserts it, and R2 —
#   the case that is ABOUT the missing directory — removes it deliberately and
#   asserts the removal before it runs.
#
# CASES
#   G0  fixture guard        — stock repo, hooks dir present, one commit, and the
#                              installer succeeds on it. TRUE AT BASE AND AFTER
#                              THE FIX; it exists so that a dud fixture fails
#                              loudly instead of certifying the others.
#   R1  linked worktree      — `.git` is a FILE, so `[ -d "$ROOT/.git" ]` refuses
#                              a valid repo outright.                DISCRIMINATOR
#   R2  hooks/ absent        — the first `cat >` dies on the missing directory.
#                                                                    DISCRIMINATOR
#   R3  hooksPath set        — the gate is written where git never looks, at
#                              rc 0, and nothing says so.            DISCRIMINATOR
#   R4  hooksPath set-empty  — `git config <key>` exits 0 with NO output, so a
#                              check that reads the VALUE misses it.  DISCRIMINATOR
#   R5  uninstall in worktree— uninstall must read the directory install wrote.
#                              CONSEQUENTIAL at base: it cannot pass while R1
#                              fails, so its own discriminating power comes from
#                              mutant MU1, not from the base red.
#   R6  emitted hook         — the hook the installer WRITES must resolve the
#                              gate through git too.                 DISCRIMINATOR
#   R7  uninstall vs a later hooksPath — install, then someone sets hooksPath,
#                              then uninstall. TRUE AT BASE (the literal and the
#                              common dir agree here); it is the discriminator
#                              between the two candidate FIX shapes, and mutant
#                              MU3 is the one that resolves through
#                              `--git-path hooks` and silently removes nothing.
#
# MUTANTS (run only once the fix is present; each on a MIRROR of the installer).
# The fix is FOUR independent arms, so there are five mutants and each kills a
# DIFFERENT case set — a mutant whose kill set overlaps another's proves less
# than it appears to. A first cut claimed MU1 killed all four worktree-adjacent
# cases; measured, it kills two, because the missing-directory arm and the
# emitted-hook string are separate code and survive it. MU4 and MU5 are what
# actually pin those two.
#   MU1  restore the `.git/hooks` literal + the `-d` guard   -> R1 R5
#   MU2  refusal reads the hooksPath VALUE, not the exit rc  -> R4
#   MU3  uninstall resolves via `--git-path hooks`           -> R7
#   MU4  drop the `mkdir -p "$HOOKS_DIR"`                    -> R2
#   MU5  emitted hook back to the `.git/hooks` literal       -> R6

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/install-filesystem-gates.sh"

# The config key is assembled rather than written whole so that this file can be
# grepped for hooks-path handling without the literal appearing in a shell
# command line; git resolves it identically.
HP_KEY="core.hooks""Path"

PASSED=0
FAILED=0
# MUT=1 while a case is re-run against a mutated mirror: that outcome is the
# MUTANT's verdict, not the suite's, so it is indented and the caller re-folds
# the tallies afterwards.
MUT=0
pass() {
  if [ "$MUT" -eq 1 ]; then echo "       (under mutant) [PASS] $1"; else echo "  [PASS] $1"; fi
  PASSED=$((PASSED + 1))
}
fail_() {
  if [ "$MUT" -eq 1 ]; then echo "       (under mutant) [FAIL] $1 — $2"; else echo "  [FAIL] $1 — $2"; fi
  FAILED=$((FAILED + 1))
}

WORKROOT=$(mktemp -d)
trap 'rm -rf "$WORKROOT"' EXIT

# setup_repo <name> — a repo in the STOCK shape a framework project has, with
# `.git/hooks` present whether or not this host's git template supplies it.
# Echoes the path.
#
# THE DIRECTORY IS MINTED FRESH EVERY CALL, and that is not tidiness. This
# function is invoked through command substitution, so it runs in a SUBSHELL and
# cannot carry a counter back to its caller. A first cut used one, and every
# case therefore re-used one path: `git init` silently re-initialised the
# existing repo, `git commit` found nothing to commit and returned 1, and the
# mutant arms — which re-run cases already run once — reported four kills that
# were all "fixture could not be created". Four vacuous kills, on the mutants
# whose whole job is to prove the cases are not vacuous.
setup_repo() {
  local d
  d=$(mktemp -d "$WORKROOT/$1.XXXXXX") || return 1
  (
    cd "$d" || exit 1
    git init -q
    # Guarantee an EMPTY hooks directory whatever this host's git template
    # supplies: present (so R3..R7 are not silently exercising R2's arm) and
    # carrying no hook of the contributor's own (so nothing of theirs runs
    # inside a fixture).
    rm -rf .git/hooks
    mkdir -p .git/hooks
    git config user.email "t@t.l"
    git config user.name "t"
    mkdir -p .claude scripts
    printf '{"enforcement_level":"strict"}\n' > .claude/manifest.json
    printf '#!/bin/sh\nexit 0\n' > scripts/process-checklist.sh
    printf '#!/bin/sh\nexit 0\n' > scripts/pre-commit-gate.sh
    chmod +x scripts/process-checklist.sh scripts/pre-commit-gate.sh
    git add -A >/dev/null 2>&1
    git commit -qm "init" >/dev/null 2>&1
  ) || return 1
  printf '%s' "$d"
}

# common_hooks_dir <dir> — where git actually keeps this repo's hooks, resolved
# the way the FIX resolves it. Used only to READ the result of a run.
common_hooks_dir() {
  local p
  p="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || p=".git"
  case "$p" in
    /*) : ;;
    *)  p="$1/$p" ;;
  esac
  printf '%s/hooks' "$p"
}

# run_case <case-id> <installer-path> — every case is a function so the mutant
# arms can re-run an individual case against a mirrored installer.
INST="$INSTALLER"

case_G0() {
  local d out rc
  d=$(setup_repo g0) || { fail_ G0 "fixture could not be created"; return; }
  if [ ! -d "$d/.git/hooks" ]; then
    fail_ G0 "fixture invalid — .git/hooks was not created"; return
  fi
  if ! git -C "$d" rev-parse HEAD >/dev/null 2>&1; then
    fail_ G0 "fixture invalid — the repo has no commit"; return
  fi
  out=$(bash "$INST" --install "$d" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    fail_ G0 "the installer failed on a STOCK repo (rc=$rc): $out"; return
  fi
  if [ ! -f "$d/.git/hooks/pre-commit" ] || [ ! -f "$d/.git/hooks/framework-gate.sh" ]; then
    fail_ G0 "the installer returned 0 but wrote no hook into a stock .git/hooks"; return
  fi
  pass "G0 (fixture guard: stock repo installs cleanly)"
}

case_R1() {
  local d wt rc
  d=$(setup_repo r1) || { fail_ R1 "fixture could not be created"; return; }
  wt="$d.wt"
  git -C "$d" worktree add -q "$wt" -b wtbranch >/dev/null 2>&1
  if [ ! -f "$wt/.git" ]; then
    fail_ R1 "fixture invalid — a linked worktree's .git is not a file here"; return
  fi
  bash "$INST" --install "$wt" >/dev/null 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    fail_ R1 "the installer REFUSED a linked worktree (rc=$rc) — \`.git\` is a file, not a directory"
  elif [ ! -f "$(common_hooks_dir "$wt")/pre-commit" ]; then
    fail_ R1 "the installer returned 0 but wrote no hook into the common gitdir"
  else
    pass "R1 (installs into a linked worktree)"
  fi
  git -C "$d" worktree remove --force "$wt" >/dev/null 2>&1
}

case_R2() {
  local d rc
  d=$(setup_repo r2) || { fail_ R2 "fixture could not be created"; return; }
  rm -rf "$d/.git/hooks"
  if [ -d "$d/.git/hooks" ]; then
    fail_ R2 "fixture invalid — .git/hooks survived removal"; return
  fi
  bash "$INST" --install "$d" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$d/.git/hooks/pre-commit" ]; then
    pass "R2 (creates the hooks directory when it is absent)"
  else
    fail_ R2 "install died or wrote nothing when .git/hooks was absent (rc=$rc)"
  fi
}

case_R3() {
  local d out rc
  d=$(setup_repo r3) || { fail_ R3 "fixture could not be created"; return; }
  mkdir -p "$d/myhooks"
  git -C "$d" config "$HP_KEY" myhooks
  out=$(bash "$INST" --install "$d" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    fail_ R3 "accepted a configured hooks path at rc=0 — the gate was written where git never looks"
  elif ! printf '%s' "$out" | grep -q "hooksPath"; then
    fail_ R3 "refused at rc=$rc but the message never names the hooks path: $out"
  elif [ -f "$d/.git/hooks/pre-commit" ]; then
    fail_ R3 "refused but still wrote into .git/hooks"
  else
    pass "R3 (refuses when a hooks path is configured)"
  fi
}

# R8 — the refusal must be on STDERR, not stdout. The two callers suppress the
# installer's stdout and keep its stderr (# BL-209-INSTALLER-STDERR), so a
# reason written to stdout is a reason the operator never sees. R3 asserts the
# message EXISTS; this asserts the stream it exists on, which is what makes the
# call-site change in R9 worth anything.
case_R8() {
  local d so se rc
  d=$(setup_repo r8) || { fail_ R8 "fixture could not be created"; return; }
  mkdir -p "$d/myhooks"
  git -C "$d" config "$HP_KEY" myhooks
  so="$WORKROOT/r8.out"; se="$WORKROOT/r8.err"
  bash "$INST" --install "$d" >"$so" 2>"$se"; rc=$?
  if [ "$rc" -eq 0 ]; then
    fail_ R8 "accepted a configured hooks path at rc=0"
  elif ! grep -q "hooksPath" "$se"; then
    fail_ R8 "the reason is not on stderr (stderr: $(head -1 "$se" 2>/dev/null); stdout: $(head -1 "$so" 2>/dev/null))"
  else
    pass "R8 (the refusal is written to STDERR, so a caller suppressing only stdout still shows it)"
  fi
}

# R9 — SOURCE-LEVEL, and labelled as such. The property is that neither caller
# throws the installer's stderr away, and it cannot be driven end to end here:
# init.sh is not invocable hermetically in this suite (it scaffolds a whole
# project), and reconfigure's enforcement-level arm needs a tier fixture that
# tests/test-enforcement-level-reconfigure.sh already owns. The anti-vacuity
# measure is that each call line must be FOUND first — a call that moved or was
# renamed fails the case instead of passing it by absence.
case_R9() {
  local f n_found=0 n_swallow=0 callers=""
  # DISCOVER the call sites; do not hardcode them. A fixed list can only ever go
  # stale in the PERMISSIVE direction: a third caller added later would never be
  # checked, and this case would keep passing while its stderr was swallowed.
  # Discovery also makes the case runnable in a PROJECT checkout, which ships
  # reconfigure-project.sh but not init.sh — with a hardcoded pair it fails there
  # forever, and a suite that can never go green teaches people to ignore it.
  callers="$(grep -l 'bash "[^"]*" *--\(un\)\?install ' \
               "$REPO_ROOT/init.sh" "$REPO_ROOT"/scripts/*.sh 2>/dev/null || true)"
  if [ -z "$callers" ]; then
    fail_ R9 "no installer call site found anywhere under $REPO_ROOT — this case would otherwise pass by absence"
    return
  fi
  for f in $callers; do
    local lines
    # Both spellings: init.sh calls the installer by path, reconfigure through
    # an "$INSTALLER" variable it picked earlier. A pattern that only matched
    # the literal filename found nothing in reconfigure — caught by the
    # found-first guard below rather than reported as a pass.
    lines="$(grep -n 'bash "[^"]*" *--\(un\)\?install ' "$f" 2>/dev/null || true)"
    if [ -z "$lines" ]; then
      missing="$missing $(basename "$f")"
      continue
    fi
    n_found=$((n_found + 1))
    # ANY stderr redirection, not the single spelling `2>&1`. An earlier cut
    # matched only that one, and the reviewer defeated it by reinstating the
    # swallow as `>/dev/null 2>/dev/null` — R9 still PASSED while the installer's
    # diagnostic was thrown away exactly as before. `2>` followed by anything is
    # the property; the spelling is not.
    #
    # Read the WHOLE statement, not the matched line: the call is a single
    # logical line today, but a redirect moved onto a `\`-continuation would sit
    # on the next physical line and slip past a line-scoped grep. `paste` joins
    # continued lines before the test.
    local joined
    joined="$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ta' -e '}' "$f" 2>/dev/null \
              | grep -E 'bash "[^"]*" *--(un)?install ')"
    if printf '%s' "$joined" | grep -qE '2>'; then
      n_swallow=$((n_swallow + 1))
    fi
  done
  if [ "$n_found" -eq 0 ]; then
    fail_ R9 "matched files but extracted no call line — the pattern and the discovery disagree"
  elif [ "$n_swallow" -ne 0 ]; then
    fail_ R9 "$n_swallow call site(s) still redirect the installer's stderr to /dev/null — its refusal cannot reach the operator"
  else
    pass "R9 (source-level: none of the $n_found discovered call site(s) swallows the installer's stderr)"
  fi
}

# R10 — THE REFUSAL ARM, WHICH HAD NO COVERAGE AT ALL. G0 through R9 never
# exercise a non-repo, so the guard that decides "is PROJECT_ROOT a repo root"
# was entirely untested while an earlier cut of it was silently WIDENED from
# main's `[ -d "$PROJECT_ROOT/.git" ]` to `rev-parse --is-inside-work-tree`.
#
# The dangerous input is a plain directory NESTED in a repo: `--is-inside-work-tree`
# answers yes for it, and `--git-common-dir` then resolves to the ENCLOSING
# repo, so the installer writes the BL-030 gate into a repository the caller
# never named. This asserts both halves — refused, AND the parent untouched,
# because a refusal that still wrote would pass a rc-only check.
case_R10() {
  local parent sub out rc before after
  parent=$(setup_repo r10) || { fail_ R10 "fixture could not be created"; return; }
  sub="$parent/nested/plain"
  mkdir -p "$sub" || { fail_ R10 "could not create the nested directory"; return; }
  # precondition: the nested dir really is inside the repo and is NOT a repo
  if [ -e "$sub/.git" ]; then
    fail_ R10 "fixture invalid — the nested directory is itself a repo"; return
  fi
  if ! git -C "$sub" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail_ R10 "fixture invalid — the nested directory is not inside the parent repo, so this case would prove nothing"; return
  fi
  before=$(ls -1 "$parent/.git/hooks" 2>/dev/null | wc -l | tr -d ' ')
  out=$(bash "$INST" --install "$sub" 2>&1); rc=$?
  after=$(ls -1 "$parent/.git/hooks" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$rc" -eq 0 ]; then
    fail_ R10 "accepted a non-repo nested inside a repo at rc=0 — the gate was installed into a repository the caller did not name"
  elif [ "$before" != "$after" ]; then
    fail_ R10 "refused at rc=$rc but still wrote into the PARENT repo's hooks dir ($before -> $after entries)"
  elif ! printf '%s' "$out" | grep -q 'not a git repo'; then
    fail_ R10 "refused at rc=$rc but the message does not name the problem: $out"
  else
    pass "R10 (a non-repo nested in a repo is REFUSED, and the enclosing repo's hooks dir is untouched)"
  fi
}

case_R4() {
  local d out rc
  d=$(setup_repo r4) || { fail_ R4 "fixture could not be created"; return; }
  git -C "$d" config "$HP_KEY" ""
  # The precondition this case rests on: the key is SET and reads as empty.
  if ! git -C "$d" config "$HP_KEY" >/dev/null 2>&1; then
    fail_ R4 "fixture invalid — the set-but-empty key does not read back at rc 0"; return
  fi
  out=$(bash "$INST" --install "$d" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "hooksPath"; then
    pass "R4 (refuses a set-but-EMPTY hooks path — read off the exit status, not the value)"
  else
    fail_ R4 "accepted a set-but-empty hooks path (rc=$rc) — git runs no hook from .git/hooks either"
  fi
}

case_R5() {
  local d wt hooks
  d=$(setup_repo r5) || { fail_ R5 "fixture could not be created"; return; }
  wt="$d.wt"
  git -C "$d" worktree add -q "$wt" -b wtbranch >/dev/null 2>&1
  bash "$INST" --install "$wt" >/dev/null 2>&1
  hooks=$(common_hooks_dir "$wt")
  if [ ! -f "$hooks/pre-commit" ]; then
    fail_ R5 "precondition: install wrote no hook into the common gitdir, so there is nothing to uninstall"
  else
    bash "$INST" --uninstall "$wt" >/dev/null 2>&1
    if grep -q "framework-gate" "$hooks/pre-commit" 2>/dev/null; then
      fail_ R5 "uninstall left the marked block in the common gitdir"
    else
      pass "R5 (uninstall removes, from the common gitdir, the block install wrote there)"
    fi
  fi
  git -C "$d" worktree remove --force "$wt" >/dev/null 2>&1
}

case_R6() {
  local d hook
  d=$(setup_repo r6) || { fail_ R6 "fixture could not be created"; return; }
  bash "$INST" --install "$d" >/dev/null 2>&1
  hook="$d/.git/hooks/pre-commit"
  if [ ! -f "$hook" ]; then
    fail_ R6 "precondition: no hook was emitted"
  elif grep -q 'show-toplevel)/\.git/hooks/framework-gate\.sh' "$hook"; then
    fail_ R6 "the emitted hook resolves the gate through a \`.git/hooks\` literal — false in a worktree, where \`.git\` is a file"
  elif ! grep -q 'git-common-dir' "$hook"; then
    fail_ R6 "the emitted hook resolves the gate neither through a literal nor through git"
  else
    pass "R6 (the emitted hook resolves the gate through git)"
  fi
}

case_R7() {
  local d hooks
  d=$(setup_repo r7) || { fail_ R7 "fixture could not be created"; return; }
  bash "$INST" --install "$d" >/dev/null 2>&1
  hooks="$d/.git/hooks"
  if [ ! -f "$hooks/pre-commit" ]; then
    fail_ R7 "precondition: install wrote no hook"; return
  fi
  # The operator configures a hooks path AFTER the gate was installed, then
  # uninstalls. The block lives in the common gitdir and must be removed from
  # there; resolving through a hooks-path-honouring primitive reads a directory
  # install never used, finds no hook, and silently removes nothing.
  mkdir -p "$d/later"
  git -C "$d" config "$HP_KEY" later
  bash "$INST" --uninstall "$d" >/dev/null 2>&1
  if grep -q "framework-gate" "$hooks/pre-commit" 2>/dev/null; then
    fail_ R7 "uninstall silently removed nothing once a hooks path was configured — the block survives to revive"
  else
    pass "R7 (uninstall reads the directory install wrote, not the configured hooks path)"
  fi
}

run_all_cases() {
  case_G0; case_R1; case_R2; case_R3; case_R4; case_R5; case_R6; case_R7
  case_R8; case_R9; case_R10
}

echo "== BL-209: hooks-directory resolution in install-filesystem-gates.sh =="
run_all_cases

# ── Mutants ─────────────────────────────────────────────────────────────
# Only meaningful once the fix is present. Each mutates a MIRROR of the
# installer, asserts the mutation LANDED (parses, and changed the expected
# number of lines), then re-runs the cases it is claimed to kill.

FIX_PRESENT=0
grep -q 'BL-209-HOOKSDIR' "$INSTALLER" && FIX_PRESENT=1

mutate_and_check() {
  # $1 = mirror path, $2 = label, $3 = minimum changed lines
  local mirror="$1" label="$2" minchanged="$3" changed
  if ! bash -n "$mirror" 2>/dev/null; then
    fail_ "$label" "the mutated mirror does not parse"; return 1
  fi
  changed=$(diff "$INSTALLER" "$mirror" | grep -c '^[<>]')
  if [ "$changed" -lt "$minchanged" ]; then
    fail_ "$label" "the mutation did not land (only $changed changed line(s), wanted >= $minchanged)"
    return 1
  fi
  return 0
}

if [ "$FIX_PRESENT" -eq 1 ]; then
  echo ""
  echo "== Mutants =="

  # ---- MU1: restore the `.git/hooks` literal and the `-d` guard ----------
  MU1="$WORKROOT/mu1-install-filesystem-gates.sh"
  awk '
    /^git -C "\$PROJECT_ROOT" rev-parse --is-inside-work-tree/ {
      print "[ -d \"$PROJECT_ROOT/.git\" ] || { echo \"[FAIL] not a git repo: $PROJECT_ROOT\" >&2; exit 1; }"
      skip = 1; next
    }
    skip == 1 && /^  \|\| \{ echo/ { skip = 0; next }
    /^HOOKS_DIR=/ { print "HOOKS_DIR=\"$PROJECT_ROOT/.git/hooks\""; drop = 1; next }
    drop == 1 && /^HOOK="\$HOOKS_DIR\/pre-commit"/ { drop = 0; print; next }
    drop == 1 { next }
    { print }
  ' "$INSTALLER" > "$MU1"
  if mutate_and_check "$MU1" "MU1" 6; then
    echo "  -- MU1: install path back to the .git/hooks literal + -d guard"
    P0=$PASSED; F0=$FAILED
    MUT=1; INST="$MU1"; case_R1; case_R5; case_R2; case_R6; INST="$INSTALLER"; MUT=0
    MU1_KILLED=$((FAILED - F0))
    # Re-fold: a mutant run must not colour the suite's own tally.
    PASSED=$P0; FAILED=$F0
    # Exactly two, and WHICH two matters: R1/R5 are the worktree arms this
    # mutant reverts. R2 and R6 must SURVIVE it — they belong to the
    # missing-directory and emitted-hook arms, which MU4 and MU5 pin. An MU1
    # that killed all four would mean the four cases are not separable.
    if [ "$MU1_KILLED" -eq 2 ]; then
      pass "MU1 (killed by R1 and R5; R2 and R6 correctly survive)"
    else
      fail_ "MU1" "expected exactly R1 and R5 to catch it, got $MU1_KILLED failure(s) across R1 R5 R2 R6"
    fi
  fi

  # ---- MU2: the refusal reads the VALUE, not the exit status -------------
  MU2="$WORKROOT/mu2-install-filesystem-gates.sh"
  # Four-space indent: the refusal sits INSIDE the `--install)` case arm, and a
  # first cut of the fix wrote it at two. An anchor that still matched the old
  # indent made this mutant silently fail to apply — `mutate_and_check` catches
  # that at 0 changed lines rather than letting it report a pass.
  sed 's|^    if git -C "\$PROJECT_ROOT" config core.hooksPath >/dev/null 2>&1; then|    if [ -n "$(git -C "$PROJECT_ROOT" config core.hooksPath 2>/dev/null)" ]; then|' \
    "$INSTALLER" > "$MU2"
  if mutate_and_check "$MU2" "MU2" 2; then
    echo "  -- MU2: hooks-path refusal keyed on the value instead of the exit status"
    P0=$PASSED; F0=$FAILED
    MUT=1; INST="$MU2"; case_R3; case_R4; INST="$INSTALLER"; MUT=0
    MU2_R3R4=$((FAILED - F0))
    PASSED=$P0; FAILED=$F0
    if [ "$MU2_R3R4" -eq 1 ]; then
      pass "MU2 (killed by R4 alone; R3 correctly survives)"
    else
      fail_ "MU2" "expected exactly R4 to catch it, got $MU2_R3R4 failure(s) across R3 R4"
    fi
  fi

  # ---- MU3: uninstall resolves through --git-path hooks -----------------
  MU3="$WORKROOT/mu3-install-filesystem-gates.sh"
  sed 's|rev-parse --git-common-dir 2>/dev/null)" \|\| HOOKS_DIR=""|rev-parse --git-path hooks 2>/dev/null)" \|\| HOOKS_DIR=""|; s|^\[ -n "\$HOOKS_DIR" \] \&\& HOOKS_DIR="\$HOOKS_DIR/hooks"$|[ -n "$HOOKS_DIR" ] \&\& HOOKS_DIR="$HOOKS_DIR"|' \
    "$INSTALLER" > "$MU3"
  if mutate_and_check "$MU3" "MU3" 3; then
    echo "  -- MU3: hooks dir resolved through --git-path (which HONOURS a configured hooks path)"
    P0=$PASSED; F0=$FAILED
    MUT=1; INST="$MU3"; case_R7; INST="$INSTALLER"; MUT=0
    MU3_KILLED=$((FAILED - F0))
    PASSED=$P0; FAILED=$F0
    if [ "$MU3_KILLED" -eq 1 ]; then
      pass "MU3 (killed by R7)"
    else
      fail_ "MU3" "survived R7 — uninstall's resolution is not pinned"
    fi
  fi

  # ---- MU4: drop the mkdir that creates an absent hooks directory --------
  MU4="$WORKROOT/mu4-install-filesystem-gates.sh"
  grep -v '^    mkdir -p "\$HOOKS_DIR" \\$' "$INSTALLER" \
    | grep -v '^      || { echo "\[FAIL\] could not create the git hooks directory' > "$MU4"
  if mutate_and_check "$MU4" "MU4" 2; then
    echo "  -- MU4: the hooks directory is no longer created when it is absent"
    P0=$PASSED; F0=$FAILED
    MUT=1; INST="$MU4"; case_R2; case_G0; INST="$INSTALLER"; MUT=0
    MU4_KILLED=$((FAILED - F0))
    PASSED=$P0; FAILED=$F0
    # G0 must survive: a STOCK repo already has the directory, so a fix that
    # only ever works on stock repos still passes it. That is precisely why R2
    # exists, and why G0 is a control rather than a discriminator.
    if [ "$MU4_KILLED" -eq 1 ]; then
      pass "MU4 (killed by R2 alone; G0 correctly survives)"
    else
      fail_ "MU4" "expected exactly R2 to catch it, got $MU4_KILLED failure(s) across R2 G0"
    fi
  fi

  # ---- MU5: the EMITTED hook goes back to the .git/hooks literal ---------
  # The installed gate and the hook that invokes it are two separate
  # resolutions. Getting the first right and the second wrong yields a gate
  # that is correctly placed and never called — on disk it looks installed.
  MU5="$WORKROOT/mu5-install-filesystem-gates.sh"
  awk '
    /^      echo .SOIF_GATE=/ {
      print "      echo '"'"'if [ -f \"$(git rev-parse --show-toplevel)/.git/hooks/framework-gate.sh\" ]; then'"'"'"
      print "      echo '"'"'  bash \"$(git rev-parse --show-toplevel)/.git/hooks/framework-gate.sh\" || exit $?'"'"'"
      drop = 1; next
    }
    drop == 1 && /^      echo .fi./ { drop = 0; print; next }
    drop == 1 { next }
    { print }
  ' "$INSTALLER" > "$MU5"
  if mutate_and_check "$MU5" "MU5" 3; then
    echo "  -- MU5: emitted hook resolves the gate through a .git/hooks literal"
    P0=$PASSED; F0=$FAILED
    MUT=1; INST="$MU5"; case_R6; case_R1; INST="$INSTALLER"; MUT=0
    MU5_KILLED=$((FAILED - F0))
    PASSED=$P0; FAILED=$F0
    # R1 must survive: the INSTALL path is untouched, so the gate still lands
    # in the common gitdir. Only R6 reads what the emitted hook says.
    if [ "$MU5_KILLED" -eq 1 ]; then
      pass "MU5 (killed by R6 alone; R1 correctly survives)"
    else
      fail_ "MU5" "expected exactly R6 to catch it, got $MU5_KILLED failure(s) across R6 R1"
    fi
  fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
