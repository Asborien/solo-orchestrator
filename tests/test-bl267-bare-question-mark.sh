#!/usr/bin/env bash
# tests/test-bl267-bare-question-mark.sh
#
# `## BL-267:` — A BARE `?` WAS SAVED AS THE ANSWER.
#
# The wizard's banner tells the operator "Type '?' at prompts marked with
# [? for suggestions] to see options." `prompt_with_suggestions` honours
# that: it loops on `?`, shows the suggestion set, and asks again.
# `prompt_input` — the helper behind 81 of the wizard's prompts — had NO
# handling for it, so a `?` fell through to `echo "$result"` and was
# recorded verbatim by the `save_answer` on the next line, then carried
# into PROJECT_INTAKE.md. Observed on `one_time_budget` and `users_12mo`.
#
# The fix's own hazard is the second half of this suite. `prompt_input`
# returns the answer on STDOUT — every call site is `x=$(prompt_input …)`
# — so ANY notice it prints without `>&2` is CAPTURED AS PART OF THE
# ANSWER. Measured from the current mutant, a `?` followed by `42` yields
# `  No suggestions available for this field — answer it directly, or type
# N/A.\n42`. C2 is the case for that, and it also asserts the notice REACHES stderr, which nothing else checks; MP2 is the mutant that proves it is
# load-bearing. (The re-ask notice is a bare `echo … >&2`, matching the
# sibling helpers; an earlier draft used `print_info`, which writes to
# stdout — hence the hazard being worth a case at all.)
#
# This drives the REAL prompt_input with stdin, and the real save_answer,
# against a hermetic progress file.
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
# prompt_input's body only — prompt_with_suggestions carries an identical `?`
# arm, so any assertion about "the arm" must say WHICH function's.
_prompt_input_body() { awk '/^prompt_input\(\) \{$/ { f = 1 } f { print } f && /^\}$/ { exit }' "$1"; }

[ -f "$WIZARD" ] || { echo "  [FAIL] setup — $WIZARD not found"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }
# python3 is needed ONLY by save_answer, i.e. only by case S1. Skip that case
# rather than failing the suite, matching tests/test-intake-wizard-fixes.sh's
# `[SKIP] T4 — python3 unavailable`. The C-cases drive prompt_input directly
# and need nothing but bash.
HAVE_PY3=1
command -v python3 >/dev/null 2>&1 || HAVE_PY3=0

# ask <keystrokes> <prompt> <default> [wizard] → ASK_OUT (captured stdout)
# Drives the REAL prompt_input exactly as a call site does: command
# substitution over stdout, with stderr discarded the way a terminal
# would consume it.
ask() {
  local keys="$1" prompt="$2" default="$3" bin="${4:-$WIZARD}"
  local d; d="$(newtmp)"
  # stderr is CAPTURED, not discarded: C2 asserts the re-ask notice actually
  # REACHES the operator, which no other case checks. Discarding it here is
  # what made C2 subsumed by C1 — both could then only see stdout.
  ASK_ERR_FILE="$d/.ask-stderr"
  ASK_OUT="$(
    cd "$d" || exit 90
    __SOLO_INTAKE_WIZARD_SOURCED__=1
    # shellcheck disable=SC1090
    source "$bin" >/dev/null 2>&1 || exit 91
    _PAUSE_FILE="$d/.pause-sentinel"
    printf '%b' "$keys" | prompt_input "$prompt" "$default" 2>"$ASK_ERR_FILE"
  )"
  ASK_RC=$?
  ASK_ERR="$(cat "$ASK_ERR_FILE" 2>/dev/null || printf '')"
  return 0
}

# save_through <keystrokes> — the full path an operator walks: the real
# prompt_input feeding the real save_answer, then read back off disk.
save_through() {
  local keys="$1" bin="${2:-$WIZARD}"
  local d; d="$(newtmp)"
  mkdir -p "$d/.claude"
  cat > "$d/.claude/intake-progress.json" <<'PROGRESS'
{ "version": 1, "last_section": 4, "completed_sections": [1, 2, 3, 4],
  "project_name": "BL267Proj", "platform": "web", "track": "full",
  "deployment": "personal", "language": "typescript",
  "description": "BL267 fixture", "poc_mode": null, "answers": {} }
PROGRESS
  (
    cd "$d" || exit 90
    __SOLO_INTAKE_WIZARD_SOURCED__=1
    # shellcheck disable=SC1090
    source "$bin" >/dev/null 2>&1 || exit 91
    PROGRESS_FILE="$d/.claude/intake-progress.json"
    _PAUSE_FILE="$d/.pause-sentinel"
    local v
    v=$(printf '%b' "$keys" | prompt_input "Expected users at 12 months" "" 2>/dev/null)
    save_answer "users_12mo" "$v"
  ) >/dev/null 2>&1
  SAVED="$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1]))['answers'].get('users_12mo', '<<ABSENT>>'))" "$d/.claude/intake-progress.json" 2>/dev/null)"
  return 0
}

