#!/usr/bin/env bash
# tests/test-bl270-mode-vocabulary-backfill.sh
#
# `## BL-270:` — A PROJECT ADOPTED BEFORE `## BL-268:` CARRIES A `mode` NO
# READER UNDERSTANDS, AND NOTHING REPAIRED IT.
#
# The manifest carries two tier fields with two vocabularies: `mode` is
# personal|org, `deployment` is personal|organizational. Adoption's writer fed
# ONE value to both, so an organizational adoptee was born `mode:
# "organizational"`. Every reader of `mode` hands it to
# host_verify_protection, whose org-only branch-protection rules are gated on
# the literal "org" — so those projects had the required-approving-review and
# required-status-check assertions skipped and were told they passed.
#
# BL-268 fixes the birth path and makes the drivers refuse an unknown mode.
# Neither touches a project already on disk, and together they turn a silent
# false pass into a permanent hard refusal: adoption cannot be re-run
# (`_adopt_preflight_adopted` refuses on two witnesses) and the manifest is
# config-guard protected. This is the repair, and it is a migration entry in
# `_run_idempotent_backfill` beside the host and BL-030 backfills — reached by
# the `--backfill-only` entry point that already exists.
#
# TOOL DEPENDENCIES: jq and git, both asserted at startup as HARD failures.
# python3 is a pre-existing hard dependency of upgrade-project.sh (followup
# F-012); this suite drives only the backfill subshell and does not need it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE="$REPO_ROOT/scripts/upgrade-project.sh"
GH_DRIVER="$REPO_ROOT/scripts/host-drivers/github.sh"

PASSED=0
FAILED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }

TOPTMP="$(mktemp -d)"
trap 'rm -rf "$TOPTMP"' EXIT INT TERM
newtmp() { mktemp -d "$TOPTMP/fixXXXXXX"; }
_changed() { local n; n=$(diff "$1" "$2" 2>/dev/null | grep -c '^[<>]'); case "$n" in ''|*[!0-9]*) n=0 ;; esac; printf '%s\n' "$n"; }

_bail() { echo "  [FAIL] setup — $1"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }
[ -f "$UPGRADE" ] || _bail "$UPGRADE not found"
command -v jq  >/dev/null 2>&1 || _bail "jq is required (the backfill reads and writes the manifest through it)"
command -v git >/dev/null 2>&1 || _bail "git is required (the fixture is a git repo)"

MANIFEST=".claude/manifest.json"

# ── The fixture ───────────────────────────────────────────────────────────
# The block under test lives inside `_run_idempotent_backfill`'s
# `( cd "$PROJECT_ROOT" … )` subshell. Driving the whole script would drag in
# its arg parser, sentinel guard and source-dir checks; this extracts the
# FUNCTION from the real file and runs it against a fixture project, so the
# code under test is the shipped code and nothing is re-implemented.
#
# EXTRACTION IS ASSERTED, not assumed: if the function cannot be found or does
# not parse, every case below would pass against an empty shell.
extract_backfill() {
  local out="$1"
  awk '/^_run_idempotent_backfill\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$UPGRADE" > "$out"
  [ -s "$out" ] || return 1
  grep -q '^_run_idempotent_backfill() {$' "$out" || return 1
  bash -n "$out" 2>/dev/null || return 1
  return 0
}

# mk_proj <dir> <mode> <deployment> [phase_state_deployment]
mk_proj() {
  local d="$1" mode="$2" dep="$3" psdep="${4:-$3}"
  mkdir -p "$d/.claude" || return 1
  if [ "$mode" = "--no-mode" ]; then
    cat > "$d/$MANIFEST" <<JSON
{ "host": "github", "remote_url": "", "deployment": "$dep",
  "poc_mode": null, "enforcement_level": "strict" }
JSON
  else
    cat > "$d/$MANIFEST" <<JSON
{ "host": "github", "mode": "$mode", "remote_url": "", "deployment": "$dep",
  "poc_mode": null, "enforcement_level": "strict" }
JSON
  fi
  if [ "$psdep" != "--no-phase-state" ]; then
    cat > "$d/.claude/phase-state.json" <<JSON
{ "project": "BL270Proj", "framework_version": "1.0", "current_phase": 2,
  "track": "full", "deployment": "$psdep", "poc_mode": null }
JSON
  fi
  ( cd "$d" && git init -q . ) >/dev/null 2>&1 || return 1
  jq empty "$d/$MANIFEST" 2>/dev/null || return 1
  return 0
}

