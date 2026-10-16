#!/usr/bin/env bash
# tests/test-bug010-intake-silent-paths.sh
#
# `## BUG-010:` defects (1) and (2), and the residuals `## BL-265:`,
# `## BL-266:` and `## BL-267:` left open on them. Every case is a way the
# intake wizard used to report success — or never stop — over input it had
# not understood.
#
#   L  load_progress() subscripted seven keys; a progress file missing one
#      raised a KeyError on stderr, the status was ignored, and --resume
#      carried on with the variables unset, then printed "Intake Complete!"
#      at rc 0.                                    (BUG-010 (1), BL-266)
#   E  prompt_choice, and prompt_with_suggestions with no default, never
#      checked read's status: at end of input they re-asked forever
#      (BUG-010 measured ~20 MB of "Invalid choice" in two minutes). A `?`
#      at a numbered choice was told "Invalid choice".      (BUG-010 (2), BL-267)
#   R  every render_intake_file call was `|| true`, which also suspended
#      set -e INSIDE it: a jq failure mid-table appended a truncated
#      appendix to PROJECT_INTAKE.md, and the final render's failure still
#      ended in "Intake Complete!".                              (BL-265)
#
# Every run drives the REAL wizard (a copy, in a temp project), from a pipe,
# under a watchdog — the "before" of case E is an infinite loop.
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
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g' "$1"; }

[ -f "$WIZARD" ] || { echo "  [FAIL] setup — $WIZARD not found"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }
for t in python3 jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "  [FAIL] setup — $t is required"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }
done

# mk_project <dir> <progress-json> [wizard-file] — a project the wizard
# accepts, with a COPY of the wizard so nothing here touches the checkout.
mk_project() {
  local d="$1" prog="$2" bin="${3:-$WIZARD}"
  mkdir -p "$d/.claude" "$d/scripts/lib" || return 1
  cp "$bin" "$d/scripts/intake-wizard.sh" || return 1
  cp "$REPO_ROOT"/scripts/lib/helpers*.sh "$d/scripts/lib/" 2>/dev/null || return 1
  printf '{"project":"P","current_phase":0,"track":"full","deployment":"personal","poc_mode":null}\n' \
    > "$d/.claude/phase-state.json"
  printf '%s\n' "$prog" > "$d/.claude/intake-progress.json"
  printf '# Project Intake\n' > "$d/PROJECT_INTAKE.md"
}
# A progress file with every key load_progress reads.
good_progress() {  # good_progress <last> <completed-json> [answers-json]
  local ans='{}'; [ $# -ge 3 ] && ans="$3"
  printf '{ "version": 1, "last_section": %s, "completed_sections": %s,
  "project_name": "P", "platform": "web", "track": "full",
  "deployment": "personal", "language": "typescript",
  "description": "f", "poc_mode": null, "answers": %s }' "$1" "$2" "$ans"
}
ALL='[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 115, 12, 13]'

# watch <outfile> <cmd…> — run with a 20 s ceiling. Sets RUN_RC; RUN_RC=124
# means it was still running and was killed (no timeout(1) on macOS).
watch() {
  local out="$1"; shift
  ( "$@" ) >"$out.raw" 2>&1 &
  local pid=$! n=0
  while kill -0 "$pid" 2>/dev/null; do
    n=$((n + 1))
    if [ "$n" -gt 100 ]; then kill "$pid" 2>/dev/null; pkill -P "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; RUN_RC=124; strip_ansi "$out.raw" > "$out"; return 0; fi
    sleep 0.2
  done
  wait "$pid"; RUN_RC=$?
  strip_ansi "$out.raw" > "$out"
  return 0
}
_resume() { cd "$1" && printf '%s' "$2" | SOIF_NONINTERACTIVE=1 bash scripts/intake-wizard.sh --resume; }
resume() { watch "$1/run.out" _resume "$1" "$2"; }

# sourced <dir> <snippet> — run a snippet against the sourced wizard, in a
# subshell so its `set -euo pipefail` does not leak into the harness.
_sourced() {
  cd "$1" || exit 90
  __SOLO_INTAKE_WIZARD_SOURCED__=1
  # shellcheck disable=SC1091
  source scripts/intake-wizard.sh >/dev/null 2>&1 || exit 91
  PROGRESS_FILE="$1/.claude/intake-progress.json"
  INTAKE_FILE="$1/PROJECT_INTAKE.md"
  eval "$2"
}

no_complete() { ! grep -q 'Intake Complete' "$1"; }

echo "=== L — load_progress refuses a progress file it cannot read (BUG-010 (1)) ==="

