#!/usr/bin/env bash
# tests/test-bl274-single-authority-attestation.sh
#
# BL-274: an organizational deployment with ONE technical authority can never
# clear the self-approval control, because the Approver and the row's author
# are the same person at every gate. The framework's answer to "this control
# cannot apply here" is an attestation, and there are nine of them
# (`SOLO_*_ATTESTED`) plus the `zdr_attested` field.
#
# WHAT THIS SUITE PINS, AND WHY EACH CASE EXISTS.
#
# The danger in this change is not that it fails to work. It is that it works
# by LYING — turning a red gate green while the blocking pre-condition behind
# it (docs/governance-framework.md §XIV item 5, "Second technologist with
# repository and hosting access") stays unmet and unmentioned. That is
# `## BL-256:`'s failure mode — a receipt for a check that never happened —
# applied to governance instead of to tooling.
#
# So the cases split in two. A2/A5/A6/A7/A8/A9 pin that the ESCAPE works and
# is recorded. A3/A4/A10/A12 pin that it never CLAIMS anything: the output
# names the unmet pre-condition every time it fires, never says the control was
# verified, and cannot be made to print a forged `[OK]` by an operator-supplied
# reason. A1 and A11 are the controls — they pass on unmodified main and must
# keep passing, or the change has altered behaviour it was not meant to touch.
# A1 earned its place immediately: the first implementation called the handler
# bare under this script's `set -e`, so the ordinary no-attestation return of 2
# aborted the whole run and printed nothing at all.
#
# Runs on bash 3.2.57 (macOS) and 5.x. No associative arrays, no `mapfile`,
# no process substitution.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check-phase-gate.sh"

PASSED=0
FAILED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }

have_jq=1
command -v jq >/dev/null 2>&1 || have_jq=0

# ── fixture ───────────────────────────────────────────────────────────
# Shape borrowed from tests/test-check-phase-gate-self-approval.sh so both
# suites observe the same gate through the same door.
setup() {
  TMP=$(mktemp -d)
  PROJ="$TMP/p"
  mkdir -p "$PROJ/.claude"
  ( cd "$PROJ" && git init -q && git config user.email "ambient@example.com" \
      && git config user.name "Solo Operator" && git config commit.gpgsign false )
}
teardown() { rm -rf "$TMP"; }

write_log_with_approver() {
  cat > "$PROJ/APPROVAL_LOG.md" <<MD
# APPROVAL_LOG

## Phase Gate: Phase 0 → Phase 1
| Field | Value |
|---|---|
| **Gate** | Phase 0 → Phase 1 |
| **Approver** | $1 |
| **Date** | 2026-02-01 |
MD
}

write_phase_state() {
  cat > "$PROJ/.claude/phase-state.json" <<JSON
{"current_phase":1,"deployment":"$1","gates":{"phase_0_to_1":"2026-02-01"}}
JSON
}

# Record the approval row authored by a named identity. The SINGLE-AUTHORITY
# case is author == approver, which is the condition the control fires on.
record_log_as() {
  ( cd "$PROJ" \
      && git add APPROVAL_LOG.md .claude/phase-state.json 2>/dev/null \
      && GIT_AUTHOR_NAME="$1" GIT_AUTHOR_EMAIL="$2" \
         GIT_COMMITTER_NAME="$1" GIT_COMMITTER_EMAIL="$2" \
         git commit -qm "approval row" )
}

# Add an unrelated commit so HEAD moves without touching the approval row.
advance_head() {
  ( cd "$PROJ" && echo "$RANDOM" > filler.txt && git add filler.txt \
      && git commit -qm "unrelated work" )
}

run_gate() { ( cd "$PROJ" && bash "$SCRIPT" 2>&1 ) || true; }

state_field() {
  [ "$have_jq" -eq 1 ] || { printf ''; return; }
  jq -r "$1 // \"\"" "$PROJ/.claude/process-state.json" 2>/dev/null || printf ''
}

# A single-authority project: the one technologist is both approver and author.
SOLO_NAME="Martin Dean"
SOLO_MAIL="martin@example.test"
REASON="SI Ltd has one technical director; he is both Senior Technical Authority and Orchestrator."

