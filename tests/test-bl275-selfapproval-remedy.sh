#!/usr/bin/env bash
# tests/test-bl275-selfapproval-remedy.sh
#
# BL-275 half one. The self-approval refusal's remedy line is wrong in BOTH
# halves, and an operator who follows it is sent in a circle:
#
#   "Have the approver commit the APPROVAL_LOG.md entry themselves,
#    or use --force with documented justification."
#
#   1. The first half IS the failing condition. The check fires when the
#      Approver cell matches the git author of that row, so doing what the
#      sentence says reproduces the failure. The sentence was written from
#      docs/governance-framework.md §V control 1 ("committed by the approver");
#      the code enforces the inverse; nobody reconciled them.
#   2. `--force` was never built. The parser accepts --gate, --gate= and
#      --help/-h and exits 2 on anything else.
#
# THIS SUITE COVERS HALF ONE ONLY — removing two false statements and saying
# what the check actually compared. It deliberately does NOT pin any sentence
# telling the operator how to make the gate PASS, because control 1 and the
# implementation prescribe opposite actions and no wording satisfies both.
# That choice is the maintainer's and is recorded on `## BL-275:` as options
# A/B/C. A test that pinned one of them here would quietly decide it.
#
# Runs on bash 3.2.57 (macOS) and 5.x.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check-phase-gate.sh"

PASSED=0
FAILED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }

setup() {
  TMP=$(mktemp -d); PROJ="$TMP/p"; mkdir -p "$PROJ/.claude"
  ( cd "$PROJ" && git init -q && git config user.email "ambient@example.com" \
      && git config user.name "Solo Operator" && git config commit.gpgsign false )
  cat > "$PROJ/APPROVAL_LOG.md" <<'MD'
# APPROVAL_LOG

## Phase Gate: Phase 0 → Phase 1
| Field | Value |
|---|---|
| **Gate** | Phase 0 → Phase 1 |
| **Approver** | Martin Dean |
| **Date** | 2026-02-01 |
MD
  cat > "$PROJ/.claude/phase-state.json" <<'JSON'
{"current_phase":1,"deployment":"organizational","gates":{"phase_0_to_1":"2026-02-01"}}
JSON
  ( cd "$PROJ" && git add -A >/dev/null 2>&1 \
      && GIT_AUTHOR_NAME="Martin Dean" GIT_AUTHOR_EMAIL="m@x.test" \
         GIT_COMMITTER_NAME="Martin Dean" GIT_COMMITTER_EMAIL="m@x.test" \
         git commit -qm "approval row" )
}
teardown() { rm -rf "$TMP"; }

refusal() { ( cd "$PROJ" && bash "${1:-$SCRIPT}" 2>&1 ) || true; }

# ── R5 — CONTROL. The refusal itself is untouched. ───────────────────
# This is a MESSAGE fix. If the control stops firing, the change has done
# something it was never meant to do and every other case here is moot.
echo "R5: the self-approval refusal still fires (control — this is a message fix)"
setup
out=$(refusal)
if echo "$out" | grep -qE "\[FAIL\].*self-approval detected"; then
  pass "R5 (control: the refusal is unchanged)"
else
  fail_ R5 "the self-approval refusal stopped firing — a message fix must not change the verdict"
fi
teardown

# ── R2 — the evidence for R1, measured rather than asserted ──────────
# R1 removes a flag from the advice. R2 is why: the flag does not exist.
# Passes before AND after — it pins the fact the fix rests on, so that if
# --force is ever implemented this case turns red and R1 must be revisited.
echo "R2: --force is not a real flag (the fact R1 rests on)"
setup
fout=$( cd "$PROJ" && bash "$SCRIPT" --force 2>&1 ); frc=$?
if [ "$frc" -eq 2 ] && echo "$fout" | grep -q "Unknown argument"; then
  pass "R2 (--force exits 2 'Unknown argument' — advertising it was advertising nothing)"
else
  fail_ R2 "--force did not behave as an unknown argument (rc=$frc): $(echo "$fout" | head -2)"
fi
teardown

# ── R1 — the non-existent flag is gone from the advice ───────────────
echo "R1: the refusal no longer offers --force"
setup
out=$(refusal)
block=$(echo "$out" | grep -A 6 "self-approval detected")
if echo "$block" | grep -q -- "--force"; then
  fail_ R1 "the refusal still offers --force, which exits 2: $(echo "$block" | grep -- '--force' | head -1)"
else
  pass "R1 (no --force in the refusal)"
fi
teardown

# ── R3 — the advice that reproduces the failure is gone ──────────────
echo "R3: the refusal no longer tells the operator to do the thing that fails"
setup
out=$(refusal)
block=$(echo "$out" | grep -A 6 "self-approval detected")
if echo "$block" | grep -qi "approver commit the APPROVAL_LOG.md entry themselves"; then
  fail_ R3 "the refusal still advises the failing action — the approver committing their own row IS what this check refuses"
else
  pass "R3 (the circular advice is gone)"
fi
teardown

