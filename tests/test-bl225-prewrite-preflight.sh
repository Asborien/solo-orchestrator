#!/usr/bin/env bash
# tests/test-bl225-prewrite-preflight.sh
#
# `## BL-225:` — THE BEFORE-ANY-WRITE HALF.
#
# `# BL-225-STAGE-PREFLIGHT` protects the INDEX: it asks `git add --dry-run`
# before staging and stops whole. By the time it runs ~78 files are already on
# disk, and the entry says so in as many words: "The index is protected; the
# disk is not." This suite is the other half — a refusal that arrives before
# the FIRST write, so a project whose `.gitignore` refuses one of the files the
# adoption must write is left byte-identical instead of half-installed.
#
# THE DESIGN UNDER TEST. `_adopt_write_phase` is the only writer of the
# adoptee's files and is called twice: once by `adopt_prewrite_preflight`
# against a COPY of the tree, once for real. The planned path set is therefore
# not a maintained list that can drift behind the writers — it is what the
# writers produced on a rehearsal.
#
# WHAT IS STUBBED AND WHY. T1-T5 replace `_adopt_write_phase` with a stub that
# records a known path set. That is deliberate: these cases are about the
# DECISION (which oracle, what it refuses, what it leaves behind), and a real
# write phase needs a Scout report, a framework clone and an answered intake —
# fidelity the adoption e2e suites already cover. T6 closes the gap the stub
# opens, structurally: the preflight must be CALLED before the real phase.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/adopt"
STATE="$LIB/adopt-state.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bl225pw.XXXXXX")" || exit 1
case "$WORK" in "$REPO_ROOT"*) echo "FATAL: fixture inside repo"; exit 1 ;; esac
trap 'rm -rf "$WORK"' EXIT INT TERM
# A global excludes file carrying `.claude/` would make every adoptee look
# ignored; GIT_CONFIG_GLOBAL does not cover it, so neutralise the PATH default.
export XDG_CONFIG_HOME="$WORK/xdg"; mkdir -p "$XDG_CONFIG_HOME"
export HOME="$WORK/home"; mkdir -p "$HOME"

[ -f "$STATE" ] || { echo "  [FAIL] setup — $STATE not found"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }

# _adoptee DIR [ignore-line...] — a real git repo with their own history
_adoptee() {
  local d="$1"; shift
  mkdir -p "$d" && ( cd "$d" \
    && git init -q -b main . \
    && git config user.email t@example.com && git config user.name T \
    && printf 'their code\n' > README.md \
    && { [ "$#" -eq 0 ] || printf '%s\n' "$@" > .gitignore; } \
    && git add -A && git commit -q -m 'chore: their history' ) || return 1
}
# _hash DIR — a content hash of the whole tree, .git included, so "unchanged"
# means unchanged rather than "no file I thought to check".
_hash() { ( cd "$1" && find . -type f -exec cksum {} \; 2>/dev/null | LC_ALL=C sort | cksum ); }

# _run DIR PLANNED... -> "rc|err" with _adopt_write_phase stubbed to record PLANNED
_run() {
  local d="$1"; shift
  ( set +e
    ADOPT_PROJECT_NAME=t
    . "$LIB/adopt-core.sh"  >/dev/null 2>&1
    . "$STATE"              >/dev/null 2>&1
    ADOPT_WORK="$WORK/w.$$"; mkdir -p "$ADOPT_WORK"
    adopt_ledger_init "$ADOPT_WORK/written" >/dev/null 2>&1
    REAL_LEDGER="$ADOPT_WRITTEN_LEDGER"
    _planned="$*"
    # The stub is the rehearsal's write phase: it records into whatever ledger
    # the preflight pointed it at, exactly as the real writers do.
    _adopt_write_phase() {
      local p
      for p in $_planned; do adopt_record_write "$p"; done
      return 0
    }
    err=$(adopt_prewrite_preflight "$d" "" 2>&1 >/dev/null); rc=$?
    printf '%s|%s|%s|%s\n' "$rc" "$(printf '%s' "$err" | tr '\n' ' ')" \
      "$([ "$ADOPT_WRITTEN_LEDGER" = "$REAL_LEDGER" ] && echo restored || echo LOST)" \
      "$([ -e "$ADOPT_WORK/rehearsal" ] && echo residue || echo clean)" )
}