# ── A1 — CONTROL. Passes on unmodified main and must keep passing. ────
# With no attestation set, the self-approval FAIL still fires. If this case
# ever goes quiet, the change has disarmed the control rather than attested
# past it, and every other case in this file is measuring nothing.
echo "A1: no attestation → the self-approval FAIL still fires (control)"
setup; write_phase_state organizational; write_log_with_approver "$SOLO_NAME"
record_log_as "$SOLO_NAME" "$SOLO_MAIL"
out=$(run_gate)
if echo "$out" | grep -qE "\[FAIL\].*self-approval detected"; then
  pass "A1 (control: the unattested self-approval FAIL is intact)"
else
  fail_ A1 "the self-approval FAIL did not fire without an attestation — the control is disarmed, not attested. Output:
$(echo "$out" | grep -iE 'approver|self-approval|ATTESTED' | head -5)"
fi
teardown

# ── A2 — the escape works ────────────────────────────────────────────
echo "A2: attested + reason → no self-approval FAIL, and an [ATTESTED] line instead"
setup; write_phase_state organizational; write_log_with_approver "$SOLO_NAME"
record_log_as "$SOLO_NAME" "$SOLO_MAIL"
out=$( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
       SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="$REASON" bash "$SCRIPT" 2>&1 || true )
a2_ok=1
if echo "$out" | grep -qE "\[FAIL\].*self-approval detected"; then
  fail_ A2 "the self-approval FAIL still fired despite a valid attestation"; a2_ok=0
fi
if ! echo "$out" | grep -q "ATTESTED"; then
  fail_ A2 "no ATTESTED line in the transcript: $(echo "$out" | grep -iE 'approver|attest' | head -3)"; a2_ok=0
fi
[ "$a2_ok" -eq 1 ] && pass "A2 (attested: the block is lifted and announced)"
teardown

# ── A3 — THE CASE THAT MAKES THIS HONEST ─────────────────────────────
# The output must name the pre-condition that is actually unmet. Without this
# the attestation records "one technical authority" against the self-approval
# control while §XIV item 5 stays unmet and unmentioned, which launders a
# blocking pre-condition into a green gate line.
echo "A3: the ATTESTED line names governance-framework §XIV item 5 and cites BL-274"
setup; write_phase_state organizational; write_log_with_approver "$SOLO_NAME"
record_log_as "$SOLO_NAME" "$SOLO_MAIL"
out=$( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
       SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="$REASON" bash "$SCRIPT" 2>&1 || true )
a3_ok=1
echo "$out" | grep -q "XIV" || { fail_ A3 "output never names §XIV — the unmet pre-condition is unmentioned"; a3_ok=0; }
echo "$out" | grep -qi "second technologist" || { fail_ A3 "output does not name the unmet pre-condition in words"; a3_ok=0; }
echo "$out" | grep -q "BL-274" || { fail_ A3 "output does not cite BL-274"; a3_ok=0; }
[ "$a3_ok" -eq 1 ] && pass "A3 (the unmet pre-condition is named every time the escape fires)"
teardown

# ── A4 — it must never claim the control was satisfied ────────────────
echo "A4: the ATTESTED line says NOT verified, and never claims the control passed"
setup; write_phase_state organizational; write_log_with_approver "$SOLO_NAME"
record_log_as "$SOLO_NAME" "$SOLO_MAIL"
out=$( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
       SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="$REASON" bash "$SCRIPT" 2>&1 || true )
att_line=$(echo "$out" | grep "ATTESTED" | head -1)
a4_ok=1
[ -n "$att_line" ] || { fail_ A4 "no ATTESTED line to inspect"; a4_ok=0; }
if [ -n "$att_line" ]; then
  # An explicit negation must be present …
  echo "$att_line" | grep -qiE "NOT applied|not performed" \
    || { fail_ A4 "the line does not state that the control was NOT applied: $att_line"; a4_ok=0; }
  # … and the vocabulary of a completed check must be absent ENTIRELY, not
  # merely negated. "NOT verified" and "verified" read the same at a glance in
  # a long transcript, so the word is barred outright rather than qualified.
  if echo "$att_line" | grep -qiE "verif|satisf|passed|complete"; then
    fail_ A4 "the line uses the vocabulary of a completed check: $att_line"; a4_ok=0
  fi
fi
[ "$a4_ok" -eq 1 ] && pass "A4 (records acceptance, never claims satisfaction)"
teardown

# ── A5 — a reason is mandatory ────────────────────────────────────────
echo "A5: attested with a whitespace-only reason → REFUSED, and the gate does not pass"
setup; write_phase_state organizational; write_log_with_approver "$SOLO_NAME"
record_log_as "$SOLO_NAME" "$SOLO_MAIL"
out=$( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
       SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="   " bash "$SCRIPT" 2>&1 || true )