# run_backfill <dir> [extracted-fn-file] → BF_OUT, BF_RC
run_backfill() {
  local d="$1" fn="${2:-$BACKFILL_FN}"
  # THE REDIRECTION IS ON THE COMMAND, AND THAT IS LOAD-BEARING. A first cut
  # wrote `2>&1` on its own line before the closing paren, where it is a NULL
  # COMMAND rather than a redirection — and being last, its status is what `$?`
  # captures. `BF_RC` was therefore ALWAYS 0, so every `[ "$BF_RC" -eq 0 ]`
  # below could not fail for any reason inside the function, including B0,
  # which is LABELLED a reachability control and claims to observe rc=0.
  # Measured: `f7() { return 7; }` in that shape yields 0; on the command, 7.
  # A check that cannot run must not pass.
  #
  # `set -e` matches production. `_run_idempotent_backfill` runs under
  # upgrade-project.sh's `set -euo pipefail`, and this harness ran it under
  # `-uo` only — so an early errexit abort inside the block would have been
  # invisible here while being fatal in the real script.
  BF_OUT="$(
    set -euo pipefail
    cd "$d" || exit 90
    PROJECT_ROOT="$d"
    SCRIPT_DIR="$REPO_ROOT/scripts"
    ORCHESTRATOR_ROOT="$REPO_ROOT"
    # shellcheck source=/dev/null
    . "$REPO_ROOT/scripts/lib/helpers.sh" >/dev/null 2>&1 || exit 91
    # shellcheck source=/dev/null
    . "$fn" || exit 92
    _run_idempotent_backfill 2>&1
  )"
  BF_RC=$?
  return 0
}

mval() { jq -r --arg k "$2" '.[$k] // "<<ABSENT>>"' "$1/$MANIFEST" 2>/dev/null; }

BACKFILL_FN="$(newtmp)/backfill.sh"
if ! extract_backfill "$BACKFILL_FN"; then
  _bail "could not extract a parseable _run_idempotent_backfill from $UPGRADE — every case below would pass against an empty shell"
fi

echo "=== B — the real _run_idempotent_backfill ==="

# B0 (CONTROL) — REACHABILITY. Before asserting anything about the new block,
# prove the harness reaches the function and it completes on a project that
# needs no repair. Without this a red below could be a broken fixture.
P0="$(newtmp)/p"
if ! mk_proj "$P0" personal personal; then
  fail_ "B0 (control) setup" "could not build the fixture"
else
  run_backfill "$P0"
  if [ "$BF_RC" -eq 0 ] && [ "$(mval "$P0" mode)" = "personal" ]; then
    pass "B0 (control) — the backfill runs to completion on an unaffected project (rc=$BF_RC), mode untouched"
  else
    fail_ "B0 (control)" "rc=$BF_RC mode=[$(mval "$P0" mode)] — the fixture, not the defect, is broken: $(printf '%s' "$BF_OUT" | tail -2 | tr '\n' ' ')"
  fi
fi

# B1 — THE DISCRIMINATOR.
P1="$(newtmp)/p"
if ! mk_proj "$P1" organizational organizational; then
  fail_ "B1 setup" "could not build the stranded fixture"
else
  run_backfill "$P1"
  if [ "$BF_RC" -eq 0 ] && [ "$(mval "$P1" mode)" = "org" ]; then
    pass "B1 — a stranded adoptee is repaired to mode=org (rc=$BF_RC)"
  else
    fail_ "B1" "rc=$BF_RC mode=[$(mval "$P1" mode)], want org: $(printf '%s' "$BF_OUT" | tail -2 | tr '\n' ' ')"
  fi

  # B2 — deployment must NOT move. It was already right, and a repair that
  # "translates" it recreates the defect in the other field. True at base
  # (the block does not run there), so a control at base and a discriminator
  # under MP3 — said, not counted as a red.
  if [ "$(mval "$P1" deployment)" = "organizational" ]; then
    pass "B2 (control at base) — deployment stays [organizational]; only mode moved"
  else
    fail_ "B2" "deployment is [$(mval "$P1" deployment)], want organizational — the translation leaked"
  fi

  # B3 — idempotent, by the same standard as its neighbours.
  before="$(newtmp)/m"; cp "$P1/$MANIFEST" "$before"
  run_backfill "$P1"
  if [ "$BF_RC" -eq 0 ] && [ "$(_changed "$before" "$P1/$MANIFEST")" -eq 0 ]; then
    pass "B3 — a second run is a byte no-op on the manifest (rc=$BF_RC)"
  else
    fail_ "B3" "rc=$BF_RC, manifest changed on the second run ($(_changed "$before" "$P1/$MANIFEST") line(s))"
  fi