echo "=== T — the refusal arrives before the first write ==="

# T1 — THE DISCRIMINATOR. Their .gitignore hides .claude/, which is where the
# adoption's own state lives. Today ~78 files land before anything notices.
P1="$WORK/t1"; _adoptee "$P1" '.claude/'
H1="$(_hash "$P1")"
IFS='|' read -r rc1 err1 led1 res1 <<<"$(_run "$P1" '.claude/manifest.json' 'PROJECT_INTAKE.md')"
chk "T1: refuses (rc != 0)"                         "$([ "${rc1:-0}" -ne 0 ] && echo yes || echo no)" "yes"
chk "T1: names the refused path"                    "$(printf '%s' "$err1" | grep -c 'manifest.json')" "1"
chk "T1: says nothing was written"                  "$(printf '%s' "$err1" | grep -ci 'NOTHING WAS WRITTEN')" "1"
chk "T1: and the project is BYTE-IDENTICAL"         "$(_hash "$P1")" "$H1"

# T2 — the control: a project with no rule in the way is allowed through, and
# the rehearsal still leaves it untouched.
P2="$WORK/t2"; _adoptee "$P2"
H2="$(_hash "$P2")"
IFS='|' read -r rc2 err2 led2 res2 <<<"$(_run "$P2" '.claude/manifest.json' 'PROJECT_INTAKE.md')"
chk "T2: allows a project with no rule in the way"  "${rc2:-x}" "0"
chk "T2: and left it BYTE-IDENTICAL too"            "$(_hash "$P2")" "$H2"

# T3 — the rehearsal copy is removed. A copy of someone's whole repository
# left behind under /tmp is a disclosure of their code, not just litter.
chk "T3: the rehearsal copy is deleted (refused run)" "${res1:-x}" "clean"
chk "T3: the rehearsal copy is deleted (allowed run)" "${res2:-x}" "clean"

# T4 — the ledger is global. If the rehearsal's ledger leaked into the real run,
# the commit would stage files the real run never wrote.
chk "T4: the real ledger is restored (refused run)" "${led1:-x}" "restored"
chk "T4: the real ledger is restored (allowed run)" "${led2:-x}" "restored"

# T5 — NEGATION, both halves, because git treats them differently and a first
# draft of this case asserted the wrong one. gitignore(5): "It is not possible
# to re-include a file if a parent directory of that file is excluded." So:
#   a) '.claude/' + '!.claude/manifest.json'  -> STILL ignored. Refusing is
#      correct, and matches what `git add` would do.
#   b) '*.json'   + '!manifest.json'          -> re-included. Allowing is
#      correct, and a naive "is any parent ignored" test would get this wrong.
P5a="$WORK/t5a"; _adoptee "$P5a" '.claude/' '!.claude/manifest.json'
IFS='|' read -r rc5a _ _ _ <<<"$(_run "$P5a" '.claude/manifest.json')"
chk "T5a: '!' under an ignored DIRECTORY does not re-include — still refused" \
  "$([ "${rc5a:-0}" -ne 0 ] && echo yes || echo no)" "yes"
P5b="$WORK/t5b"; _adoptee "$P5b" '*.json' '!manifest.json'
IFS='|' read -r rc5b _ _ _ <<<"$(_run "$P5b" 'manifest.json')"
chk "T5b: a genuinely re-included path is allowed (negation is honoured)" "${rc5b:-x}" "0"

echo "=== E — the REAL driver, un-stubbed ==="