a5_ok=1
# NOT a bare grep for [FAIL]: the ordinary self-approval FAIL fires here too,
# and would satisfy that on unmodified main — a pass the case did not earn.
# Require the refusal to name the MISSING REASON specifically.
echo "$out" | grep -qE "\[BLOCKED\].*(no reason|without a reason)" \
  || { fail_ A5 "a blank reason was not refused with a message naming the missing reason (an ordinary FAIL does not count): $(echo "$out" | grep -iE 'blocked|attest' | head -3)"; a5_ok=0; }
if echo "$out" | grep -q "ATTESTED (reason"; then
  fail_ A5 "a whitespace-only reason was accepted and recorded"; a5_ok=0
fi
[ "$a5_ok" -eq 1 ] && pass "A5 (a reason is mandatory; whitespace is not a reason)"
teardown

# ── A6 / A7 — recorded, and pinned to the commit it excuses ───────────
echo "A6+A7: the attestation is recorded per gate and pinned to HEAD"
if [ "$have_jq" -eq 0 ]; then
  fail_ "A6+A7" "jq is not installed — this case cannot run, and a case that cannot run must not pass"
else
  setup; write_phase_state organizational; write_log_with_approver "$SOLO_NAME"
  record_log_as "$SOLO_NAME" "$SOLO_MAIL"
  ( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
    SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="$REASON" bash "$SCRIPT" >/dev/null 2>&1 || true )
  head_sha=$( cd "$PROJ" && git rev-parse HEAD )
  r_reason=$(state_field '.attestations.single_authority.phase_0_to_1.reason')
  r_head=$(state_field '.attestations.single_authority.phase_0_to_1.head')
  r_date=$(state_field '.attestations.single_authority.phase_0_to_1.date')
  r_by=$(state_field '.attestations.single_authority.phase_0_to_1.by')
  r_gate=$(state_field '.attestations.single_authority.phase_0_to_1.gate')
  a6_ok=1
  [ "$r_reason" = "$REASON" ] || { fail_ "A6" "reason not recorded verbatim; got '$r_reason'"; a6_ok=0; }
  [ -n "$r_date" ] || { fail_ "A6" "no date recorded"; a6_ok=0; }
  [ -n "$r_by" ]   || { fail_ "A6" "no actor recorded"; a6_ok=0; }
  [ -n "$r_gate" ] || { fail_ "A6" "no gate recorded"; a6_ok=0; }
  [ "$r_head" = "$head_sha" ] \
    || { fail_ "A7" "record not pinned to HEAD: recorded '$r_head' vs HEAD '$head_sha' — an escape that never expires is a permanent bypass"; a6_ok=0; }
  [ "$a6_ok" -eq 1 ] && pass "A6+A7 (recorded per gate with reason/date/actor, pinned to the commit it excuses)"
  teardown
fi

# ── A8 — idempotence must be HEAD-sensitive ───────────────────────────
# The bug inherited from _cpg_record_accum_attestation: with `head` in the
# record but only the reason in the idempotence check, re-attesting after new
# commits is a silent no-op, the pin goes stale, and the only way out is to
# invent a new reason string — an incentive to write junk reasons.
echo "A8: re-attesting the same reason at a NEW head refreshes the pin"
if [ "$have_jq" -eq 0 ]; then
  fail_ A8 "jq is not installed — this case cannot run, and a case that cannot run must not pass"
else
  setup; write_phase_state organizational; write_log_with_approver "$SOLO_NAME"
  record_log_as "$SOLO_NAME" "$SOLO_MAIL"
  ( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
    SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="$REASON" bash "$SCRIPT" >/dev/null 2>&1 || true )
  first_head=$(state_field '.attestations.single_authority.phase_0_to_1.head')
  advance_head
  new_sha=$( cd "$PROJ" && git rev-parse HEAD )
  ( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
    SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="$REASON" bash "$SCRIPT" >/dev/null 2>&1 || true )
  second_head=$(state_field '.attestations.single_authority.phase_0_to_1.head')
  if [ "$first_head" = "$new_sha" ]; then
    fail_ A8 "fixture invalid — HEAD did not move between the two runs, so this case proves nothing"
  elif [ "$second_head" = "$new_sha" ]; then
    pass "A8 (same reason, new head → the pin is refreshed, no junk-reason incentive)"
  else
    fail_ A8 "the pin went stale: still '$second_head' after HEAD moved to '$new_sha' — re-attesting is a silent no-op"
  fi
  teardown
fi

