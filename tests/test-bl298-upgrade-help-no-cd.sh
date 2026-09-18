#!/usr/bin/env bash
# tests/test-bl298-upgrade-help-no-cd.sh — BL-298.
#
# scripts/upgrade-project.sh ran _run_idempotent_backfill unconditionally, far
# above the `--- Help ---` block and further still above `--- Validate project
# root ---` — the block that already owned the right refusal. The function opens
# with `( cd "$PROJECT_ROOT"`, and find_project_root returns the EMPTY STRING
# when no .claude/phase-state.json is above cwd. (No line distances here either:
# this header was the one place the branch still carried what the entry said it
# had removed, and the numbers it carried were already two commits stale.)
#
# `cd ""` is version-split, and that decides which half of the defect shows.
# Measured: a silent no-op returning 0 on bash 3.2.57 and 5.2.21, an error
# ("null directory", rc 1) from 5.3 on. So the function either ran rooted at
# whatever cwd happened to be, or killed the script under `set -euo pipefail`.
#
# Three guards, three markers:
#   # BL-298-HELP-SKIPS-BACKFILL   — the call-site gate (C1, C2, C3, C5)
#   # BL-298-BACKFILL-ROOT-GUARD   — the refusal inside the function (C6, C7, C9)
#   # BL-298-HELP-BEATS-BACKFILL   — the --backfill-only short-circuit (C10)
#
# C4, C6a and C8 are controls: all three pass against the unfixed script in every
# environment, so their green in a RED run proves the fixtures reach the script
# rather than being broken. C1, C2, C3, C6b and C6c are VACUOUS below bash 5.3 —
# they pass against the unfixed script there. C5, C7, C9 and C10 discriminate on
# every version, and are what makes this suite gate on an ubuntu-24.04 runner
# today.
#
# SCOPE. These guards cover the two flag paths whose writes this entry measures.
# `--sync-framework --help` and `--plan --help` also swallow help and write, at
# `main` and here alike, from their own dispatch functions — a different
# mechanism, out of scope, measured and disclosed in the `## BL-298:` entry
# under "Not fixed here". Do not read a green run as covering them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="${SOLO_UPGRADE_SCRIPT:-$REPO_ROOT/scripts/upgrade-project.sh}"
# The SCRIPT's interpreter, not this suite's. `cd ""` is a silent no-op up to
# bash 5.2 and an error from 5.3, so which bash runs upgrade-project.sh decides
# what half of BL-298 is observable. Selectable so the split can be measured:
# SOLO_TEST_BASH=/bin/bash exercises 3.2.57 on this host. Running THIS FILE under
# a different bash proves nothing about that — the script has its own.
SH="${SOLO_TEST_BASH:-bash}"

echo "== tests/test-bl298-upgrade-help-no-cd.sh =="

PASSED=0
FAILED=0
pass() { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }

# bash's own diagnostic for a failed `cd`, in either spelling it can take.
CD_DIAG=': cd: '

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

WORK="$(mktemp -d)"
EMPTY_DIR="$WORK/projectless"
mkdir -p "$EMPTY_DIR"

# A generated-project fixture: enough manifest/phase-state for the backfill to
# have real work to do, so C5 can tell "skipped" from "ran and changed nothing".
PROJ="$WORK/proj"
setup_project() {
  rm -rf "$PROJ"
  mkdir -p "$PROJ/.claude"
  (
    cd "$PROJ"
    unset GITHUB_BASE_REF
    git init -q
    git remote add origin https://github.com/example/foo.git
    cat > .claude/manifest.json <<'JSON'
{"frameworkVersion":"test","mode":"personal"}
JSON
    cat > .claude/phase-state.json <<'JSON'
{"track":"light","deployment":"personal","current_phase":1,"phases":{}}
JSON
  )
}

# Content fingerprint of the fixture, .git excluded — names plus per-file cksum,
# so a new file, a deleted file or an edited byte all move it.
fingerprint() {
  (
    cd "$1"
    find . -type f ! -path './.git/*' | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s ' "$f"
      cksum < "$f"
    done
  )
}

# ────────────────────────────────────────────────────────────────────
# C1/C2/C3 — --help from a directory with no project above it
# ────────────────────────────────────────────────────────────────────
c1_c2_c3_help_outside_project() {
  local out rc=0
  out=$( cd "$EMPTY_DIR" && "$SH" "$SCRIPT" --help </dev/null 2>&1 ) || rc=$?

  if [ "$rc" -eq 0 ]; then
    pass "C1: --help exits 0 outside a project (rc=$rc)"
  else
    fail_ "C1" "--help must exit 0 outside a project; rc=$rc, output:\n$out"
  fi

  if echo "$out" | grep -q 'Solo Orchestrator — Project Upgrade'; then
    pass "C2: --help prints its usage heading outside a project"
  else
    fail_ "C2" "--help printed no usage heading; output:\n$out"
  fi

  if echo "$out" | grep -qF "$CD_DIAG"; then
    fail_ "C3" "--help emitted a bash cd diagnostic; output:\n$out"
  else
    pass "C3: --help emits no bash 'cd:' diagnostic outside a project"
  fi
}