echo "=== C — the real prompt_input ==="

# C0 (CONTROL) — an ordinary answer round-trips. True on main by
# construction; without it a RED run could be a broken fixture.
ask '42\n' "Expected users at 12 months" ""
if [ "$ASK_OUT" = "42" ]; then
  pass "C0 (control) — an ordinary answer is returned verbatim ([$ASK_OUT])"
else
  fail_ "C0 (control)" "an ordinary answer came back as [$ASK_OUT], want [42] — the fixture, not the defect, is broken"
fi

# C1 — THE DISCRIMINATOR. `?` must not be the answer; the next line is.
ask '?\n42\n' "Expected users at 12 months" ""
if [ "$ASK_OUT" = "42" ]; then
  pass "C1 — a bare \`?\` re-asks, and the NEXT line is the answer ([$ASK_OUT])"
else
  fail_ "C1" "prompt_input returned [$ASK_OUT], want [42] — a question mark was taken as the answer"
fi

# C2 — the notice must REACH THE OPERATOR, on stderr, and must not ride along
# on stdout. Both halves matter and neither is covered elsewhere: C1 pins the
# returned value, so a silent re-ask that emitted NO notice at all would leave
# C1 green while the operator saw nothing explaining why the prompt repeated.
# Asserting only "stdout is clean" made this case strictly subsumed by C1 —
# same input, and no value matching the old glob could ever equal "42".
ask '?\n42\n' "Expected users at 12 months" ""
if ! printf '%s' "$ASK_ERR" | grep -qi 'suggestion'; then
  fail_ "C2" "no re-ask notice reached stderr — the prompt repeated with no explanation to the operator (stderr: [$ASK_ERR])"
else
  case "$ASK_OUT" in
    *suggestion*|*Suggestion*|*INFO*)
      fail_ "C2" "the re-ask notice was captured into the answer: [$ASK_OUT]" ;;
    *)
      pass "C2 — the notice reaches the operator on stderr and stays out of the captured answer" ;;
  esac
fi

# C3 — the same with a DEFAULT in play (the one_time_budget shape,
# `prompt_input "One-time budget (or N/A)" "N/A"`). The default must
# survive the re-ask.
ask '?\n\n' "One-time budget (or N/A)" "N/A"
if [ "$ASK_OUT" = "N/A" ]; then
  pass "C3 — with a default set, a \`?\` then Enter still yields the default ([$ASK_OUT])"
else
  fail_ "C3" "returned [$ASK_OUT], want [N/A] — the default did not survive the re-ask"
fi

# C4 (CONTROL) — a `?` EMBEDDED in a real answer is not the help key and
# must be left alone. True on main; it pins that the fix tests for the
# bare token, not for the character.
ask 'why? about 42\n' "Expected users at 12 months" ""
if [ "$ASK_OUT" = "why? about 42" ]; then
  pass "C4 (control) — an answer that merely CONTAINS '?' is untouched ([$ASK_OUT])"
else
  fail_ "C4 (control)" "returned [$ASK_OUT], want [why? about 42]"
fi

echo "=== S — end to end, through the real save_answer ==="

if [ "$HAVE_PY3" -eq 0 ]; then
  echo "  [SKIP] S1 — python3 unavailable (save_answer writes through it)"
else
  save_through '?\n42\n'
  if [ "$SAVED" = "42" ]; then
    pass "S1 — users_12mo lands on disk as [42], not as a question mark"
  else
    fail_ "S1" "users_12mo was saved as [$SAVED], want [42]"
  fi
fi

echo "=== M — mutation proof on a mirror ==="

M_MARK="BL-267-BARE-QUESTION-MARK"
n="$(grep -c "$M_MARK" "$WIZARD" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
[ "$n" = "1" ] \
  && pass "M0 — '$M_MARK' occurs exactly once in intake-wizard.sh" \
  || fail_ "M0" "'$M_MARK' occurs $n times in intake-wizard.sh (need exactly 1)"

# MP1 — delete the `?` arm on a mirror, restoring main. C1 and S1 must
# re-open, while C0 and C4 stay green.
MP1="$(newtmp)/fw"
if ! mkdir -p "$MP1" || ! cp -Rp "$REPO_ROOT/scripts" "$MP1/"; then
  fail_ "MP1 setup" "could not mirror scripts/"