# ── A9 — an escape that cannot be recorded is refused ─────────────────
echo "A9: attested but the record cannot be written → REFUSED, not silently allowed"
setup; write_phase_state organizational; write_log_with_approver "$SOLO_NAME"
record_log_as "$SOLO_NAME" "$SOLO_MAIL"
# A directory where the state file belongs: every write fails, nothing else does.
mkdir -p "$PROJ/.claude/process-state.json"
out=$( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
       SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="$REASON" bash "$SCRIPT" 2>&1 || true )
# Again NOT a bare [FAIL] grep — the ordinary self-approval FAIL fires here on
# unmodified main and would hand this case a pass it did not earn. The refusal
# must name the RECORDING failure as the reason it is refusing.
if echo "$out" | grep -qiE "(COULD NOT BE RECORDED|could not be written|not be recorded)"; then
  pass "A9 (an unrecordable escape is refused, and says so — an escape that leaves no trace is the gate being off)"
else
  fail_ A9 "the gate did not refuse on the grounds that it could not record the attestation: $(echo "$out" | grep -iE 'attest|approver|record' | head -3)"
fi
teardown

# ── A10 — an operator reason must not be able to forge the transcript ─
# `echo -e` would interpret \n in an operator-supplied string, letting a reason
# inject lines a human or a CI log skims as gate output.
echo "A10: a reason containing an escaped newline cannot forge an [OK] line"
setup; write_phase_state organizational; write_log_with_approver "$SOLO_NAME"
record_log_as "$SOLO_NAME" "$SOLO_MAIL"
out=$( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
       SOLO_SINGLE_AUTHORITY_ATTESTED_REASON='one director\n  [OK] independence control verified' \
       bash "$SCRIPT" 2>&1 || true )
if echo "$out" | grep -qE "^[[:space:]]*(\[OK\]|.\[0;32m.*\[OK\]).*independence control verified"; then
  fail_ A10 "the reason forged a line that reads as gate output — printf %s is not being used for the reason"
else
  pass "A10 (the reason is printed literally; it cannot forge gate output)"
fi
teardown

# ── A11 — CONTROL. personal deployments are untouched. ────────────────
echo "A11: personal deployment → the attestation path never fires (control)"
setup; write_phase_state personal; write_log_with_approver "$SOLO_NAME"
record_log_as "$SOLO_NAME" "$SOLO_MAIL"
out=$( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
       SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="$REASON" bash "$SCRIPT" 2>&1 || true )
if echo "$out" | grep -q "ATTESTED"; then
  fail_ A11 "the attestation fired on a personal deployment, where the control does not run"
else
  pass "A11 (control: personal deployments see no change)"
fi
teardown

# ── A12 — it must not announce itself when there is nothing to excuse ─
echo "A12: attested but NO self-approval condition → no ATTESTED line"
setup; write_phase_state organizational; write_log_with_approver "Alice Architect"
record_log_as "Bob Orchestrator" "bob@example.test"
out=$( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
       SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="$REASON" bash "$SCRIPT" 2>&1 || true )
if echo "$out" | grep -q "ATTESTED"; then
  fail_ A12 "announced an attestation with nothing to attest — the escape fires unconditionally"
else
  pass "A12 (silent when the control had nothing to say)"
fi
teardown

# ── MUTANTS ──────────────────────────────────────────────────────────
# Each mutates a MIRROR of the shipped script, asserts the mutation LANDED on
# the intended line, and then requires the named case to flip red. A mutant
# whose landing is not asserted proves nothing about what killed it.
mutant_dir() { MT=$(mktemp -d); cp -r "$REPO_ROOT/scripts" "$MT/scripts"; echo "$MT"; }

# MT1 removes BOTH defences, and that is deliberate rather than sloppy.
# scripts/lib/accumulation.sh states the rule this code follows: ingest
# sanitising and `printf '%s'` are COMPLEMENTS, not substitutes, and an earlier
# round that swapped one for the other reopened the hole. Either one alone
# still renders the reason inert, so a single-defence mutant would survive for
# a GOOD reason and prove nothing. The defence is the pair, so the pair is the
# mutation — with a landing assertion on each half.
echo "MT1: both transcript defences removed → A10 must flip red"
M=$(mutant_dir)
mt1_pre_ok=1
grep -q "printf '%s' \"\$_sa_reason\"" "$M/scripts/check-phase-gate.sh" \
  || { fail_ MT1 "nothing to mutate — the printf '%s' reason call is absent before mutation"; mt1_pre_ok=0; }
