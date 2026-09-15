#!/usr/bin/env bash
# tests/test-bl265-jq-reserved-label.sh
#
# `## BL-265:` — A JQ KEYWORD NAMED A FUNCTION PARAMETER, SO THE INTAKE
# FILE'S PROJECT CONTEXT TABLE RENDERED EMPTY.
#
# render_intake_file() in scripts/intake-wizard.sh opened its Project
# Context table with `def row(label; val): …`. `label` is a jq KEYWORD
# (`label $out | break $out`), not an identifier, so jq refuses to compile
# the ENTIRE program — not just that line — and emits nothing. Measured on
# jq 1.5, 1.6, 1.7 and 1.8.2; only jq 1.4, which predates label/break,
# accepts it.
#
# The damage is bounded but silent in the direction that matters: both call
# sites are `render_intake_file || true`, which also suppresses `set -e`
# inside the function, so the appendix is still written — with a Project
# Context table that has a header and ZERO rows. Project name, description,
# platform, track, deployment, language, POC mode and the section counters
# all vanish from PROJECT_INTAKE.md while the wizard prints
# "[OK] Section N saved." and carries on.
#
# This drives the REAL render_intake_file against a hermetic progress file.
# The control is the Answers table, which is produced by a SECOND jq
# invocation and was never affected — it passes at base, so a RED run
# cannot be mistaken for a broken fixture.
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
command -v jq >/dev/null 2>&1 || { echo "  [FAIL] setup — jq is required"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }

# Distinctive payloads: if the program fails to compile, these are exactly
# what goes missing from the rendered file.
CTX_NAME='BL265-PROJECT-NAME'
CTX_DESC='BL265-DESCRIPTION'
CTX_LANG='BL265-LANGUAGE'
ANS_VALUE='BL265-ANSWER-VALUE'

# mk_progress <dir> — a project skeleton carrying an intake-progress.json
# with one recorded answer (the control) and a full context block.
mk_progress() {
  local d="$1"
  mkdir -p "$d/.claude" || return 1
  cat > "$d/.claude/intake-progress.json" <<PROGRESS
{
  "last_section": 3,
  "project_name": "$CTX_NAME",
  "platform": "web",
  "track": "full",
  "deployment": "personal",
  "language": "$CTX_LANG",
  "description": "$CTX_DESC",
  "poc_mode": null,
  "completed_sections": [1, 2, 3],
  "answers": { "problem_statement": "$ANS_VALUE" }
}
PROGRESS
  jq empty "$d/.claude/intake-progress.json" 2>/dev/null || return 1
  return 0
}

# render <project-dir> [wizard] → RENDER_RC, and writes
#   <project-dir>/PROJECT_INTAKE.md plus <project-dir>/render.err
# Sourcing is subshell-isolated: intake-wizard.sh carries `set -euo pipefail`
# at top level and would impose it on this harness otherwise.
render() {
  local d="$1" bin="${2:-$WIZARD}"
  (
    cd "$d" || exit 90
    __SOLO_INTAKE_WIZARD_SOURCED__=1
    # shellcheck disable=SC1090
    source "$bin" >/dev/null 2>&1 || exit 91
    PROGRESS_FILE="$d/.claude/intake-progress.json"
    INTAKE_FILE="$d/PROJECT_INTAKE.md"
    # Production calls this as `render_intake_file || true`, which also
    # suppresses the sourced `set -e` inside the function. Keep that exact
    # shape — under a bare call the failing jq aborts the subshell and the
    # appendix is never appended, which is NOT what an operator sees.
    render_intake_file || exit $?
  ) 2>"$d/render.err"
  RENDER_RC=$?
  return 0
}

# ctx_row <file> <label> → the Value cell of that Project Context row
ctx_row() {
  awk -F'|' -v l=" $2 " '$2 == l { gsub(/^ +| +$/, "", $3); print $3; exit }' "$1"
}

echo "=== R — the real render_intake_file, hermetic progress file ==="

PD="$(newtmp)/proj"
if ! mk_progress "$PD"; then
  fail_ "R setup" "could not build the fixture progress file"
else
  render "$PD"
  if [ "$RENDER_RC" -ne 0 ] || [ ! -f "$PD/PROJECT_INTAKE.md" ]; then
    fail_ "R0" "render_intake_file did not produce PROJECT_INTAKE.md (rc=$RENDER_RC)"
  else
    pass "R0 — render_intake_file produced PROJECT_INTAKE.md (rc=$RENDER_RC)"

    # R1 — THE CONTROL. The Answers table comes from a SECOND jq program
    # that never named a keyword, so this is true on main by construction.
    # A RED run without it could be a broken fixture rather than the defect.
    if grep -q "$ANS_VALUE" "$PD/PROJECT_INTAKE.md"; then
      pass "R1 (control) — the Answers table, rendered by a separate jq program, is intact"
    else
      fail_ "R1 (control)" "the recorded answer [$ANS_VALUE] is missing — the fixture, not the defect, is broken"
    fi

    # R2 — THE DISCRIMINATOR. With the keyword in place the whole program
    # fails to compile and this table has a header and no rows at all.
    got="$(ctx_row "$PD/PROJECT_INTAKE.md" "Project name")"
    if [ "$got" = "$CTX_NAME" ]; then
      pass "R2 — the Project Context table carries the project name BY VALUE"
    else
      fail_ "R2" "Project name row is [$got], want [$CTX_NAME] — the jq program did not compile"
    fi

    # R3 — a second context row, pinned by value, so a mutant that keeps
    # one row cannot pass the table off as rendered.
    got="$(ctx_row "$PD/PROJECT_INTAKE.md" "Description")"
    if [ "$got" = "$CTX_DESC" ]; then
      pass "R3 — and the Description row, also by value"
    else
      fail_ "R3" "Description row is [$got], want [$CTX_DESC]"
    fi

    # R4 — the row count. Nine `row(...)` calls, nine data rows.
    n="$(awk '/^### Project Context$/ { inctx = 1; next } /^### /  { inctx = 0 } inctx && /^\| / { c++ } END { print c + 0 }' "$PD/PROJECT_INTAKE.md")"
    if [ "$n" = "10" ]; then
      pass "R4 — the table carries its header plus all nine context rows"
    else
      fail_ "R4" "the Project Context table has $n \`| \`-led line(s), want 10 (header + nine rows)"
    fi

    # R5 — jq compiled silently. This is the operator-visible half: on main
    # every save_section printed a jq compile error under an [OK] banner.
    if [ ! -s "$PD/render.err" ]; then
      pass "R5 — render_intake_file wrote nothing to stderr"
    else
      fail_ "R5" "render_intake_file emitted stderr: $(head -1 "$PD/render.err")"
    fi
  fi