# ────────────────────────────────────────────────────────────────────
# C4 — CONTROL. --help from INSIDE a project already exits 0 at the parent
# commit (PROJECT_ROOT is non-empty there, so the cd succeeds). It must keep
# doing so: this is the arm the call-site gate could break.
# ────────────────────────────────────────────────────────────────────
c4_help_inside_project_still_exits_zero() {
  local out rc=0
  setup_project
  out=$( cd "$PROJ" && "$SH" "$SCRIPT" --help </dev/null 2>&1 ) || rc=$?

  if [ "$rc" -eq 0 ] && echo "$out" | grep -q 'Solo Orchestrator — Project Upgrade'; then
    pass "C4 (control): --help inside a project exits 0 and prints help"
  else
    fail_ "C4" "--help inside a project must still exit 0 with help; rc=$rc, output:\n$out"
  fi
}

# ────────────────────────────────────────────────────────────────────
# C5 — --help touches no directory. At the parent commit the backfill RAN on
# this fixture and wrote to it; --help is a read-only flag and must not.
# ────────────────────────────────────────────────────────────────────
c5_help_mutates_nothing() {
  local before after rc=0
  setup_project
  before="$(fingerprint "$PROJ")"
  ( cd "$PROJ" && "$SH" "$SCRIPT" --help </dev/null >/dev/null 2>&1 ) || rc=$?
  after="$(fingerprint "$PROJ")"

  if [ "$before" = "$after" ]; then
    pass "C5: --help leaves the project tree byte-identical"
  else
    fail_ "C5" "--help mutated the project tree; diff:\n$(diff <(echo "$before") <(echo "$after") || true)"
  fi
}

# ────────────────────────────────────────────────────────────────────
# C6 — the backfill refuses an empty PROJECT_ROOT by NAME, on the ordinary
# upgrade path. This is the message edge-cases-scripts.sh E18 asserts on.
# ────────────────────────────────────────────────────────────────────
c6_track_outside_project_refuses_by_name() {
  local out rc=0
  out=$( cd "$EMPTY_DIR" && "$SH" "$SCRIPT" --track standard </dev/null 2>&1 ) || rc=$?

  if [ "$rc" -eq 1 ]; then
    pass "C6a: --track standard outside a project exits 1, the canonical refusal code (rc=$rc)"
  else
    fail_ "C6a" "--track standard outside a project must exit 1; output:\n$out"
  fi

  # BOTH lines the refusal owes, each WITH ITS SEVERITY. Pinning only the first
  # leaves the remediation line deletable in silence; pinning the text without
  # the `[FAIL]` prefix leaves `print_fail` swappable for `print_info`, which
  # still exits 1 but softens a refusal into a note — the messaging standard's
  # "never soften a block", and a mutant that survived a review at 12/0.
  # The labels are safe to match joined: helpers-core.sh gates its colours on
  # `[ -t 1 ]`, and no case here gives the script a tty — every one captures
  # through a command substitution or discards to /dev/null — so RED and NC are
  # empty and `[FAIL] ` is contiguous with the message.
  # -qxF, not -qF: a substring match still passes when the line is APPENDED to
  # ("… project found. This is only a note."), which is the same softening the
  # severity prefix is here to prevent. Whole-line or it is not pinned.
  if echo "$out" | grep -qxF '[FAIL] No Solo Orchestrator project found.' \
     && echo "$out" | grep -qxF '[INFO] Run this script from your project directory (where .claude/phase-state.json lives).'; then
    pass "C6b: the refusal names the condition and the remedy, each at its own severity"
  else
    fail_ "C6b" "expected both refusal lines with their [FAIL]/[INFO] severities; output:\n$out"
  fi

  if echo "$out" | grep -qF "$CD_DIAG"; then
    fail_ "C6c" "bash's cd diagnostic stood in for the refusal; output:\n$out"
  else
    pass "C6c: no bash 'cd:' diagnostic on the --track path"
  fi
}

# ────────────────────────────────────────────────────────────────────
# C7 — the same guard on the other path that reaches it, --backfill-only.
# ────────────────────────────────────────────────────────────────────
c7_backfill_only_outside_project_refuses_by_name() {
  local out rc=0
  out=$( cd "$EMPTY_DIR" && "$SH" "$SCRIPT" --backfill-only </dev/null 2>&1 ) || rc=$?

  if [ "$rc" -eq 1 ] \
     && echo "$out" | grep -qF 'No Solo Orchestrator project found.' \
     && ! echo "$out" | grep -qF "$CD_DIAG"; then
    pass "C7: --backfill-only outside a project refuses by name, no cd diagnostic"
  else
    fail_ "C7" "--backfill-only must refuse by name; rc=$rc, output:\n$out"
  fi
}