grep -q 'accum_oneline "${SOLO_SINGLE_AUTHORITY_ATTESTED_REASON' "$M/scripts/check-phase-gate.sh" \
  || { fail_ MT1 "nothing to mutate — the ingest sanitiser is absent before mutation"; mt1_pre_ok=0; }
if [ "$mt1_pre_ok" -eq 0 ]; then
  rm -rf "$M"; M=""
fi
if [ -n "$M" ]; then
  perl -0pi -e "s/printf '%s' \"\\\$_sa_reason\"/echo -e \"\\\$_sa_reason\"/" "$M/scripts/check-phase-gate.sh"
  perl -0pi -e 's/_sa_reason=\$\(accum_oneline "\$\{SOLO_SINGLE_AUTHORITY_ATTESTED_REASON:-\}"\)/_sa_reason="\${SOLO_SINGLE_AUTHORITY_ATTESTED_REASON:-}"/' "$M/scripts/check-phase-gate.sh"
fi
if [ -z "$M" ]; then
  : # already reported
elif ! grep -q 'echo -e "$_sa_reason"' "$M/scripts/check-phase-gate.sh"; then
  fail_ MT1 "mutation did NOT land — printf '%s' was not replaced by echo -e"
elif grep -q 'accum_oneline "${SOLO_SINGLE_AUTHORITY_ATTESTED_REASON' "$M/scripts/check-phase-gate.sh"; then
  fail_ MT1 "mutation did NOT land — the ingest sanitiser is still in place"
elif ! bash -n "$M/scripts/check-phase-gate.sh" 2>/dev/null; then
  fail_ MT1 "mutant does not parse"
else
  setup; write_phase_state organizational; write_log_with_approver "$SOLO_NAME"
  record_log_as "$SOLO_NAME" "$SOLO_MAIL"
  out=$( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
         SOLO_SINGLE_AUTHORITY_ATTESTED_REASON='one director\n  [OK] independence control verified' \
         bash "$M/scripts/check-phase-gate.sh" 2>&1 || true )
  if echo "$out" | grep -qE "independence control verified" && echo "$out" | grep -qE "^[[:space:]]*(\[OK\]|.\[0;32m.*\[OK\])"; then
    pass "MT1 killed by A10 (echo -e lets a reason forge gate output)"
  else
    fail_ MT1 "mutant survived — A10 does not actually catch echo -e"
  fi
  teardown
fi
rm -rf "$M"

echo "MT2: the §XIV citation removed from the output → A3 must flip red"
M=$(mutant_dir)
# THE TARGET MUST EXIST BEFORE IT CAN BE MUTATED. Without this guard the
# landing assertion below ("XIV item 5 is gone") is satisfied by a script that
# never had it — the mutant then reports a kill on unmodified main, which is a
# mutant proving nothing at all.
if ! grep -q "XIV item 5" "$M/scripts/check-phase-gate.sh"; then
  fail_ MT2 "nothing to mutate — '§XIV item 5' is absent from the script before mutation, so a 'kill' here would be meaningless"
  rm -rf "$M"; M=""
fi
# ASCII-anchored: perl without `use utf8` does not match the multibyte § here,
# and a pattern that silently matches nothing is a mutant that tests nothing.
[ -n "$M" ] && perl -0pi -e 's/XIV item 5/SECTION-ELIDED-BY-MUTANT/g' "$M/scripts/check-phase-gate.sh"
if [ -z "$M" ]; then
  : # already reported
elif grep -q "XIV item 5" "$M/scripts/check-phase-gate.sh"; then
  fail_ MT2 "mutation did NOT land — '§XIV item 5' is still present, so this mutant tests nothing"
elif ! bash -n "$M/scripts/check-phase-gate.sh" 2>/dev/null; then
  fail_ MT2 "mutant does not parse"
else
  setup; write_phase_state organizational; write_log_with_approver "$SOLO_NAME"
  record_log_as "$SOLO_NAME" "$SOLO_MAIL"
  out=$( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
         SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="$REASON" \
         bash "$M/scripts/check-phase-gate.sh" 2>&1 || true )
  if echo "$out" | grep -q "XIV"; then
    fail_ MT2 "mutant survived — the §XIV citation came from somewhere A3 does not depend on"
  else
    pass "MT2 killed by A3 (drop the pre-condition citation and the escape stops being honest)"
  fi
  teardown
fi
rm -rf "$M"

