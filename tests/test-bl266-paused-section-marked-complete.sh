#!/usr/bin/env bash
# tests/test-bl266-paused-section-marked-complete.sh
#
# `## BL-266:` — TYPING `pause` FILED THE UNFINISHED SECTION AS COMPLETE,
# AND `--resume` THEN SKIPPED IT FOR GOOD.
#
# Every run_section_N in scripts/intake-wizard.sh ends in an unconditional
# `save_section N`. Typing `pause` at any prompt sets a sentinel file; from
# that moment prompt_input / prompt_choice / prompt_with_suggestions return
# the empty string at entry and save_answer refuses to write — but nothing
# stopped the trailing `save_section N`, so the section entered
# completed_sections carrying ZERO answers. On the next run
# is_section_complete saw it there and run_script_mode printed
# "Section N — already complete" and moved on. The operator is never asked
# those questions again, and no message says so.
#
# THE GUARD WRITES NOTHING, and that is the whole of it. `last_section`
# already holds the previous section's number, so it IS the resume point and
# there is nothing to record. An earlier cut computed one, which forced
# save_section to know the runner's ORDER (that 115's predecessor is 11,
# because `115 - 1` is not a section) and made it a third home for an ordering
# that belongs to run_script_mode. That cut is gone.
#
# CONSEQUENCE FOR THIS SUITE, stated because it matters when reading a green
# run: R2 and R4 assert `last_section`, and with no write left they now read
# back the value the FIXTURE seeded. They are corroboration, not discrimination
# — they cannot fail on this branch. **E1 is what actually proves the fix**: it
# drives the real `--resume` twice and asserts the operator is ASKED the paused
# section again, which is the outcome the defect destroyed.
#
# The R cases drive the REAL save_section, with the sentinel set by the REAL
# prompt_input reading the literal word `pause` from stdin.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WIZARD="$REPO_ROOT/scripts/intake-wizard.sh"

PASSED=0
FAILED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }

TOPTMP="$(mktemp -d)"
trap 'rm -rf "$TOPTMP"' EXIT INT TERM
newtmp() { mktemp -d "$TOPTMP/fixXXXXXX"; }
_changed_lines() { local n; n=$(diff "$1" "$2" 2>/dev/null | grep -c '^[<>]'); case "$n" in ''|*[!0-9]*) n=0 ;; esac; printf '%s\n' "$n"; }

[ -f "$WIZARD" ] || { echo "  [FAIL] setup — $WIZARD not found"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  [FAIL] setup — python3 is required (save_section writes through it)"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }
HAVE_PY3_E1=1

ANS_VALUE='BL266-ANSWER-SAVED-BEFORE-THE-PAUSE'

# mk_project <dir> — a project skeleton whose progress file records
# sections 1-3 done, so `last_section` is 3 when section 4 begins.
mk_project() {
  local d="$1"
  mkdir -p "$d/.claude" || return 1
  cat > "$d/.claude/intake-progress.json" <<PROGRESS
{
  "version": 1,
  "last_section": 3,
  "completed_sections": [1, 2, 3],
  "project_name": "BL266Proj",
  "platform": "web",
  "track": "full",
  "deployment": "personal",
  "language": "typescript",
  "description": "BL266 fixture",
  "poc_mode": null,
  "answers": { "problem_statement": "$ANS_VALUE" }
}
PROGRESS
  printf '# Project Intake\n\n_fixture_\n' > "$d/PROJECT_INTAKE.md"
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$d/.claude/intake-progress.json" || return 1
  return 0
}

# save <project-dir> <section> <paused|clean> [wizard]
#   Drives the real save_section. In `paused` mode the sentinel is set by
#   the real prompt_input reading the word "pause" from stdin — not by a
#   bare `touch` — so the case is anchored to what a keystroke actually does.
save() {
  local d="$1" sect="$2" mode="$3" bin="${4:-$WIZARD}"
  (
    cd "$d" || exit 90
    __SOLO_INTAKE_WIZARD_SOURCED__=1
    # shellcheck disable=SC1090
    source "$bin" >/dev/null 2>&1 || exit 91
    PROGRESS_FILE="$d/.claude/intake-progress.json"
    INTAKE_FILE="$d/PROJECT_INTAKE.md"
    _PAUSE_FILE="$d/.pause-sentinel"
    rm -f "$_PAUSE_FILE"
    if [ "$mode" = "paused" ]; then
      printf 'pause\n' | prompt_input "Must-have feature 1" "" >/dev/null 2>&1
      [ -f "$_PAUSE_FILE" ] || exit 92
    fi
    save_section "$sect"
  ) >"$d/save.out" 2>&1
  SAVE_RC=$?
  return 0
}

jget() { python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d[sys.argv[2]])" "$1" "$2" 2>/dev/null; }

echo "=== R — the real save_section, sentinel set by the real pause keyword ==="

# R0 (CONTROL) — with no pause, save_section still does its job. True on
# main by construction; without it a RED run cannot be told from a fixture
# that never worked.
PD0="$(newtmp)/proj"
if ! mk_project "$PD0"; then
  fail_ "R0 setup" "could not build the fixture project"
else
  save "$PD0" 4 clean
  cs="$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1]))['completed_sections'])" "$PD0/.claude/intake-progress.json" 2>/dev/null)"
  if [ "$SAVE_RC" -eq 0 ] && [ "$cs" = "[1, 2, 3, 4]" ]; then
    pass "R0 (control) — an UNPAUSED save_section 4 files section 4 as complete (rc=$SAVE_RC)"
  else
    fail_ "R0 (control)" "unpaused save_section 4 gave rc=$SAVE_RC, completed_sections=$cs — the fixture, not the defect, is broken"
  fi