# T1-T5 stub `_adopt_write_phase`, and that stub is a hole the review found:
# a rehearsal pointed at "$root" instead of "$copy" — the original defect with a
# lie on top — passed all 20 cases, because a stub that writes nowhere cannot
# make a byte-identical assertion fail. So run the REAL driver once. This case
# is the one that kills:
#   - pointing the rehearsal at the project instead of the copy
#   - moving `adopt_test_debt_record` back above the preflight (a file lands,
#     and the refusal's "nothing was written" becomes false)
#   - dropping `# BL-225-REHEARSAL-NO-TRACE` (the tree stays clean but the
#     refusal claims adoption ATTEMPTED writes to the project)
# It needs a Scout report, so it SKIPS LOUDLY rather than silently if scout
# cannot produce one — a skipped case that reads as a pass is how the stub hole
# stayed open.
E_ROOT="$WORK/e2e"; E_P="$E_ROOT/p"; mkdir -p "$E_ROOT"
mkdir -p "$E_P/src" && ( cd "$E_P" && git init -q . \
  && git config user.email e@test.invalid && git config user.name E \
  && printf '{"name":"acme","scripts":{"test":"npm test"}}\n' > package.json \
  && printf '# acme\n' > README.md \
  && printf '.claude/\n' > .gitignore \
  && git add -A && git commit -q -m 'chore: their history' ) >/dev/null 2>&1
if ! bash "$REPO_ROOT/scripts/scout.sh" --root "$E_P" --out "$E_ROOT/scan" >/dev/null 2>&1 \
   || [ ! -s "$E_ROOT/scan/scout-report.json" ]; then
  bad "E setup — scripts/scout.sh produced no report; the end-to-end case cannot run, and is NOT silently skipped"
else
  E_HASH_BEFORE="$(_hash "$E_P")"
  # ENOUGH ANSWERS TO REACH THE PREFLIGHT, AND A LOUD FAILURE IF WE DO NOT.
  # A fixed 5-line stream underran the intake on a host without node/npm: the
  # driver stopped at "Tooling Configuration ... no answer was given" BEFORE the
  # preflight, so E1-E3 passed VACUOUSLY (nothing ran, so nothing was written)
  # and E4/E5 read the intake abort's message instead of the preflight's.
  # Measured in `ubuntu:24.04`: 23/2 there against 25/0 on this Mac, for a
  # fixture difference and not a product difference. E0 below is the guard: if
  # the run did not reach the preflight, say so instead of asserting anything.
  { printf '2\n'; i=0; while [ "$i" -lt 40 ]; do printf '1\n'; i=$((i + 1)); done; } > "$E_ROOT/answers"
  E_ERR="$E_ROOT/err"
  ( cd "$E_P" && bash "$REPO_ROOT/scripts/adopt-project.sh" \
      --scan-report "$E_ROOT/scan/scout-report.json" ) < "$E_ROOT/answers" >/dev/null 2>"$E_ERR"
  E_RC=$?
  E_DIRTY="$( cd "$E_P" && git status --porcelain --ignored --untracked-files=all 2>/dev/null | grep -c . )"
  # E0 — the run must have reached the PREFLIGHT. Without this every assertion
  # below is satisfied by a driver that stopped earlier for an unrelated reason.
  chk "E0 — the run reached the pre-write preflight (not an earlier abort)" \
    "$(grep -c 'your ignore rules refuse' "$E_ERR")" "1"
  chk "E1 — the real driver REFUSES an adoptee whose rules hide .claude/" \
    "$([ "$E_RC" -ne 0 ] && echo yes || echo no)" "yes"
  chk "E2 — and the project is BYTE-IDENTICAL afterwards (real writers, no stub)" \
    "$(_hash "$E_P")" "$E_HASH_BEFORE"
  chk "E3 — not one file, tracked, untracked or ignored, was left behind" "$E_DIRTY" "0"
  # The refusal must be REFUSED (nothing touched), never BLOCKED (something was).
  chk "E4 — the refusal is labelled REFUSED, so it does not claim writes it did not make" \
    "$(grep -c '\[REFUSED\]' "$E_ERR")" "1"
  chk "E5 — and never says adoption ATTEMPTED writes to this project" \
    "$(grep -ci 'ATTEMPTED writes' "$E_ERR")" "0"
fi

echo "=== S — the call is before the write, structurally ==="