# ────────────────────────────────────────────────────────────────────
# C9 — PROJECT_ROOT non-empty and NOT a directory. `find_project_root` echoes
# its answer through a command substitution, which strips trailing newlines, so
# a project directory whose name ENDS IN A NEWLINE yields a PROJECT_ROOT one
# byte short of the real path. Put an ordinary FILE at that shortened path and
# the guard's predicate is pinned three ways at once: `-n` and `-e` both admit
# it and then fail in the `cd`, only `-d` refuses. Reachable on every bash, so
# this case is the one that is not vacuous anywhere.
# ────────────────────────────────────────────────────────────────────
c9_root_that_is_not_a_directory() {
  local out rc=0 base nl_dir shadow
  base="$WORK/nl"
  rm -rf "$base"; mkdir -p "$base"
  # $'\n' and not $(printf '\n'): a command substitution strips the very
  # trailing newline this fixture is built out of.
  nl_dir="$base/weird"$'\n'
  shadow="$base/weird"
  mkdir -p "$nl_dir/.claude" || { fail_ "C9" "could not create a newline-named directory on this filesystem"; return; }
  printf '%s\n' '{"track":"light","deployment":"personal","current_phase":1,"phases":{}}' > "$nl_dir/.claude/phase-state.json" \
    || { fail_ "C9" "could not seed the newline-named project"; return; }
  printf 'not a directory\n' > "$shadow" \
    || { fail_ "C9" "could not create the shadow file at the truncated path"; return; }

  # Confirm the fixture really does produce the condition before asserting on it.
  if [ -d "$shadow" ] || [ ! -e "$shadow" ]; then
    fail_ "C9" "fixture did not produce a non-directory at the truncated path"
    return
  fi

  out=$( cd "$nl_dir" && "$SH" "$SCRIPT" --track standard </dev/null 2>&1 ) || rc=$?

  if [ "$rc" -eq 1 ] \
     && echo "$out" | grep -qF 'No Solo Orchestrator project found.' \
     && ! echo "$out" | grep -qF "$CD_DIAG"; then
    pass "C9: a PROJECT_ROOT that exists but is not a directory is refused by name"
  else
    fail_ "C9" "expected the named refusal for a non-directory root; rc=$rc, output:\n$out"
  fi
}

# ────────────────────────────────────────────────────────────────────
# C10 — --help combined with another flag is still --help. `--backfill-only
# --help` skipped the backfill via the call-site gate and then fell into the
# --backfill-only short-circuit, which refreshes CDF assets and exits 0 without
# printing a line of help. Pins `# BL-298-HELP-BEATS-BACKFILL`: help text, exit
# 0, and a byte-identical project tree.
# ────────────────────────────────────────────────────────────────────
c10_backfill_only_plus_help_is_help() {
  local out rc=0 before after
  setup_project
  before="$(fingerprint "$PROJ")"
  out=$( cd "$PROJ" && "$SH" "$SCRIPT" --backfill-only --help </dev/null 2>&1 ) || rc=$?
  after="$(fingerprint "$PROJ")"

  if [ "$rc" -eq 0 ] \
     && echo "$out" | grep -q 'Solo Orchestrator — Project Upgrade' \
     && [ "$before" = "$after" ]; then
    pass "C10: --backfill-only --help prints help, exits 0, writes nothing"
  else
    fail_ "C10" "rc=$rc; tree changed: $([ "$before" = "$after" ] && echo no || echo yes); output:\n$out"
  fi
}

# ────────────────────────────────────────────────────────────────────
# C8 — CONTROL. --validate-only exits before the backfill at the parent commit
# and must keep doing so. Green here in a RED run is what proves the harness
# reaches the script at all.
# ────────────────────────────────────────────────────────────────────
c8_validate_only_unaffected() {
  local out rc=0
  out=$( cd "$EMPTY_DIR" && "$SH" "$SCRIPT" --validate-only --track standard </dev/null 2>&1 ) || rc=$?

  if [ "$rc" -eq 0 ] && echo "$out" | grep -q '"validate_only": true'; then
    pass "C8 (control): --validate-only still exits 0 with resolved JSON"
  else
    fail_ "C8" "--validate-only must be unaffected; rc=$rc, output:\n$out"
  fi
}

c1_c2_c3_help_outside_project
c4_help_inside_project_still_exits_zero
c5_help_mutates_nothing
c6_track_outside_project_refuses_by_name
c7_backfill_only_outside_project_refuses_by_name
c9_root_that_is_not_a_directory
c10_backfill_only_plus_help_is_help
c8_validate_only_unaffected

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