fi

echo "=== M — mutation proof on a mirror ==="

M_MARK="# BL-265-JQ-RESERVED"
n="$(grep -c "${M_MARK}\$" "$WIZARD" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
[ "$n" = "1" ] \
  && pass "M0 — '$M_MARK' occurs exactly once at end-of-line in intake-wizard.sh" \
  || fail_ "M0" "'$M_MARK' occurs $n times in intake-wizard.sh (need exactly 1)"

# MP1 — restore the reserved word on a mirror: R2 must go red again, and
# R1 must stay green (the second jq program is untouched), which is what
# proves R2 discriminates the defect rather than the fixture.
MP1="$(newtmp)/fw"
if ! mkdir -p "$MP1" || ! cp -Rp "$REPO_ROOT/scripts" "$MP1/"; then
  fail_ "MP1 setup" "could not mirror scripts/"
else
  tgt="$MP1/scripts/intake-wizard.sh"; before="$(mktemp)"; cp "$tgt" "$before"
  sed -e 's/def row(lbl; val): "| " + lbl + " | "/def row(label; val): "| " + label + " | "/' "$before" > "$tgt"
  if ! bash -n "$tgt" 2>/dev/null \
     || [ "$(grep -c 'def row(label; val)' "$tgt")" -ne 1 ] \
     || [ "$(grep -c 'def row(lbl; val)' "$tgt")" -ne 0 ] \
     || [ "$(_changed_lines "$before" "$tgt")" -ne 2 ]; then
    fail_ "MP1 setup" "the reserved-word mutation did not apply cleanly"
  else
    PD1="$(newtmp)/proj"
    if ! mk_progress "$PD1"; then
      fail_ "MP1 setup" "could not build the mutant's fixture"
    else
      render "$PD1" "$tgt"
      got="$(ctx_row "$PD1/PROJECT_INTAKE.md" "Project name")"
      ctl="$(grep -c "$ANS_VALUE" "$PD1/PROJECT_INTAKE.md" 2>/dev/null)"
      if [ "$got" != "$CTX_NAME" ] && [ "$ctl" -ge 1 ]; then
        pass "MP1 (MUTATION) — with \`label\` restored the Project Context table is EMPTY (name row [$got]) while the Answers table still renders: R2 is what stops it"
      else
        fail_ "MP1 (MUTATION)" "the reserved word changed nothing (name=[$got] answers=$ctl) — R2 may be passing for another reason"
      fi
    fi
  fi
fi

# MP2 — the table is pinned BY VALUE, not by shape. Point the project-name
# row at the description field instead: every row still renders, the row
# count is unchanged, and only a value assertion sees it.
MP2="$(newtmp)/fw"
if ! mkdir -p "$MP2" || ! cp -Rp "$REPO_ROOT/scripts" "$MP2/"; then
  fail_ "MP2 setup" "could not mirror scripts/"
else
  tgt2="$MP2/scripts/intake-wizard.sh"; before2="$(mktemp)"; cp "$tgt2" "$before2"
  if [ "$(grep -c '^      row("Project name"; \.project_name),$' "$before2")" -ne 1 ]; then
    fail_ "MP2 setup" "the project-name row is not a unique single line"
  else
    sed -e 's/^      row("Project name"; \.project_name),$/      row("Project name"; .description),/' "$before2" > "$tgt2"
    if ! bash -n "$tgt2" 2>/dev/null \
       || [ "$(grep -c '^      row("Project name"; \.description),$' "$tgt2")" -ne 1 ] \
       || [ "$(_changed_lines "$before2" "$tgt2")" -ne 2 ]; then
      fail_ "MP2 setup" "the wrong-field mutation did not apply cleanly"
    else
      PD2="$(newtmp)/proj"
      if ! mk_progress "$PD2"; then
        fail_ "MP2 setup" "could not build the mutant's fixture"
      else
        render "$PD2" "$tgt2"
        got="$(ctx_row "$PD2/PROJECT_INTAKE.md" "Project name")"
        n2="$(awk '/^### Project Context$/ { inctx = 1; next } /^### / { inctx = 0 } inctx && /^\| / { c++ } END { print c + 0 }' "$PD2/PROJECT_INTAKE.md")"
        if [ "$got" != "$CTX_NAME" ] && [ "$n2" = "10" ]; then
          pass "MP2 (MUTATION) — a row sourced from the wrong field still renders 10 lines but carries [$got]: R2 pins the VALUE, not the shape"
        else
          fail_ "MP2 (MUTATION)" "the wrong-field mutation was not caught by value (name=[$got] lines=$n2)"
        fi
      fi
    fi
  fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] && exit 0
exit 1