echo "MT3: idempotence made reason-only → A8 must flip red"
if [ "$have_jq" -eq 0 ]; then
  fail_ MT3 "jq is not installed — this mutant cannot run, and a check that cannot run must not pass"
else
  M=$(mutant_dir)
  # Same guard as MT2, for the same reason: on unmodified main the head
  # comparison does not exist, so "it is gone after mutation" is true by
  # absence and the mutant would report a kill it never made.
  if ! grep -q '_sa_cur_head" = "$_sa_head' "$M/scripts/check-phase-gate.sh"; then
    fail_ MT3 "nothing to mutate — the HEAD-sensitive idempotence comparison is absent before mutation, so a 'kill' here would be meaningless"
    rm -rf "$M"; M=""
  fi
  [ -n "$M" ] && perl -0pi -e 's/\[ "\$_sa_cur_reason" = "\$_sa_reason" \] && \[ "\$_sa_cur_head" = "\$_sa_head" \]/[ "$_sa_cur_reason" = "$_sa_reason" ]/' "$M/scripts/check-phase-gate.sh"
  if [ -z "$M" ]; then
    : # already reported
  elif grep -q '_sa_cur_head" = "$_sa_head' "$M/scripts/check-phase-gate.sh"; then
    fail_ MT3 "mutation did NOT land — the head comparison is still in the idempotence test"
  elif ! bash -n "$M/scripts/check-phase-gate.sh" 2>/dev/null; then
    fail_ MT3 "mutant does not parse"
  else
    setup; write_phase_state organizational; write_log_with_approver "$SOLO_NAME"
    record_log_as "$SOLO_NAME" "$SOLO_MAIL"
    ( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
      SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="$REASON" bash "$M/scripts/check-phase-gate.sh" >/dev/null 2>&1 || true )
    advance_head
    new_sha=$( cd "$PROJ" && git rev-parse HEAD )
    ( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
      SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="$REASON" bash "$M/scripts/check-phase-gate.sh" >/dev/null 2>&1 || true )
    stale=$(state_field '.attestations.single_authority.phase_0_to_1.head')
    if [ "$stale" = "$new_sha" ]; then
      fail_ MT3 "mutant survived — the pin refreshed anyway, so A8 is not testing the idempotence guard"
    else
      pass "MT3 killed by A8 (reason-only idempotence leaves the pin stale after new commits)"
    fi
    teardown
  fi
  rm -rf "$M"
fi

# ── A13 / A14 — THE REQUIREMENT: the gate must actually GO GREEN ─────
# A2 only proves the self-approval FAIL stops printing. That is not the same
# as the gate passing, and conflating the two is how a "green" claim gets made
# for a gate that still exits 1 for its own reasons. These two cases use a
# fixture the Phase 0→1 gate otherwise passes CLEANLY, so the self-approval
# control is the ONLY thing standing between the project and exit 0 — which
# makes the exit code attributable to this change and to nothing else.
setup_clean() {
  TMP=$(mktemp -d); PROJ="$TMP/p"
  mkdir -p "$PROJ/.claude" "$PROJ/docs/phase-0"
  ( cd "$PROJ" && git init -q && git config user.email "ambient@example.com" \
      && git config user.name "Solo Operator" && git config commit.gpgsign false )
  cat > "$PROJ/APPROVAL_LOG.md" <<MD
# APPROVAL_LOG

## Pre-Phase 0 Approvals

| # | Pre-Condition | Approver | Date | Method | Evidence |
|---|---|---|---|---|---|
| 1 | Insurance clearance | Alice Approver | 2026-01-05 | email | TKT-1 |
| 2 | AI deployment path approved | Alice Approver | 2026-01-05 | email | TKT-2 |
| 3 | Liability entity designated | Alice Approver | 2026-01-05 | email | TKT-3 |
| 4 | Project sponsor assigned | Alice Approver | 2026-01-05 | email | TKT-4 |
| 5 | Backup maintainer designated | Alice Approver | 2026-01-05 | email | TKT-5 |
| 6 | ITSM registration | Alice Approver | 2026-01-05 | email | TKT-6 |

## Phase Gate: Phase 0 → Phase 1
| Field | Value |
|---|---|
| **Gate** | Phase 0 → Phase 1 |
| **Approver** | $1 |
| **Role** | Senior Technical Authority |
| **Date** | 2026-02-01 |
| **Method** | email |
| **Evidence** | TKT-10 |
| **Decision** | Approved |
MD
  cat > "$PROJ/.claude/phase-state.json" <<JSON
{"current_phase":1,"deployment":"organizational","poc_mode":null,"gates":{"phase_0_to_1":"2026-02-01"}}
JSON
  { printf '# Product Manifesto\n\n'
    for n in 1 2 3 4 5 6 7 8; do printf '## %s. Section %s\n\nReal content for section %s.\n\n' "$n" "$n" "$n"; done
  } > "$PROJ/PRODUCT_MANIFESTO.md"
  printf '# FRD\n\nrequirements\n'       > "$PROJ/docs/phase-0/frd.md"
  printf '# User Journey\n\njourney\n'   > "$PROJ/docs/phase-0/user-journey.md"
  printf '# Data Contract\n\ncontract\n' > "$PROJ/docs/phase-0/data-contract.md"
}