for spec in "project_name|missing key" "last_section|missing key" "BADJSON|not JSON" "NONINT|non-integer last_section"; do
  key="${spec%%|*}"; what="${spec#*|}"
  d="$(newtmp)/proj"
  case "$key" in
    BADJSON) prog='{ "last_section": 3, ' ;;
    NONINT)  prog="$(good_progress '"three"' '[1, 2, 3]')" ;;
    *)       prog="$(good_progress 3 '[1, 2, 3]' | python3 -c "import json,sys; d=json.load(sys.stdin); d.pop('$key'); print(json.dumps(d))")" ;;
  esac
  mk_project "$d" "$prog" || { fail_ "L setup ($what)" "fixture"; continue; }
  resume "$d" $'pause\n'
  bad=""
  [ "$RUN_RC" -ne 0 ] || bad="$bad [rc 0]"
  [ "$RUN_RC" -ne 124 ] || bad="$bad [hung]"
  no_complete "$d/run.out" || bad="$bad [printed Intake Complete]"
  grep -q 'Resuming from' "$d/run.out" && bad="$bad [resumed anyway]"
  case "$key" in
    BADJSON|NONINT) grep -qi 'progress' "$d/run.out" || bad="$bad [refusal does not name the progress file]" ;;
    *) grep -q "$key" "$d/run.out" || bad="$bad [refusal does not name '$key']" ;;
  esac
  grep -q 'Traceback' "$d/run.out" && bad="$bad [raw traceback shown]"
  [ -z "$bad" ] && pass "L ($what: $key) — --resume refuses by name, rc=$RUN_RC, nothing resumed" \
                || fail_ "L ($what: $key)" "$bad :: $(tail -3 "$d/run.out" | tr '\n' ' ')"
done

d="$(newtmp)/proj"
mk_project "$d" "$(good_progress 3 '[1, 2, 3]')"
resume "$d" $'pause\n'
if grep -q 'Resuming from Section 4' "$d/run.out" && [ "$RUN_RC" -ne 124 ]; then
  pass "L-C (control) — a complete progress file still resumes at Section 4"
else
  fail_ "L-C (control)" "rc=$RUN_RC :: $(tail -3 "$d/run.out" | tr '\n' ' ')"
fi

echo "=== E — end of input stops the wizard; it does not loop or complete (BUG-010 (2), BL-267) ==="

# E1 — the whole wizard, resumed with NO input at all. Before: an endless
# "Invalid choice" loop at the first numbered choice.
d="$(newtmp)/proj"
mk_project "$d" "$(good_progress 3 '[1, 2, 3]')"
resume "$d" ''
bad=""
[ "$RUN_RC" -ne 124 ] || bad="$bad [still running after 20 s — the loop]"
[ "$RUN_RC" -ne 0 ]   || bad="$bad [rc 0]"
no_complete "$d/run.out" || bad="$bad [printed Intake Complete]"
grep -q 'Input ended' "$d/run.out" || bad="$bad [no end-of-input refusal]"
sz=$(wc -c < "$d/run.out" | tr -d ' ')
[ "${sz:-0}" -lt 200000 ] || bad="$bad [output $sz bytes]"
[ -z "$bad" ] && pass "E1 — --resume with no input stops at rc=$RUN_RC, says input ended, and does not complete" \
              || fail_ "E1" "$bad :: $(tail -2 "$d/run.out" | cut -c1-160 | tr '\n' ' ')"

# E2..E6 — the helpers themselves, sourced.
d="$(newtmp)/proj"; mk_project "$d" "$(good_progress 3 '[1, 2, 3]')"
watch "$d/e2.out" _sourced "$d" 'set +e; v=$(prompt_choice "Pick" alpha beta </dev/null); echo "rc=$?"'
if [ "$RUN_RC" -ne 124 ] && grep -q 'rc=[1-9]' "$d/e2.out" && grep -q 'Input ended' "$d/e2.out" && ! grep -q 'Invalid choice' "$d/e2.out"; then
  pass "E2 — prompt_choice at end of input returns non-zero and says so, once"
else
  fail_ "E2" "RUN_RC=$RUN_RC :: $(head -c 300 "$d/e2.out" | tr '\n' ' ')"
fi

watch "$d/e3.out" _sourced "$d" 'set +e; v=$(prompt_with_suggestions "Name" some_key </dev/null); echo "rc=$?"'
if [ "$RUN_RC" -ne 124 ] && grep -q 'rc=[1-9]' "$d/e3.out" && grep -q 'Input ended' "$d/e3.out"; then
  pass "E3 — prompt_with_suggestions with no default at end of input returns non-zero"
else
  fail_ "E3" "RUN_RC=$RUN_RC :: $(head -c 300 "$d/e3.out" | tr '\n' ' ')"
fi

watch "$d/e4.out" _sourced "$d" 'set +e; v=$(prompt_with_suggestions "Name" some_key "dflt" </dev/null); echo "rc=$? v=$v"'
if grep -q 'rc=0 v=dflt' "$d/e4.out"; then
  pass "E4 (control) — prompt_with_suggestions WITH a default still takes it at end of input"