# T6 — the stub in T1-T5 cannot prove ORDER. This does: in adopt_main the
# preflight's marked call must precede the real write phase's marked call.
_ln() { grep -n "$1" "$STATE" | head -1 | cut -d: -f1; }
pre_ln="$(_ln 'BL-225-PREWRITE-CALL$')"; wr_ln="$(_ln 'BL-225-WRITE-PHASE-REAL$')"
chk "T6: both marked calls exist" \
  "$([ -n "$pre_ln" ] && [ -n "$wr_ln" ] && echo yes || echo no)" "yes"
chk "T6: the preflight is called BEFORE the write phase" \
  "$([ -n "$pre_ln" ] && [ -n "$wr_ln" ] && [ "$pre_ln" -lt "$wr_ln" ] && echo yes || echo no)" "yes"

# T7 — one write phase, not two. The anti-drift claim is that the rehearsal and
# the real run share a writer; two definitions would defeat it.
chk "T7: _adopt_write_phase is defined exactly once" \
  "$(grep -c '^_adopt_write_phase() {' "$STATE")" "1"
chk "T7: and the archive/install/state writers live only inside it" \
  "$(grep -c '^  adopt_archive_write "\$root" "\$work"' "$STATE")" "1"

echo "=== M — markers and a mutation proof ==="

for m in 'BL-225-PREWRITE-CALL' 'BL-225-WRITE-PHASE-REAL' 'BL-225-PREWRITE-REFUSE'; do
  n="$(grep -c "# ${m}\$" "$STATE")"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
  chk "M0: '# $m' occurs exactly once at end-of-line" "$n" "1"
done

# MP1 — delete the check-ignore arm on a mirror: T1 must stop refusing. Without
# this, T1 passes for any reason at all, including a preflight that refuses
# every project.
#
# The mutation is awk, not python3: the runner has python3 and a bare
# `ubuntu:24.04` does not, and this suite must give the same verdict on both.
# It rewrites a TWO-LINE anchor, so the edit cannot be a one-line sed; and it
# asserts the anchor was unique AND that the replacement LANDED, because "the
# mutator ran" is not "the mutant mutates".
MP="$WORK/mp/lib"; mkdir -p "$MP" && cp -p "$LIB"/*.sh "$MP/"
mp_anchor='      0) ignored="$ignored'
mp_n="$(grep -cF "$mp_anchor" "$MP/adopt-state.sh")"; case "$mp_n" in ''|*[!0-9]*) mp_n=0 ;; esac
awk -v anchor="$mp_anchor" '
  $0 == anchor { print "      0) : ;;"; skip = 1; next }
  skip == 1    { skip = 0; next }
  { print }
' "$MP/adopt-state.sh" > "$MP/adopt-state.sh.mut" && mv "$MP/adopt-state.sh.mut" "$MP/adopt-state.sh"
mp_left="$(grep -cF "$mp_anchor" "$MP/adopt-state.sh")"; case "$mp_left" in ''|*[!0-9]*) mp_left=0 ;; esac
mp_new="$(grep -c '^      0) : ;;$' "$MP/adopt-state.sh")"; case "$mp_new" in ''|*[!0-9]*) mp_new=0 ;; esac
if [ "$mp_n" -ne 1 ] || [ "$mp_left" -ne 0 ] || [ "$mp_new" -ne 1 ] \
   || ! bash -n "$MP/adopt-state.sh" 2>/dev/null; then
  bad "MP1 setup: the mutation did not apply cleanly (anchors=$mp_n left=$mp_left new=$mp_new)"
else
  P9="$WORK/t9"; _adoptee "$P9" '.claude/'
  mp_rc=$( set +e
    ADOPT_PROJECT_NAME=t
    . "$MP/adopt-core.sh"  >/dev/null 2>&1
    . "$MP/adopt-state.sh" >/dev/null 2>&1
    ADOPT_WORK="$WORK/w.mp"; mkdir -p "$ADOPT_WORK"
    adopt_ledger_init "$ADOPT_WORK/written" >/dev/null 2>&1
    _adopt_write_phase() { adopt_record_write '.claude/manifest.json'; return 0; }
    adopt_prewrite_preflight "$P9" "" >/dev/null 2>&1; echo $? )
  chk "MP1 (MUTATION): without the oracle the ignored project is ALLOWED — T1 is what stops it" \
    "${mp_rc:-x}" "0"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0
exit 1