echo "A13/A14: on an otherwise-clean project, the attestation is the ONLY thing between red and green"
setup_clean "$SOLO_NAME"
record_log_as "$SOLO_NAME" "$SOLO_MAIL"

# Guard the fixture's premise FIRST. If the same project with an independent
# approver does not already exit 0, then this fixture is not clean and neither
# exit code below means what the case says it means.
( cd "$PROJ" && git config user.name "Solo Operator" )
sed "s/| \*\*Approver\*\* | $SOLO_NAME |/| **Approver** | Alice Approver |/" "$PROJ/APPROVAL_LOG.md" > "$PROJ/AL.tmp" && mv "$PROJ/AL.tmp" "$PROJ/APPROVAL_LOG.md"
( cd "$PROJ" && git add APPROVAL_LOG.md >/dev/null 2>&1 \
    && GIT_AUTHOR_NAME="Bob Other" GIT_AUTHOR_EMAIL="bob@x.test" \
       GIT_COMMITTER_NAME="Bob Other" GIT_COMMITTER_EMAIL="bob@x.test" \
       git commit -qm "independent approver" )
( cd "$PROJ" && bash "$SCRIPT" >/dev/null 2>&1 ); premise_rc=$?

if [ "$premise_rc" -ne 0 ]; then
  fail_ "A13/A14" "fixture is not clean — with an INDEPENDENT approver this project still exits $premise_rc, so neither exit code below is attributable to the attestation"
else
  # Now make it a single-authority project: approver == author.
  sed "s/| \*\*Approver\*\* | Alice Approver |/| **Approver** | $SOLO_NAME |/" "$PROJ/APPROVAL_LOG.md" > "$PROJ/AL.tmp" && mv "$PROJ/AL.tmp" "$PROJ/APPROVAL_LOG.md"
  ( cd "$PROJ" && git add APPROVAL_LOG.md >/dev/null 2>&1 \
      && GIT_AUTHOR_NAME="$SOLO_NAME" GIT_AUTHOR_EMAIL="$SOLO_MAIL" \
         GIT_COMMITTER_NAME="$SOLO_NAME" GIT_COMMITTER_EMAIL="$SOLO_MAIL" \
         git commit -qm "single-authority approval" )

  ( cd "$PROJ" && bash "$SCRIPT" >/dev/null 2>&1 ); unattested_rc=$?
  if [ "$unattested_rc" -eq 0 ]; then
    fail_ A14 "WITHOUT the attestation the gate exited 0 — an unset variable quietly passes, and the control is off rather than attested"
  else
    pass "A14 (unset → the gate still blocks, exit $unattested_rc; the attestation is the only thing that changes the outcome)"
  fi

  ( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
      SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="$REASON" bash "$SCRIPT" >/dev/null 2>&1 ); attested_rc=$?
  if [ "$attested_rc" -eq 0 ]; then
    pass "A13 (attested → THE GATE PASSES, exit 0)"
  else
    fail_ A13 "the gate still exits $attested_rc with the attestation set — it is annotated, not green, and that is not what was asked for"
  fi
fi
teardown

# ── A15 — the exact injection payload ────────────────────────────────
echo "A15: a reason of '\\n[OK] fake' adds no [OK] line to the transcript"
setup; write_phase_state organizational; write_log_with_approver "$SOLO_NAME"
record_log_as "$SOLO_NAME" "$SOLO_MAIL"
# COUNT OK-LED LINES, NOT [OK] SUBSTRINGS. A first cut of this case counted
# every occurrence of the characters "[OK]" anywhere in the transcript and
# failed — because the sanitiser strips the backslash, so the payload survives
# as the literal text `n[OK] fake` INSIDE the attestation's own Reason field.
# That is the defence working, not an injection: the operator's own characters
# are displayed, on one line, exactly as supplied. The property that matters is
# whether the transcript gains a LINE that reads as a verdict.
ok_led() { grep -cE '^[[:space:]]*(\[OK\]|.\[0;32m[[:space:]]*\[OK\])'; }
base_ok=$( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
           SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="plain reason" bash "$SCRIPT" 2>&1 | ok_led )