else
  fail_ "E4 (control)" "$(head -c 300 "$d/e4.out" | tr '\n' ' ')"
fi

watch "$d/e5.out" _sourced "$d" 'set +e; v=$(printf "2" | prompt_choice "Pick" alpha beta); echo "rc=$? v=$v"'
if grep -q 'rc=0 v=beta' "$d/e5.out"; then
  pass "E5 — a last answer with no trailing newline is still taken, not treated as end of input"
else
  fail_ "E5" "$(head -c 300 "$d/e5.out" | tr '\n' ' ')"
fi

watch "$d/e6.out" _sourced "$d" 'set +e; v=$(printf "?\n1\n" | prompt_choice "Pick" alpha beta); echo "rc=$? v=$v"'
if grep -q 'rc=0 v=alpha' "$d/e6.out" && grep -q 'No suggestions' "$d/e6.out" && ! grep -q 'Invalid choice' "$d/e6.out"; then
  pass "E6 — '?' at a numbered choice explains itself instead of 'Invalid choice', then re-asks"
else
  fail_ "E6" "$(head -c 300 "$d/e6.out" | tr '\n' ' ')"
fi

echo "=== R — a failed render is said, and never half-written (BL-265 residual) ==="

# `.answers` as a string: the length test passes and to_entries fails, so
# the SECOND jq of the render dies after the first has written its table.
BADANS="$(good_progress 13 "$ALL" '"x"')"

d="$(newtmp)/proj"; mk_project "$d" "$BADANS"
cp "$d/PROJECT_INTAKE.md" "$d/before.md"
watch "$d/r1.out" _sourced "$d" 'set +e; render_intake_file; echo "rc=$?"'
bad=""
grep -q 'rc=[1-9]' "$d/r1.out" || bad="$bad [render returned 0 over a jq failure]"
cmp -s "$d/before.md" "$d/PROJECT_INTAKE.md" || bad="$bad [PROJECT_INTAKE.md was changed]"
[ -z "$bad" ] && pass "R1 — render_intake_file returns non-zero and leaves PROJECT_INTAKE.md byte-identical" \
              || fail_ "R1" "$bad"

# R5 — the FIRST jq (the Project Context table) failing: `completed_sections`
# as a string makes its `map(tostring)` error. A second jq failing (R1) is
# not the same guard — each call's status is checked on its own line.
d="$(newtmp)/proj"; mk_project "$d" "$(good_progress 13 '"1, 2"')"
cp "$d/PROJECT_INTAKE.md" "$d/before.md"
watch "$d/r5.out" _sourced "$d" 'set +e; render_intake_file; echo "rc=$?"'
if grep -q 'rc=[1-9]' "$d/r5.out" && cmp -s "$d/before.md" "$d/PROJECT_INTAKE.md"; then
  pass "R5 — a failure in the Project Context jq is caught too, and the file is left byte-identical"
else
  fail_ "R5" "$(tr '\n' ' ' < "$d/r5.out" | cut -c1-200)"
fi

d="$(newtmp)/proj"; mk_project "$d" "$BADANS"
watch "$d/r2.out" _sourced "$d" 'set +e; save_section 3; echo "rc=$?"'
if grep -q 'rc=0' "$d/r2.out" && grep -q 'PROJECT_INTAKE.md was NOT updated' "$d/r2.out"; then
  pass "R2 — after a section, a failed render is said and the wizard goes on"
else
  fail_ "R2" "$(tr '\n' ' ' < "$d/r2.out" | cut -c1-300)"
fi

d="$(newtmp)/proj"; mk_project "$d" "$BADANS"
resume "$d" ''
bad=""
[ "$RUN_RC" -ne 0 ] || bad="$bad [rc 0]"
[ "$RUN_RC" -ne 124 ] || bad="$bad [hung]"
no_complete "$d/run.out" || bad="$bad [printed Intake Complete over a failed render]"
grep -q 'PROJECT_INTAKE.md was NOT updated' "$d/run.out" || bad="$bad [failure not said]"
[ -z "$bad" ] && pass "R3 — the final render failing stops the run (rc=$RUN_RC) instead of 'Intake Complete!'" \
              || fail_ "R3" "$bad :: $(tail -3 "$d/run.out" | tr '\n' ' ')"

d="$(newtmp)/proj"; mk_project "$d" "$(good_progress 13 "$ALL")"
resume "$d" ''
if [ "$RUN_RC" -eq 0 ] && grep -q 'Intake Complete' "$d/run.out" && grep -q 'INTAKE_ANSWERS_BEGIN' "$d/PROJECT_INTAKE.md"; then
  pass "R4 (control) — a complete, readable intake still ends in 'Intake Complete!' at rc 0"
else
  fail_ "R4 (control)" "rc=$RUN_RC :: $(tail -3 "$d/run.out" | tr '\n' ' ')"
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