fi

PD="$(newtmp)/proj"
if ! mk_project "$PD"; then
  fail_ "R setup" "could not build the fixture project"
else
  save "$PD" 4 paused
  if [ "$SAVE_RC" -eq 92 ]; then
    fail_ "R setup" "the real prompt_input did not set the sentinel on the word 'pause'"
  elif [ "$SAVE_RC" -ne 0 ]; then
    fail_ "R setup" "paused save_section 4 exited $SAVE_RC: $(head -1 "$PD/save.out" 2>/dev/null)"
  else
    # R1 — THE DISCRIMINATOR.
    cs="$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1]))['completed_sections'])" "$PD/.claude/intake-progress.json" 2>/dev/null)"
    if [ "$cs" = "[1, 2, 3]" ]; then
      pass "R1 — a PAUSED section 4 is not added to completed_sections (still $cs)"
    else
      fail_ "R1" "completed_sections is $cs, want [1, 2, 3] — the paused section was filed as finished"
    fi

    # R2 — the resume point: `last_section + 1` must land back on 4.
    got="$(jget "$PD/.claude/intake-progress.json" last_section)"
    if [ "$got" = "3" ]; then
      pass "R2 (corroboration — seeded, cannot fail here; see E1) — last_section is 3, so --resume starts at section 4"
    else
      fail_ "R2" "last_section is [$got], want [3] — --resume would start at $((got + 1))"
    fi

    # R3 — the real reader. is_section_complete is what run_script_mode
    # consults, and it reads COMPLETED_SECTIONS via load_progress.
    verdict="$(
      cd "$PD" || exit 1
      __SOLO_INTAKE_WIZARD_SOURCED__=1
      # shellcheck disable=SC1090
      source "$WIZARD" >/dev/null 2>&1 || exit 1
      PROGRESS_FILE="$PD/.claude/intake-progress.json"
      load_progress >/dev/null 2>&1
      if is_section_complete 4; then echo SKIPPED; else echo ASKED; fi
    )"
    if [ "$verdict" = "ASKED" ]; then
      pass "R3 — is_section_complete 4 is false, so the runner asks section 4 again"
    else
      fail_ "R3" "is_section_complete 4 reports [$verdict] — --resume would skip section 4 permanently"
    fi

    # R6 (CONTROL) — an answer stored BEFORE the pause is untouched. True
    # on main; it pins that the guard refuses the completion record without
    # discarding work.
    got="$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1]))['answers'].get('problem_statement', '<<ABSENT>>'))" "$PD/.claude/intake-progress.json" 2>/dev/null)"
    if [ "$got" = "$ANS_VALUE" ]; then
      pass "R6 (control) — the answer saved before the pause survives the paused save_section"
    else
      fail_ "R6 (control)" "the pre-pause answer is [$got], want [$ANS_VALUE]"
    fi
  fi
fi

# R4 — SECTION 115. `115 - 1` is 114, and every section id is below it.
PD115="$(newtmp)/proj"
if ! mk_project "$PD115"; then
  fail_ "R4 setup" "could not build the fixture project"