else
  tgt="$MP1/scripts/intake-wizard.sh"; before="$(mktemp)"; cp "$tgt" "$before"
  # the arm sits INSIDE prompt_input's `while true` loop, so both the opener
  # and its closing `fi` carry four spaces, not two.
  arm_ln="$(grep -n '^    if \[ "\$result" = "?" \]; then$' "$before" | head -1 | cut -d: -f1)"
  end_ln="$(awk -v s="$arm_ln" 'NR > s && $0 == "    fi" { print NR; exit }' "$before")"
  if [ -z "$arm_ln" ] || [ -z "$end_ln" ]; then
    fail_ "MP1 setup" "could not locate the ? arm (arm=$arm_ln end=$end_ln)"
  else
    { head -n $((arm_ln - 1)) "$before"; tail -n +$((end_ln + 1)) "$before"; } > "$tgt"
    # Scope the "it is gone" check to prompt_input's OWN body. Since the
    # conversion to the loop idiom, prompt_with_suggestions carries a
    # BYTE-IDENTICAL `?` arm at the same indent, so a whole-file count of 0
    # can never be reached and an unscoped assertion fails on a mutation that
    # applied perfectly.
    if ! bash -n "$tgt" 2>/dev/null \
       || [ "$(_prompt_input_body "$tgt" | grep -c 'if \[ "\$result" = "?" \]; then')" -ne 0 ] \
       || [ "$(_prompt_input_body "$before" | grep -c 'if \[ "\$result" = "?" \]; then')" -ne 1 ] \
       || [ "$(grep -c '^prompt_input() {$' "$tgt")" -ne 1 ]; then
      fail_ "MP1 setup" "the ?-arm removal did not apply cleanly"
    else
      ask '?\n42\n' "Expected users at 12 months" "" "$tgt"
      mut_out="$ASK_OUT"
      ask '42\n' "Expected users at 12 months" "" "$tgt"
      save_through '?\n42\n' "$tgt"
      if [ "$mut_out" = "?" ] && [ "$ASK_OUT" = "42" ] \
         && { [ "$HAVE_PY3" -eq 0 ] || [ "$SAVED" = "?" ]; }; then
        if [ "$HAVE_PY3" -eq 0 ]; then
          pass "MP1 (MUTATION) — without the arm a bare \`?\` is returned ([$mut_out]) while ordinary answers still work; disk half SKIPPED (no python3): C1 is what stops it"
        else
          pass "MP1 (MUTATION) — without the arm a bare \`?\` is returned ([$mut_out]) and SAVED ([$SAVED]) while ordinary answers still work: C1/S1 are what stop it"
        fi
      else
        fail_ "MP1 (MUTATION)" "removing the arm changed nothing (returned=[$mut_out] ordinary=[$ASK_OUT] saved=[$SAVED])"
      fi
    fi
  fi
fi

# MP2 — drop the `>&2` on the notice. The `?` is still swallowed and C1's
# "is the answer 42" reading is the only thing that would not notice; C2
# is the case that does.
MP2="$(newtmp)/fw"
if ! mkdir -p "$MP2" || ! cp -Rp "$REPO_ROOT/scripts" "$MP2/"; then
  fail_ "MP2 setup" "could not mirror scripts/"
else
  tgt2="$MP2/scripts/intake-wizard.sh"; before2="$(mktemp)"; cp "$tgt2" "$before2"
  if [ "$(grep -c 'answer it directly, or type N/A." >&2$' "$before2")" -ne 1 ]; then
    fail_ "MP2 setup" "the redirected notice is not a unique single line"
  else
    sed -e 's/answer it directly, or type N\/A\." >&2$/answer it directly, or type N\/A."/' "$before2" > "$tgt2"
    if ! bash -n "$tgt2" 2>/dev/null \
       || [ "$(grep -c 'answer it directly, or type N/A." >&2$' "$tgt2")" -ne 0 ] \
       || [ "$(_changed_lines "$before2" "$tgt2")" -ne 2 ]; then
      fail_ "MP2 setup" "the stderr-redirect mutation did not apply cleanly"
    else
      ask '?\n42\n' "Expected users at 12 months" "" "$tgt2"
      save_through '?\n42\n' "$tgt2"
      case "$ASK_OUT" in
        *"No suggestions available"*)
          if [ "$HAVE_PY3" -eq 0 ] || [ "$SAVED" != "42" ]; then
            if [ "$HAVE_PY3" -eq 0 ]; then
              pass "MP2 (MUTATION) — an unredirected notice is captured into the answer ([$(printf '%s' "$ASK_OUT" | head -1)…]); disk half SKIPPED (no python3): C2 is what stops it"
            else
              pass "MP2 (MUTATION) — an unredirected notice is captured into the answer and SAVED as [$(printf '%s' "$SAVED" | head -1)…]: C2 is what stops it"
            fi
          else
            fail_ "MP2 (MUTATION)" "the notice reached stdout but the saved answer was still [$SAVED]"
          fi ;;
        *)
          fail_ "MP2 (MUTATION)" "dropping >&2 changed nothing (returned=[$ASK_OUT]) — C2 may be passing for another reason" ;;
      esac
    fi
  fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] && exit 0
exit 1