# ── R4 — it says what it actually compared ───────────────────────────
# Replacing bad advice with no advice would leave the operator with a verdict
# and no way to reason about it. The replacement asserts NEITHER rule; it
# states the comparison and names the distinction the check cannot make.
echo "R4: the refusal states what it compared and what it cannot distinguish"
setup
out=$(refusal)
block=$(echo "$out" | grep -A 6 "self-approval detected")
r4_ok=1
echo "$block" | grep -qi "compared" \
  || { fail_ R4 "the refusal does not say what it compared"; r4_ok=0; }
echo "$block" | grep -qi "cannot tell\|cannot distinguish" \
  || { fail_ R4 "the refusal does not name the distinction it cannot make"; r4_ok=0; }
[ "$r4_ok" -eq 1 ] && pass "R4 (states the comparison and its own limit)"
teardown

# ── R6 — a single-authority project is pointed at its real blocker ───
echo "R6: the refusal points a single-authority project at the pre-condition, not at a flag"
setup
out=$(refusal)
block=$(echo "$out" | grep -A 6 "self-approval detected")
if echo "$block" | grep -q "XIV"; then
  pass "R6 (names governance-framework §XIV item 5 as the pre-condition behind the symptom)"
else
  fail_ R6 "the refusal does not point at the blocking pre-condition: $(echo "$block" | tail -3)"
fi

# ── R7 — the pointer names an entry that EXISTS ───────────────────────
# The shipped text said `See ## BL-274:.` — an entry filed on no branch. It now
# points at BL-275, the entry about this exact message. Pinned by its literal
# token, because a repoint nobody asserts is a repoint that drifts back.
echo "R7: the refusal points at BL-275, not the never-filed BL-274"
setup
out=$(refusal)
block=$(echo "$out" | grep -A 8 "self-approval detected")
if echo "$block" | grep -q 'See ## BL-275:'; then
  pass "R7 (the pointer resolves — See ## BL-275:)"
else
  fail_ R7 "the refusal still points elsewhere: $(echo "$block" | grep -o 'See ## BL-[0-9]*:' | head -1)"
fi
teardown

# ── MUTANTS ──────────────────────────────────────────────────────────
mutant_dir() { MT=$(mktemp -d); cp -r "$REPO_ROOT/scripts" "$MT/scripts"; echo "$MT"; }

echo "MTR1: --force restored to the advice → R1 must flip red"
M=$(mutant_dir)
if grep -q -- "--force with documented" "$M/scripts/check-phase-gate.sh"; then
  fail_ MTR1 "nothing to mutate — the --force advice is already present, so this mutant would prove nothing"
  rm -rf "$M"; M=""
fi
[ -n "$M" ] && perl -0pi -e 's/(echo "  This gate compared)/echo "  or use --force with documented justification."\n        $1/' "$M/scripts/check-phase-gate.sh"
if [ -z "$M" ]; then
  :
elif ! grep -q -- "--force with documented" "$M/scripts/check-phase-gate.sh"; then
  fail_ MTR1 "mutation did NOT land — --force was not reinserted"
elif ! bash -n "$M/scripts/check-phase-gate.sh" 2>/dev/null; then
  fail_ MTR1 "mutant does not parse"
else
  setup
  out=$(refusal "$M/scripts/check-phase-gate.sh")
  if echo "$out" | grep -A 6 "self-approval detected" | grep -q -- "--force"; then
    pass "MTR1 killed by R1 (reinstating --force is caught)"
  else
    fail_ MTR1 "mutant survived — R1 does not actually see the advice block"
  fi
  teardown
fi
[ -n "$M" ] && rm -rf "$M"

echo "MTR2: the circular advice restored → R3 must flip red"
M=$(mutant_dir)
if grep -qi "approver commit the APPROVAL_LOG.md entry themselves" "$M/scripts/check-phase-gate.sh"; then
  fail_ MTR2 "nothing to mutate — the circular advice is already present"
  rm -rf "$M"; M=""
fi
[ -n "$M" ] && perl -0pi -e 's/(echo "  This gate compared)/echo "  Have the approver commit the APPROVAL_LOG.md entry themselves."\n        $1/' "$M/scripts/check-phase-gate.sh"
if [ -z "$M" ]; then
  :
elif ! grep -qi "approver commit the APPROVAL_LOG.md entry themselves" "$M/scripts/check-phase-gate.sh"; then
  fail_ MTR2 "mutation did NOT land — the circular advice was not reinserted"
elif ! bash -n "$M/scripts/check-phase-gate.sh" 2>/dev/null; then
  fail_ MTR2 "mutant does not parse"
else
  setup
  out=$(refusal "$M/scripts/check-phase-gate.sh")
  if echo "$out" | grep -A 6 "self-approval detected" | grep -qi "approver commit the APPROVAL_LOG.md entry themselves"; then
    pass "MTR2 killed by R3 (reinstating the circular advice is caught)"
  else
    fail_ MTR2 "mutant survived — R3 does not actually see the advice block"
  fi
  teardown
fi
[ -n "$M" ] && rm -rf "$M"

echo
echo "  Passed: $PASSED   Failed: $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