fi

# B4 (CONTROL) — an ABSENT mode is left alone. The two manifest-field siblings
# key on absence; this block must not steal their input.
P4="$(newtmp)/p"
if ! mk_proj "$P4" --no-mode organizational; then
  fail_ "B4 (control) setup" "could not build the fixture"
else
  run_backfill "$P4"
  if [ "$(mval "$P4" mode)" = "<<ABSENT>>" ]; then
    pass "B4 (control) — an ABSENT mode is untouched: this block repairs present-and-invalid only"
  else
    fail_ "B4 (control)" "mode became [$(mval "$P4" mode)]; an absent field belongs to the sibling backfills"
  fi
fi

# B5 — the contradiction refusal. With the records in conflict there is no
# correct mode to derive.
P5="$(newtmp)/p"
if ! mk_proj "$P5" organizational organizational personal; then
  fail_ "B5 setup" "could not build the disagreeing fixture"
else
  run_backfill "$P5"
  if [ "$(mval "$P5" mode)" = "organizational" ] \
     && printf '%s' "$BF_OUT" | grep -q "disagree about deployment"; then
    pass "B5 — a manifest/phase-state deployment disagreement is refused by name; mode left alone"
  else
    fail_ "B5" "mode=[$(mval "$P5" mode)] out=[$(printf '%s' "$BF_OUT" | grep -i deploy | head -1)]"
  fi
fi

# B6 — a deployment word nobody knows cannot yield a mode.
P6="$(newtmp)/p"
if ! mk_proj "$P6" organizational enterprise; then
  fail_ "B6 setup" "could not build the fixture"
else
  run_backfill "$P6"
  if [ "$(mval "$P6" mode)" = "organizational" ] \
     && printf '%s' "$BF_OUT" | grep -q "cannot derive"; then
    pass "B6 — an unknown deployment is refused by name; mode left alone"
  else
    fail_ "B6" "mode=[$(mval "$P6" mode)] out=[$(printf '%s' "$BF_OUT" | grep -i derive | head -1)]"
  fi
fi

# B7 — THE GUESS-REFUSAL. When phase-state carries no `.deployment`, the BL-030
# block above writes a WARNED GUESS of "personal" into the manifest. Deriving
# from that and announcing `[OK] mode repaired: organizational -> personal`
# would silently demote an organizational project — the same class of outcome
# this block exists to prevent. It refuses a DISAGREEMENT, so it must refuse an
# INVENTION too.
P7="$(newtmp)/p"
if ! mk_proj "$P7" organizational organizational --no-phase-state; then
  fail_ "B7 setup" "could not build the no-phase-state fixture"
else
  run_backfill "$P7"
  if [ "$(mval "$P7" mode)" = "organizational" ] \
     && printf '%s' "$BF_OUT" | grep -q "records no 'deployment'"; then
    pass "B7 — with no phase-state deployment the block REFUSES rather than deriving from BL-030's assumed default"
  else
    fail_ "B7" "mode=[$(mval "$P7" mode)] out=[$(printf '%s' "$BF_OUT" | grep -i deploy | head -1)]"
  fi
fi

echo "=== V — the repair must change BEHAVIOUR, not just the value ==="

PROT_DEFICIENT='{"allow_force_pushes":{"enabled":false},"enforce_admins":{"enabled":true},"required_pull_request_reviews":{"required_approving_review_count":0}}'
PROT_COMPLIANT='{"allow_force_pushes":{"enabled":false},"enforce_admins":{"enabled":true},"required_pull_request_reviews":{"required_approving_review_count":1},"required_status_checks":{"strict":true,"contexts":[]}}'

