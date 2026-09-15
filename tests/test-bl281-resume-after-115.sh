#!/usr/bin/env bash
# tests/test-bl281-resume-after-115.sh
#
# `## BL-281:` — `--resume` AFTER A CLEAN FINISH OF SECTION 11.5 RAN NOTHING,
# PRINTED "Intake Complete!", AND NEVER RAN SECTIONS 12 AND 13.
#
# The runner's order is `1 2 3 4 5 6 7 8 9 10 11 115 12 13` — 115 encodes
# Section 11.5 as an integer so it can pass through save_section and
# is_section_complete, which makes the list non-monotonic. --resume computed
# its start point as `LAST_SECTION + 1` and run_script_mode skipped with
# `[ "$section" -lt "$start_section" ]`. After `save_section 115` that start
# point is 116, every id in the list is below it, and the loop ran nothing:
# no Section 12, no Section 13 (the Agent Initialization Prompt), then the
# completion banner at exit 0.
#
# The fix (`# BL-281-SECTION-ORDER`, `# BL-281-NEXT-SECTION`,
# `# BL-281-POSITION-SKIP`, `# BL-281-RESUME-POINT`) keeps the order in ONE
# list, derives the resume point as the element AFTER the last completed one
# by position, and skips by position rather than by value.
#
# Every fixture drives the REAL wizard through `--resume` from a pipe:
# --resume is dispatched before the non-TTY refusal, so no stubs are needed.
# `## BL-266:` (PR #390) guards the PAUSE path only and does not reach this;
# these fixtures never pause inside 11.5 — the section is recorded as
# cleanly complete, which is the case that branch leaves open.
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
_syntax_ok() { bash "-n" "$1" 2>/dev/null; }
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g' "$1"; }