else
  python3 -c "
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['last_section'] = 11
d['completed_sections'] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
json.dump(d, open(p, 'w'), indent=2)" "$PD115/.claude/intake-progress.json"
  save "$PD115" 115 paused
  got="$(jget "$PD115/.claude/intake-progress.json" last_section)"
  if [ "$got" = "11" ]; then
    pass "R4 (corroboration — seeded, cannot fail here; see E1) — pausing in section 115 leaves the resume point at 11"
  else
    fail_ "R4" "last_section is [$got], want [11] — --resume would start at $((got + 1)) and skip every section"
  fi
fi

# ── E1: THE OPERATOR-VISIBLE OUTCOME, THROUGH THE REAL `--resume` ───────────
# R2 and R4 assert `last_section`, and since the resume-point write was removed
# they read back the value the FIXTURE seeded — they cannot fail on this branch.
# That is not a reason to keep the write; it is a reason to assert the thing the
# operator actually experiences. This drives the REAL wizard end to end:
#
#   resume #1  -> section 4 is asked, operator types `pause`, wizard exits
#   resume #2  -> section 4 must be ASKED AGAIN, not reported "already complete"
#
# `--resume` is dispatched at intake-wizard.sh:2243, BEFORE the non-TTY refusal
# at :2324, so it drives from a pipe with no stubs and no TTY.
echo "=== E1 — the real --resume, end to end ==="

mk_project_fixture() { mk_project "$@"; }
mk_project() {   # <dir> — a project the wizard will accept, sections 1-3 done
  local d="$1"
  mkdir -p "$d/.claude" "$d/scripts/lib" || return 1
  cp "$WIZARD" "$d/scripts/intake-wizard.sh" || return 1
  # the wizard sources $SCRIPT_DIR/lib/helpers.sh at load time
  cp "$REPO_ROOT"/scripts/lib/helpers*.sh "$d/scripts/lib/" 2>/dev/null || return 1
  printf '{"project":"P","current_phase":0,"track":"full","deployment":"personal","poc_mode":null}\n' \
    > "$d/.claude/phase-state.json"
  cat > "$d/.claude/intake-progress.json" <<PROG
{ "version": 1, "last_section": 3, "completed_sections": [1, 2, 3],
  "project_name": "P", "platform": "web", "track": "full",
  "deployment": "personal", "language": "typescript",
  "description": "f", "poc_mode": null, "answers": {} }
PROG
  printf '# Project Intake\n' > "$d/PROJECT_INTAKE.md"
  return 0
}

E1D="$(newtmp)/proj"
if ! mk_project "$E1D"; then
  fail_ "E1 setup" "could not build the project fixture"
elif [ "$HAVE_PY3_E1" = "0" ]; then
  echo "  [SKIP] E1 — python3 unavailable (the wizard's state writes go through it)"
else
  # resume #1 — pause inside section 4
  ( cd "$E1D" && printf 'pause\n' | bash scripts/intake-wizard.sh --resume ) >"$E1D/r1.out" 2>&1
  e1_completed="$(python3 -c "
import json,sys
print(json.load(open(sys.argv[1]))['completed_sections'])" "$E1D/.claude/intake-progress.json" 2>/dev/null)"
  # resume #2 — section 4 must be ASKED again
  ( cd "$E1D" && printf 'pause\n' | bash scripts/intake-wizard.sh --resume ) >"$E1D/r2.out" 2>&1

  if ! grep -q 'Section 4: Features' "$E1D/r1.out"; then
    fail_ "E1 setup" "resume #1 never reached section 4 — the fixture, not the defect: $(tail -2 "$E1D/r1.out" | tr '\n' ' ')"
  elif [ "$e1_completed" != "[1, 2, 3]" ]; then
    fail_ "E1" "after pausing in section 4 completed_sections is $e1_completed, want [1, 2, 3]"
  elif grep -q 'Section 4 — already complete' "$E1D/r2.out"; then
    fail_ "E1" "resume #2 SKIPPED section 4 as already complete — the paused section is lost to the operator"
  elif ! grep -q 'Section 4: Features' "$E1D/r2.out"; then
    fail_ "E1" "resume #2 did not ask section 4 at all: $(tail -2 "$E1D/r2.out" | tr '\n' ' ')"
  else
    pass "E1 — a section paused on one --resume is ASKED AGAIN on the next, through the real wizard"
  fi
fi

echo "=== M — mutation proof on a mirror ==="

M_MARK="BL-266-PAUSE-INCOMPLETE"
n="$(grep -c "$M_MARK" "$WIZARD" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
[ "$n" = "1" ] \
  && pass "M0 — '$M_MARK' occurs exactly once in intake-wizard.sh" \
  || fail_ "M0" "'$M_MARK' occurs $n times in intake-wizard.sh (need exactly 1)"