verify() {  # <mode> <protection-json> → V_RC, V_ERR
  local mode="$1" prot="$2" d
  d="$(newtmp)"; mkdir -p "$d/bin"
  cat > "$d/bin/gh" <<GH
#!/usr/bin/env bash
case "\$*" in
  *"branches/"*"/protection"*) printf '%s\n' '$prot'; exit 0 ;;
  *) exit 0 ;;
esac
GH
  chmod +x "$d/bin/gh"
  ( cd "$d" && git init -q . && git remote add origin https://github.com/acme/api.git ) >/dev/null 2>&1
  V_ERR="$d/err"
  (
    cd "$d" || exit 9
    PATH="$d/bin:$PATH"
    # shellcheck source=/dev/null
    . "$GH_DRIVER" >/dev/null 2>&1 || exit 91
    host_verify_protection main "$mode"
  ) >/dev/null 2>"$V_ERR"
  V_RC=$?
  return 0
}

if [ ! -f "$GH_DRIVER" ]; then
  fail_ "V setup" "$GH_DRIVER not found"
else
  PV="$(newtmp)/p"
  if ! mk_proj "$PV" organizational organizational; then
    fail_ "V setup" "could not build the fixture"
  else
    stranded="$(mval "$PV" mode)"
    run_backfill "$PV"
    repaired="$(mval "$PV" mode)"

    # V0 (CONTROL) — the fixture protection really is org-deficient, proven by
    # a mode the driver accepts. Without this, V1 could pass on a fixture that
    # fails for any reason at all.
    verify org "$PROT_DEFICIENT"
    if [ "$V_RC" -ne 0 ] && grep -q 'required_approving_review_count' "$V_ERR"; then
      pass "V0 (control) — mode=org refuses this protection, naming an org-only rule (rc=$V_RC)"
    else
      fail_ "V0 (control)" "mode=org gave rc=$V_RC — the fixture is not org-deficient, so V1 proves nothing"
    fi

    # V1 — the repaired value makes the ORG rules run.
    verify "$repaired" "$PROT_DEFICIENT"
    if [ "$V_RC" -ne 0 ] && grep -q 'required_approving_review_count' "$V_ERR"; then
      pass "V1 — after the backfill, mode=[$repaired] makes the driver run the ORG rules (rc=$V_RC)"
    else
      fail_ "V1" "mode=[$repaired] gave rc=$V_RC without naming an org-only rule — the value moved, the behaviour did not"
    fi

    # V2 (CONTROL) — and it is not simply always failing.
    verify "$repaired" "$PROT_COMPLIANT"
    if [ "$V_RC" -eq 0 ]; then
      pass "V2 (control) — the repaired mode PASSES org-compliant protection (rc=$V_RC): V1 is the org rules, not a blanket failure"
    else
      fail_ "V2 (control)" "org-compliant protection failed (rc=$V_RC): $(head -1 "$V_ERR" 2>/dev/null)"
    fi

    # NO CASE FOR THE STRANDED VALUE'S DRIVER BEHAVIOUR, DELIBERATELY. That the
    # drivers REFUSE an unknown mode is `## BL-268:`'s second arm, on a
    # different branch; asserting it from here would make this suite fail on
    # its own branch and pass only once the other lands. V0/V1/V2 rest on the
    # org-only rules, which are on main and independent of that fix. The
    # stranded value is recorded above as `$stranded` for the failure text and
    # nothing else.
  fi
fi

echo "=== M — mutation proofs on a mirror ==="

M_MARK="BL-270-MODE-VOCABULARY-BACKFILL"
n="$(grep -c "$M_MARK" "$UPGRADE" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
[ "$n" = "1" ] \
  && pass "M0 — '$M_MARK' occurs exactly once in upgrade-project.sh" \
  || fail_ "M0" "'$M_MARK' occurs $n time(s) (need 1)"