[ -f "$WIZARD" ] || { echo "  [FAIL] setup — $WIZARD not found"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  [FAIL] setup — python3 is required (the wizard's state writes go through it)"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }

# mk_project <dir> <last_section> <completed-json-array> [wizard-file]
#   A project the wizard accepts, with a COPY of the wizard and its helpers
#   so nothing here touches the checkout. The progress file is the only
#   thing that varies between cases.
mk_project() {
  local d="$1" last="$2" done_="$3" bin="${4:-$WIZARD}"
  mkdir -p "$d/.claude" "$d/scripts/lib" || return 1
  cp "$bin" "$d/scripts/intake-wizard.sh" || return 1
  cp "$REPO_ROOT"/scripts/lib/helpers*.sh "$d/scripts/lib/" 2>/dev/null || return 1
  printf '{"project":"P","current_phase":0,"track":"full","deployment":"personal","poc_mode":null}\n' \
    > "$d/.claude/phase-state.json"
  cat > "$d/.claude/intake-progress.json" <<PROG
{ "version": 1, "last_section": $last, "completed_sections": $done_,
  "project_name": "P", "platform": "web", "track": "full",
  "deployment": "personal", "language": "typescript",
  "description": "f", "poc_mode": null, "answers": {} }
PROG
  printf '# Project Intake\n' > "$d/PROJECT_INTAKE.md"
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$d/.claude/intake-progress.json" || return 1
  return 0
}

# resume <dir> <stdin-text>  — the real `--resume`, driven from a pipe.
resume() {
  local d="$1" input="$2"
  ( cd "$d" && printf '%s' "$input" | SOIF_NONINTERACTIVE=1 bash scripts/intake-wizard.sh --resume ) >"$d/run.raw" 2>&1
  RESUME_RC=$?
  strip_ansi "$d/run.raw" > "$d/run.out"
  return 0
}

jget() { python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d[sys.argv[2]])" "$1" "$2" 2>/dev/null; }

ALL_BUT_12_13='[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 115]'

echo "=== C — controls that hold at base (the fixture works, the resume point works for ordinary ids) ==="

# C1 — resume from an ordinary id lands on the next section.
C1="$(newtmp)/proj"
if ! mk_project "$C1" 3 '[1, 2, 3]'; then
  fail_ "C1 setup" "could not build the fixture"
else
  resume "$C1" $'pause\n'
  if grep -q 'Section 4: Features' "$C1/run.out"; then
    pass "C1 (control) — last_section 3 resumes at Section 4"
  else
    fail_ "C1 (control)" "resume from 3 did not reach Section 4: $(tail -2 "$C1/run.out" | tr '\n' ' ')"
  fi
fi

# C2 — resume from 11 reaches 11.5 (115 is never below 12, so base passes).
C2="$(newtmp)/proj"
if ! mk_project "$C2" 11 '[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]'; then
  fail_ "C2 setup" "could not build the fixture"
else
  resume "$C2" $'pause\n'
  if grep -q 'Section 11.5: Testing' "$C2/run.out"; then
    pass "C2 (control) — last_section 11 resumes at Section 11.5"
  else
    fail_ "C2 (control)" "resume from 11 did not reach Section 11.5: $(tail -2 "$C2/run.out" | tr '\n' ' ')"
  fi
fi

# C3 — everything complete: nothing runs, the banner prints, exit 0, and
# no arithmetic error leaks (the start point is now a possibly-empty id).
C3="$(newtmp)/proj"
if ! mk_project "$C3" 13 '[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 115]'; then
  fail_ "C3 setup" "could not build the fixture"
else
  resume "$C3" ''
  if [ "$RESUME_RC" -eq 0 ] && grep -q 'Intake Complete!' "$C3/run.out" \
     && ! grep -q '\[STEP\] Section' "$C3/run.out" \
     && ! grep -q 'integer expression expected' "$C3/run.out"; then
    pass "C3 (control) — a fully complete intake resumes to the banner with nothing re-run (rc=$RESUME_RC)"
  else
    fail_ "C3 (control)" "rc=$RESUME_RC; $(grep -c '\[STEP\] Section' "$C3/run.out") sections re-run; $(grep -c 'integer expression' "$C3/run.out") arithmetic errors"
  fi
fi

echo "=== R — the defect: --resume after a clean finish of Section 11.5 ==="

RD="$(newtmp)/proj"
if ! mk_project "$RD" 115 "$ALL_BUT_12_13"; then
  fail_ "R setup" "could not build the fixture"
else
  resume "$RD" ''

  # R1 — Section 12 runs.
  if grep -q 'Section 12: Tooling Configuration' "$RD/run.out"; then
    pass "R1 — after a clean Section 11.5, --resume runs Section 12"
  else
    fail_ "R1" "Section 12 never ran: $(grep -m1 'Resuming from' "$RD/run.out")"
  fi

  # R2 — Section 13 (the Agent Initialization Prompt) runs.
  if grep -q 'Section 13: Agent Initialization Prompt' "$RD/run.out"; then
    pass "R2 — after a clean Section 11.5, --resume runs Section 13 (Agent Initialization Prompt)"
  else
    fail_ "R2" "Section 13 never ran — the intake ends without its initialization prompt"
  fi

  # R3 — the record: 12 and 13 filed, last_section 13.
  cs="$(jget "$RD/.claude/intake-progress.json" completed_sections)"
  ls_="$(jget "$RD/.claude/intake-progress.json" last_section)"
  if [ "$cs" = "[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 115]" ] && [ "$ls_" = "13" ]; then
    pass "R3 — completed_sections gains 12 and 13 and last_section is 13"
  else
    fail_ "R3" "completed_sections=$cs last_section=$ls_ — want 12 and 13 filed and last_section 13"
  fi

  # R4 — the resume point is a section id, not arithmetic on one.
  if grep -q 'Resuming from Section 12' "$RD/run.out" && ! grep -q 'Resuming from Section 116' "$RD/run.out"; then
    pass "R4 — the transcript says 'Resuming from Section 12', not 116"
  else
    fail_ "R4" "resume point line: $(grep -m1 'Resuming from' "$RD/run.out" || echo '<none>')"
  fi

  # R5 — the finish is still reached, AFTER 12 and 13, at exit 0.
  if [ "$RESUME_RC" -eq 0 ] && grep -q 'Intake Complete!' "$RD/run.out" \
     && [ "$(grep -n 'Intake Complete!' "$RD/run.out" | head -1 | cut -d: -f1)" -gt "$(grep -n 'Section 13: Agent' "$RD/run.out" | head -1 | cut -d: -f1 || echo 999999)" ]; then
    pass "R5 — 'Intake Complete!' still prints, after Section 13, at rc=$RESUME_RC"
  else
    fail_ "R5" "rc=$RESUME_RC; banner/section-13 ordering wrong or banner missing"
  fi
fi

echo "=== U — next_section_after walks the runner's list by position ==="

u_next() {   # <last> [wizard-file] — echoes next_section_after's answer, or <<MISSING>>
  local last="$1" bin="${2:-$WIZARD}"
  (
    __SOLO_INTAKE_WIZARD_SOURCED__=1
    # shellcheck disable=SC1090
    source "$bin" >/dev/null 2>&1 || exit 91
    command -v next_section_after >/dev/null 2>&1 || { echo '<<MISSING>>'; exit 0; }
    printf '[%s]\n' "$(next_section_after "$last")"
  ) 2>/dev/null
}

for pair in "0:[1]" "4:[5]" "11:[115]" "115:[12]" "12:[13]" "13:[]"; do
  last="${pair%%:*}"; want="${pair#*:}"
  got="$(u_next "$last")"
  if [ "$got" = "$want" ]; then
    pass "U — next_section_after $last = $want"
  else
    fail_ "U — next_section_after $last" "got $got, want $want"
  fi
done

echo "=== M — mutation proofs on a mirror ==="

for mark in BL-281-NEXT-SECTION BL-281-POSITION-SKIP BL-281-RESUME-POINT; do
  n="$(grep -c "$mark" "$WIZARD" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" = "1" ] \
    && pass "M0 — '$mark' occurs exactly once in intake-wizard.sh" \
    || fail_ "M0" "'$mark' occurs $n times in intake-wizard.sh (need exactly 1)"
done

# MP1 — THE PLAUSIBLE WRONG FIX: keep the position skip but derive the resume
# point as `last + 1` again. For 115 that is 116, no element matches it, and
# the runner runs nothing — exactly base's behaviour by a different route.
MP1="$(newtmp)/fw"
if ! mkdir -p "$MP1" || ! cp -Rp "$REPO_ROOT/scripts" "$MP1/"; then
  fail_ "MP1 setup" "could not mirror scripts/"
else
  tgt="$MP1/scripts/intake-wizard.sh"; before="$(mktemp)"; cp "$tgt" "$before"
  m_ln="$(grep -n 'BL-281-NEXT-SECTION' "$before" | head -1 | cut -d: -f1)"
  s_ln=""
  [ -n "$m_ln" ] && s_ln="$(awk -v s="$m_ln" 'NR > s && /INTAKE_SECTION_ORDER\[\$\(\(i \+ 1\)\)\]/ { print NR; exit }' "$before")"
  if [ -z "$m_ln" ] || [ -z "$s_ln" ]; then
    fail_ "MP1 setup" "could not locate the successor line (marker=$m_ln successor=$s_ln)"
  else
    { head -n $((s_ln - 1)) "$before"; printf '        echo "$((last + 1))"\n'; tail -n +$((s_ln + 1)) "$before"; } > "$tgt"
    if ! _syntax_ok "$tgt" \
       || [ "$(_changed_lines "$before" "$tgt")" -ne 2 ] \
       || ! grep -q 'echo "$((last + 1))"' "$tgt"; then
      fail_ "MP1 setup" "the last+1 mutation did not land (changed=$(_changed_lines "$before" "$tgt"))"
    else
      got="$(u_next 115 "$tgt")"
      PDM="$(newtmp)/proj"
      if ! mk_project "$PDM" 115 "$ALL_BUT_12_13" "$tgt"; then
        fail_ "MP1 setup" "could not build the mutant's fixture"
      else
        resume "$PDM" ''
        if [ "$got" = "[116]" ] && ! grep -q 'Section 12: Tooling Configuration' "$PDM/run.out"; then
          pass "MP1 (MUTATION) — with the resume point back to last+1 (=$got) Section 12 never runs again: R1 is what stops it"
        else
          fail_ "MP1 (MUTATION)" "next=$got and Section 12 $(grep -q 'Section 12: Tooling' "$PDM/run.out" && echo ran || echo 'did not run') — the mutation changed nothing R1 can see"
        fi
      fi
    fi
  fi
fi

# MP2 — delete `reached=1`: the start section still runs (it matches), but
# every later section is skipped as "not the start". Section 13 disappears.
MP2="$(newtmp)/fw"
if ! mkdir -p "$MP2" || ! cp -Rp "$REPO_ROOT/scripts" "$MP2/"; then
  fail_ "MP2 setup" "could not mirror scripts/"
else
  tgt2="$MP2/scripts/intake-wizard.sh"; before2="$(mktemp)"; cp "$tgt2" "$before2"
  p_ln="$(grep -n 'BL-281-POSITION-SKIP' "$before2" | head -1 | cut -d: -f1)"
  r_ln=""
  [ -n "$p_ln" ] && r_ln="$(awk -v s="$p_ln" 'NR > s && $0 == "      reached=1" { print NR; exit }' "$before2")"
  if [ -z "$p_ln" ] || [ -z "$r_ln" ]; then
    fail_ "MP2 setup" "could not locate reached=1 (marker=$p_ln line=$r_ln)"
  else
    { head -n $((r_ln - 1)) "$before2"; tail -n +$((r_ln + 1)) "$before2"; } > "$tgt2"
    if ! _syntax_ok "$tgt2" \
       || [ "$(_changed_lines "$before2" "$tgt2")" -ne 1 ] \
       || [ "$(grep -c '^      reached=1$' "$tgt2")" -ne 0 ]; then
      fail_ "MP2 setup" "the reached=1 deletion did not land"
    else
      PDM2="$(newtmp)/proj"
      if ! mk_project "$PDM2" 115 "$ALL_BUT_12_13" "$tgt2"; then
        fail_ "MP2 setup" "could not build the mutant's fixture"
      else
        resume "$PDM2" ''
        if grep -q 'Section 12: Tooling Configuration' "$PDM2/run.out" && ! grep -q 'Section 13: Agent' "$PDM2/run.out"; then
          pass "MP2 (MUTATION) — without reached=1 Section 12 runs but Section 13 is skipped: R2 is what stops it"
        else
          fail_ "MP2 (MUTATION)" "deleting reached=1 changed nothing R2 can see"
        fi
      fi
    fi
  fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] && exit 0
exit 1