# MP1 — delete the whole pause guard on a mirror, restoring main's
# unconditional save. R1 must re-open.
MP1="$(newtmp)/fw"
if ! mkdir -p "$MP1" || ! cp -Rp "$REPO_ROOT/scripts" "$MP1/"; then
  fail_ "MP1 setup" "could not mirror scripts/"
else
  tgt="$MP1/scripts/intake-wizard.sh"; before="$(mktemp)"; cp "$tgt" "$before"
  mark_ln="$(grep -n "$M_MARK" "$before" | head -1 | cut -d: -f1)"
  end_ln="$(awk -v s="$mark_ln" 'NR >= s && $0 == "  fi" { print NR; exit }' "$before")"
  if [ -z "$mark_ln" ] || [ -z "$end_ln" ]; then
    fail_ "MP1 setup" "could not locate the guard block (mark=$mark_ln end=$end_ln)"
  else
    { head -n $((mark_ln - 1)) "$before"; tail -n +$((end_ln + 1)) "$before"; } > "$tgt"
    if ! bash -n "$tgt" 2>/dev/null \
       || [ "$(grep -c "$M_MARK" "$tgt")" -ne 0 ] \
       || [ "$(grep -c '^save_section() {$' "$tgt")" -ne 1 ]; then
      fail_ "MP1 setup" "the guard-removal mutation did not apply cleanly"
    else
      PDM="$(newtmp)/proj"
      if ! mk_project "$PDM"; then
        fail_ "MP1 setup" "could not build the mutant's fixture"
      else
        save "$PDM" 4 paused "$tgt"
        cs="$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1]))['completed_sections'])" "$PDM/.claude/intake-progress.json" 2>/dev/null)"
        if [ "$cs" != "[1, 2, 3]" ]; then
          pass "MP1 (MUTATION) — without the guard a paused section 4 is filed as complete again (completed_sections=$cs): R1 is what stops it"
        else
          fail_ "MP1 (MUTATION)" "removing the guard changed nothing — R1 may be passing for another reason"
        fi
      fi
    fi
  fi
fi

# MP2 — the guard's `return 0`. Under the new shape the guard is three lines
# and the only thing that stops the fall-through is that final `return`; delete
# it and execution continues into the normal write, filing the paused section as
# complete exactly as base does. The previous MP2 mutated the `115` resume-point
# arithmetic, which this rework deleted — a mutant whose target no longer exists
# fails at setup rather than proving anything, so it is replaced rather than kept.
MP2="$(newtmp)/fw"
if ! mkdir -p "$MP2" || ! cp -Rp "$REPO_ROOT/scripts" "$MP2/"; then
  fail_ "MP2 setup" "could not mirror scripts/"
else
  tgt2="$MP2/scripts/intake-wizard.sh"; before2="$(mktemp)"; cp "$tgt2" "$before2"
  # the guard's own `return 0` — the one two lines after render_intake_file
  g_ln="$(grep -n 'Section \$section_num paused before it was finished' "$before2" | head -1 | cut -d: -f1)"
  r_ln=""
  [ -n "$g_ln" ] && r_ln="$(awk -v s="$g_ln" 'NR > s && $0 == "    return 0" { print NR; exit }' "$before2")"
  if [ -z "$g_ln" ] || [ -z "$r_ln" ]; then
    fail_ "MP2 setup" "could not locate the guard's return (msg=$g_ln return=$r_ln)"
  else
    { head -n $((r_ln - 1)) "$before2"; tail -n +$((r_ln + 1)) "$before2"; } > "$tgt2"
    if ! bash -n "$tgt2" 2>/dev/null \
       || [ "$(_changed_lines "$before2" "$tgt2")" -ne 1 ]; then
      fail_ "MP2 setup" "the return-removal mutation did not apply cleanly"
    else
      PDM2="$(newtmp)/proj"
      if ! mk_project_fixture "$PDM2"; then
        fail_ "MP2 setup" "could not build the mutant's fixture"
      else
        save "$PDM2" 4 paused "$tgt2"
        cs="$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1]))['completed_sections'])" "$PDM2/.claude/intake-progress.json" 2>/dev/null)"
        if [ "$cs" != "[1, 2, 3]" ]; then
          pass "MP2 (MUTATION) — without the guard's \`return 0\` a paused section falls through and is filed as complete (completed_sections=$cs): R1 is what stops it"
        else
          fail_ "MP2 (MUTATION)" "removing the return changed nothing (completed_sections=$cs)"
        fi
      fi
    fi
  fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] && exit 0
exit 1