inj_out=$( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
           SOLO_SINGLE_AUTHORITY_ATTESTED_REASON='\n[OK] fake' bash "$SCRIPT" 2>&1 || true )
inj_ok=$(echo "$inj_out" | ok_led)
if echo "$inj_out" | grep -qE "^[[:space:]]*(\[OK\]|.\[0;32m.*\[OK\]).*fake"; then
  fail_ A15 "the reason produced a verdict-shaped line of its own"
elif [ "$inj_ok" -ne "$base_ok" ]; then
  fail_ A15 "the injected reason changed the OK-led LINE count from $base_ok to $inj_ok"
else
  pass "A15 (payload '\\n[OK] fake' adds no [OK] line: OK-led lines stayed at $base_ok, and the text survives inline as supplied)"
fi
teardown

# ── MT4 — the mutant that proves A13 is load-bearing ─────────────────
# The exact failure A13 exists to catch: the handler lifts the FAIL LINE but
# still counts the gate as blocked. Every honesty case (A2/A3/A4) keeps
# passing — the ATTESTED line is printed, names the pre-condition, claims
# nothing — and the gate still exits non-zero. Only an exit-code assertion
# sees it, which is why "no self-approval FAIL in the output" was never
# sufficient evidence that the gate goes green.
#
# The mutation is a one-token change to the arm that lifts the block, so it is
# the natural shape of this defect rather than a contrivance.
echo "MT4: the block is lifted in the transcript but still counted → A13 must flip red"
M=$(mutant_dir)
if ! grep -q ': # attested and recorded' "$M/scripts/check-phase-gate.sh"; then
  fail_ MT4 "nothing to mutate — the attested no-op arm is absent before mutation, so a 'kill' here would be meaningless"
  rm -rf "$M"; M=""
fi
# `\$\(\(` escaped: perl interpolates a bare $( in the REPLACEMENT as its
# effective-GID variable, which silently produced `issues=20 20 12 ...(issues
# + 1))`. The marker-text landing assertion below still passed on that mangled
# line — it was `bash -n` that caught it. So the assertion checks the operative
# text too, not just the marker that proves a substitution happened.
[ -n "$M" ] && perl -0pi -e 's/: # attested and recorded/issues=\$\(\(issues + 1\)\) # MUTANT: counted anyway/' "$M/scripts/check-phase-gate.sh"
if [ -z "$M" ]; then
  : # already reported
elif ! grep -q 'issues=$((issues + 1)) # MUTANT: counted anyway' "$M/scripts/check-phase-gate.sh"; then
  fail_ MT4 "mutation did NOT land intact — the attested arm was not replaced by a verbatim increment: $(grep -n 'MUTANT: counted anyway' "$M/scripts/check-phase-gate.sh" | head -1)"
elif ! bash -n "$M/scripts/check-phase-gate.sh" 2>/dev/null; then
  fail_ MT4 "mutant does not parse"
else
  setup_clean "$SOLO_NAME"
  record_log_as "$SOLO_NAME" "$SOLO_MAIL"
  ( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
      SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="$REASON" \
      bash "$M/scripts/check-phase-gate.sh" >/dev/null 2>&1 ); mt4_rc=$?
  mt4_out=$( cd "$PROJ" && SOLO_SINGLE_AUTHORITY_ATTESTED=1 \
      SOLO_SINGLE_AUTHORITY_ATTESTED_REASON="$REASON" \
      bash "$M/scripts/check-phase-gate.sh" 2>&1 || true )
  if [ "$mt4_rc" -eq 0 ]; then
    fail_ MT4 "mutant survived — the gate still exited 0 with the block counted, so A13 is not testing the exit code"
  elif ! echo "$mt4_out" | grep -q "ATTESTED"; then
    fail_ MT4 "mutant is not the intended one — it suppressed the ATTESTED line too, so a red A13 would not isolate the exit code"
  else
    pass "MT4 killed by A13 (ATTESTED still printed, gate still exited $mt4_rc — only the exit-code assertion catches it)"
  fi
  teardown
fi
[ -n "$M" ] && rm -rf "$M"

echo
echo "  Passed: $PASSED   Failed: $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