# mutate <sed-expr> <must-vanish> <want-changed> → MUT (extracted fn) or ""
mutate() {
  local expr="$1" gone="$2" want="$3" d src fn
  d="$(newtmp)"; src="$d/upgrade.sh"; fn="$d/fn.sh"
  sed -e "$expr" "$UPGRADE" > "$src"
  if [ "$(grep -c "$gone" "$src")" -ne 0 ]; then MUT=""; MUT_WHY="the mutated text is still present"; return 0; fi
  if [ "$(_changed "$UPGRADE" "$src")" -ne "$want" ]; then
    MUT=""; MUT_WHY="changed $(_changed "$UPGRADE" "$src") line(s), wanted $want"; return 0
  fi
  awk '/^_run_idempotent_backfill\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$src" > "$fn"
  if ! bash -n "$fn" 2>/dev/null; then MUT=""; MUT_WHY="the mutated function does not parse"; return 0; fi
  MUT="$fn"; MUT_WHY=""
  return 0
}

# MP1 — the guard accepts an absent mode too. It would then write `mode` onto
# projects the sibling backfills own, on their input. B4 is what stops it.
mutate "s@^      ''|personal|org) ;;.*\$@      personal|org) ;;@" \
       "^      ''" 2
if [ -z "$MUT" ]; then
  fail_ "MP1 setup" "the guard mutation did not apply cleanly — $MUT_WHY"
else
  PM1="$(newtmp)/p"
  if ! mk_proj "$PM1" --no-mode organizational; then
    fail_ "MP1 setup" "could not build the mutant's fixture"
  else
    run_backfill "$PM1" "$MUT"
    if [ "$(mval "$PM1" mode)" != "<<ABSENT>>" ]; then
      pass "MP1 (MUTATION) — dropping the empty arm makes the block claim an ABSENT mode (wrote [$(mval "$PM1" mode)]): B4 is what stops it"
    else
      fail_ "MP1 (MUTATION)" "the guard mutation changed nothing (mode=[$(mval "$PM1" mode)])"
    fi
  fi
fi

# MP2 — remove the contradiction refusal. The block then derives from one
# record while contradicting the other. B5 is what stops it.
# The arm is an `elif` since the guess-refusal was added above it.
mutate 's|^        elif \[ -n "\$bl270_ps" \] && \[ -n "\$bl270_dep" \] && \[ "\$bl270_ps" != "\$bl270_dep" \]; then$|        elif false; then|' \
       '"\$bl270_ps" != "\$bl270_dep"' 2
if [ -z "$MUT" ]; then
  fail_ "MP2 setup" "the contradiction-refusal mutation did not apply cleanly — $MUT_WHY"
else
  PM2="$(newtmp)/p"
  if ! mk_proj "$PM2" organizational organizational personal; then
    fail_ "MP2 setup" "could not build the mutant's fixture"
  else
    run_backfill "$PM2" "$MUT"
    if [ "$(mval "$PM2" mode)" != "organizational" ]; then
      pass "MP2 (MUTATION) — without the refusal a disagreeing project is written mode=[$(mval "$PM2" mode)] from one record while the other says otherwise: B5 is what stops it"
    else
      fail_ "MP2 (MUTATION)" "removing the refusal changed nothing (mode=[$(mval "$PM2" mode)])"
    fi
  fi
fi

# MP3 — the plausible wrong fix: let the derivation reach `deployment` too.
# B1 still passes; only B2 sees it.
mutate "s|^              jq --arg m \"\$bl270_want\" '.mode = \$m' .claude/manifest.json > .claude/manifest.json.tmp \\\\\$|              jq --arg m \"\$bl270_want\" '.mode = \$m \| .deployment = \$m' .claude/manifest.json > .claude/manifest.json.tmp \\\\|" \
       "'.mode = \$m' .claude/manifest.json" 2
if [ -z "$MUT" ]; then
  fail_ "MP3 setup" "the deployment-leak mutation did not apply cleanly — $MUT_WHY"
else
  PM3="$(newtmp)/p"
  if ! mk_proj "$PM3" organizational organizational; then
    fail_ "MP3 setup" "could not build the mutant's fixture"
  else
    run_backfill "$PM3" "$MUT"
    m="$(mval "$PM3" mode)"; d="$(mval "$PM3" deployment)"
    if [ "$m" = "org" ] && [ "$d" = "org" ]; then
      pass "MP3 (MUTATION) — letting the derivation reach deployment leaves mode=[$m] correct while deployment becomes [$d]: B2 is the only case that sees it"
    else
      fail_ "MP3 (MUTATION)" "the deployment leak was not produced (mode=[$m] deployment=[$d])"
    fi
  fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] && exit 0
exit 1
