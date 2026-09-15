#!/usr/bin/env bash
# tests/test-bl268-mode-vocabulary.sh
#
# `## BL-268:` — ADOPTION WROTE THE `deployment` VOCABULARY INTO `mode`, AND
# THE ONE FUNCTION THAT READS `mode` ACCEPTED THE WRONG WORD IN SILENCE.
#
# Two halves of one defect, and either alone is survivable:
#
#   adopt_write_manifest() (scripts/lib/adopt/adopt-state.sh) wrote
#   `$ADOPT_DEPLOYMENT` into BOTH `.mode` and `.deployment`. They are not the
#   same field: `deployment` takes personal|organizational, `mode` takes
#   personal|org. So every ORGANIZATIONAL adoptee was born with
#   `mode: "organizational"` — a word no reader of `mode` knows. init.sh does
#   the translation at its own write site (`_RESOLVED_MODE="$DEPLOYMENT"`,
#   then `= "organizational" && "org"`), so a SCAFFOLDED project has never
#   carried it.
#
#   host_verify_protection() in all three host drivers had NO mode validation
#   — unlike its sibling host_configure_protection, which has refused an
#   unknown mode since it was written. Its org-only assertions are gated on
#   the literal string "org", so `"organizational"` fell through every one of
#   them and the function RETURNED 0 having run only the personal-tier subset.
#
# The blast radius is the join: an adopted organizational project asks to be
# held to the org branch-protection bar, is measured against the personal bar,
# and is told it passed. On GitHub that silently skips required approving
# reviews and required status checks; on GitLab, push-access-level 0, the
# approval rule and the pipeline-success gate; on Bitbucket, push restriction,
# approvals and passing builds. A green reading, from a check that could not
# run.
#
# WHY A RED RUN HERE IS A REAL DEFECT AND NOT A BROKEN FIXTURE. Three classes
# of control pass at base, by construction:
#   A0 / A3        `personal` round-trips through both manifest branches —
#                  the tier the fix does not touch.
#   A6             the adoptee's own manifest key survives, which is what
#                  proves the `adopt_jq_edit` branch (not the `jq -n` branch)
#                  actually ran for the pre-existing-manifest cases.
#   H*1 / H*2      each driver's fixture PASSES at `personal` and FAILS at
#                  `org` naming an org-only rule. That pair is load-bearing:
#                  it proves the fixture reaches the org-only block, so
#                  `organizational` returning 0 is the personal subset being
#                  run, not a fixture that never got that far.
#
# Everything is driven REAL: adopt_write_manifest is sourced out of the
# framework's own lib set and writes to a tmpdir project; host_verify_protection
# is sourced out of each driver and runs against a hermetic git repo with stub
# `gh` / `glab` / `curl` on PATH. Nothing under test is reimplemented here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
L_STATE="$REPO_ROOT/scripts/lib/adopt/adopt-state.sh"

PASSED=0
FAILED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }

TOPTMP="$(mktemp -d)"
trap 'rm -rf "$TOPTMP"' EXIT INT TERM
newtmp() { mktemp -d "$TOPTMP/fixXXXXXX"; }
_num() { case "$1" in ''|*[!0-9]*) printf '0\n' ;; *) printf '%s\n' "$1" ;; esac }
_changed_lines() { local n; n=$(diff "$1" "$2" 2>/dev/null | grep -c '^[<>]'); _num "$n"; }
_count()  { local n; n=$(grep -c  "$2" "$1" 2>/dev/null); _num "$n"; }
_countf() { local n; n=$(grep -cF -- "$2" "$1" 2>/dev/null); _num "$n"; }

[ -f "$L_STATE" ] || { echo "  [FAIL] setup — $L_STATE not found"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "  [FAIL] setup — jq is required (the manifest is written and read through it)"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }
command -v git >/dev/null 2>&1 || { echo '  [FAIL] setup — git is required (the drivers parse `git remote get-url origin`)'; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }

# Distinctive payloads carried by the pre-existing manifest. If the `jq -n`
# branch runs where the `adopt_jq_edit` branch was meant to, these vanish.
#
# PLAIN WORDS, DELIBERATELY. The first spelling of PRE_KEY was
# `bl268_adoptee_key`, and the contributor pre-commit hook refused the commit:
# gitleaks scored it `generic-api-key` at entropy 3.690116 and blocked the
# whole branch. It is a JSON field NAME in a fixture manifest, not a
# credential, but a fixture is not worth an allowlist — the repo ships no
# `.gitleaks.toml` and the hook has no allowlist convention, so the framework's
# answer is that fixtures should not carry high-entropy strings. Keep any
# replacement dictionary-word shaped, and keep "key"/"token"/"secret" out of
# the VALUE.
PRE_KEY='their_own_field'
PRE_VAL='BL268-ADOPTEE-FIELD-KEPT'
PRE_REMOTE='https://example.invalid/theirs.git'

# ── The manifest half ───────────────────────────────────────────────────────
# wm <fw-root> <tier> <fresh|existing> — drives the REAL adopt_write_manifest,
# sourced from FW's own lib set exactly as scripts/adopt-project.sh sources it,
# against a hermetic tmpdir project. `fresh` takes the `jq -n` create branch;
# `existing` takes the `adopt_jq_edit` branch. Sets WM_RC and WM_FILE.
#
# The source runs in a SUBSHELL: adopt-core.sh keeps a write ledger in globals
# and soif_adoption_stamp refuses a second stamp, so state must not leak
# between cases.
wm() {
  local fw="$1" tier="$2" shape="$3" d
  WM_RC=99; WM_FILE=""
  d="$(newtmp)" || return 0
  mkdir -p "$d/p/.claude/adoption" || return 0
  printf '{"fixture":"bl268"}\n' > "$d/p/.claude/adoption/scout-report.json"
  printf '{"stack":{"ciHost":"github"}}\n' > "$d/report.json"
  if [ "$shape" = "existing" ]; then
    jq -n --arg r "$PRE_REMOTE" --arg k "$PRE_KEY" --arg v "$PRE_VAL" \
      '{host: "other", mode: "personal", remote_url: $r} + {($k): $v}' \
      > "$d/p/.claude/manifest.json" || return 0
  fi
  (
    for _c in helpers-core.sh adoption-stamp.sh scaffold-shipped-set.sh hook-templates.sh \
              enforcement-level.sh tdd-classify.sh bypass-audit.sh; do
      # shellcheck disable=SC1090
      . "$fw/scripts/lib/$_c" || exit 91
    done
    for _p in adopt-core adopt-evidence adopt-intake adopt-tools adopt-state \
              adopt-archive adopt-stubs adopt-test-debt; do
      # shellcheck disable=SC1090
      . "$fw/scripts/lib/adopt/$_p.sh" || exit 92
    done
    ADOPT_DEPLOYMENT="$tier"
    ADOPT_POC_MODE=""
    adopt_write_manifest "$d/p" "$d/report.json"
  ) </dev/null >/dev/null 2>&1
  WM_RC=$?
  WM_FILE="$d/p/.claude/manifest.json"
  return 0
}

# mval <file> <key> — the value, or a loud sentinel. Never the empty string:
# an absent key and a key set to "" must not read the same.
mval() { jq -r --arg k "$2" '.[$k] // "<<ABSENT>>"' "$1" 2>/dev/null || printf '<<UNREADABLE>>\n'; }

# ── The driver half ─────────────────────────────────────────────────────────
# One fixture tree, built once: three git repos (one per host) and a bin/ of
# stub CLIs. host_verify_protection never writes, so the repos are reusable.
#
# THE FIXTURES ARE TUNED SO THAT personal PASSES AND org FAILS. That gap is
# the whole instrument: `organizational` landing on 0 can then only mean the
# org-only block was skipped.
# The default: the personal bar MET, the org bar MISSED.
PROT_ORG_DEFICIENT='{"allow_force_pushes":{"enabled":false},"enforce_admins":{"enabled":true},"required_pull_request_reviews":{"required_approving_review_count":0}}'
# The variant H5/H6 need: the SHARED bar missed too, so a verification run
# against it produces a failure BANNER — which is where the operator-visible
# half of this defect lives, because the banner interpolates $mode.
PROT_SHARED_DEFICIENT='{"allow_force_pushes":{"enabled":true},"enforce_admins":{"enabled":true},"required_pull_request_reviews":{"required_approving_review_count":0}}'

FIXDIR="$(newtmp)"
setup_fixtures() {
  mkdir -p "$FIXDIR/bin" || return 1
  local h
  for h in github gitlab bitbucket; do
    mkdir -p "$FIXDIR/$h" || return 1
  done
  ( cd "$FIXDIR/github"    && git init -q . && git remote add origin "https://github.com/acme/api.git" ) >/dev/null 2>&1 || return 1
  ( cd "$FIXDIR/gitlab"    && git init -q . && git remote add origin "https://gitlab.com/acme/api.git" ) >/dev/null 2>&1 || return 1
  ( cd "$FIXDIR/bitbucket" && git init -q . && git remote add origin "https://bitbucket.org/acme/api.git" ) >/dev/null 2>&1 || return 1

  # gh: reads a swappable protection document, so a case can change what the
  # host reports without rebuilding the fixture. The default meets the
  # personal bar (force-push off, admins enforced) and misses the org bar
  # (zero required approving reviews, no status checks).
  printf '%s\n' "$PROT_ORG_DEFICIENT" > "$FIXDIR/gh-protection.json"
  cat > "$FIXDIR/bin/gh" <<GH_STUB
#!/usr/bin/env bash
cat "$FIXDIR/gh-protection.json"
exit 0
GH_STUB

  # glab: a protected branch with a push restriction (personal bar met), but
  # push_access_level 40 rather than 0, no approval rule, and no
  # pipeline-success gate (all three org rules missed).
  cat > "$FIXDIR/bin/glab" <<'GLAB_STUB'
#!/usr/bin/env bash
case "$*" in
  *protected_branches*) printf '%s\n' '{"allow_force_push":false,"push_access_levels":[{"access_level":40}]}' ;;
  *approval_rules*)     printf '%s\n' '[]' ;;
  *)                    printf '%s\n' '{"only_allow_merge_if_pipeline_succeeds":false}' ;;
esac
exit 0
GLAB_STUB

  # curl (bitbucket): force and delete restrictions present (personal bar
  # met), no push / approvals / builds restrictions (the org bar missed).
  #
  # IT DOES NOT DRAIN STDIN, and that is deliberate rather than an omission.
  # tests/host-drivers/mock-cli.sh drains (`[ -t 0 ] || cat >/dev/null`)
  # because its stubs also serve POST/PUT call sites that pipe a body. The
  # only path this suite reaches is `_bb_curl_no_body`, which pipes nothing —
  # so the drain would read the HARNESS's stdin instead, and under any runner
  # whose stdin is an open pipe rather than a terminal (which is every CI
  # lane) `cat` blocks for ever and the suite hangs rather than fails.
  # Measured: three stuck processes on a backgrounded run. The `< /dev/null`
  # on hv's subshell is the second belt.
  cat > "$FIXDIR/bin/curl" <<'CURL_STUB'
#!/usr/bin/env bash
printf '%s\n' '{"values":[{"kind":"force"},{"kind":"delete"}]}'
exit 0
CURL_STUB
  chmod +x "$FIXDIR/bin/gh" "$FIXDIR/bin/glab" "$FIXDIR/bin/curl" || return 1
  return 0
}

# hv <fw-root> <driver> <mode> — drives the REAL host_verify_protection out of
# FW's driver file, against this fixture's repo and stub CLIs. Sets HV_RC and
# HV_ERR (stderr verbatim, so the REASON for a refusal can be pinned, not just
# its exit code).
hv() {
  local fw="$1" drv="$2" mode="$3" err
  err="$FIXDIR/hv.err"
  (
    cd "$FIXDIR/$drv" || exit 90
    PATH="$FIXDIR/bin:$PATH"; export PATH
    unset SOLO_APPROVALS_ATTESTED                     # BL-032's attestation would skip a gitlab org rule
    BITBUCKET_API_TOKEN="bl268-token"
    BITBUCKET_API_TOKEN_EMAIL="bl268@test.invalid"
    BITBUCKET_WORKSPACE="acme"
    export BITBUCKET_API_TOKEN BITBUCKET_API_TOKEN_EMAIL BITBUCKET_WORKSPACE
    # shellcheck disable=SC1090
    . "$fw/scripts/host-drivers/$drv.sh" >/dev/null 2>&1 || exit 91
    host_verify_protection "main" "$mode"
  ) </dev/null >/dev/null 2>"$err"
  HV_RC=$?
  HV_ERR="$(cat "$err" 2>/dev/null)"
  return 0
}

if ! setup_fixtures; then
  echo "  [FAIL] setup — could not build the host-driver fixtures"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1
fi

echo "=== A — the real adopt_write_manifest, both write branches ==="

# A0 (CONTROL) — personal is unchanged by the fix, through the create branch.
# Passes at base; without it a RED run could be a broken fixture.
wm "$REPO_ROOT" "personal" "fresh"
if [ "$WM_RC" -ne 0 ] || [ ! -f "$WM_FILE" ]; then
  fail_ "A0 (control)" "adopt_write_manifest exited $WM_RC and wrote no manifest — the fixture, not the defect, is broken"
else
  m="$(mval "$WM_FILE" mode)"; d="$(mval "$WM_FILE" deployment)"
  if [ "$m" = "personal" ] && [ "$d" = "personal" ]; then
    pass "A0 (control) — a personal adoptee is born mode=[$m] deployment=[$d] (jq -n branch)"
  else
    fail_ "A0 (control)" "personal landed as mode=[$m] deployment=[$d], want personal/personal"
  fi
fi

# A1/A2 — THE DISCRIMINATORS, create branch. `mode` must speak the mode
# vocabulary and `deployment` must speak its own; base writes "organizational"
# into both.
wm "$REPO_ROOT" "organizational" "fresh"
if [ "$WM_RC" -ne 0 ] || [ ! -f "$WM_FILE" ]; then
  fail_ "A1 setup" "adopt_write_manifest (organizational, fresh) exited $WM_RC and wrote no manifest"
else
  m="$(mval "$WM_FILE" mode)"; d="$(mval "$WM_FILE" deployment)"
  [ "$m" = "org" ] \
    && pass "A1 — an organizational adoptee is born .mode=[org] (jq -n branch)" \
    || fail_ "A1" ".mode is [$m], want [org] — the deployment vocabulary was written into the mode field"
  [ "$d" = "organizational" ] \
    && pass "A2 — and .deployment keeps its own word, [organizational] (jq -n branch)" \
    || fail_ "A2" ".deployment is [$d], want [organizational] — the mode vocabulary leaked into the deployment field"
fi

# A3 (CONTROL) — personal through the adopt_jq_edit branch. Also passes at base.
wm "$REPO_ROOT" "personal" "existing"
if [ "$WM_RC" -ne 0 ] || [ ! -f "$WM_FILE" ]; then
  fail_ "A3 (control)" "adopt_write_manifest (personal, existing) exited $WM_RC — the fixture, not the defect, is broken"
else
  m="$(mval "$WM_FILE" mode)"; d="$(mval "$WM_FILE" deployment)"
  if [ "$m" = "personal" ] && [ "$d" = "personal" ]; then
    pass "A3 (control) — a personal adoptee with a pre-existing manifest is mode=[$m] deployment=[$d] (adopt_jq_edit branch)"
  else
    fail_ "A3 (control)" "personal landed as mode=[$m] deployment=[$d], want personal/personal"
  fi
fi

# A4/A5/A6 — the same discriminators on the OTHER branch, plus the case that
# proves it IS the other branch.
wm "$REPO_ROOT" "organizational" "existing"
if [ "$WM_RC" -ne 0 ] || [ ! -f "$WM_FILE" ]; then
  fail_ "A4 setup" "adopt_write_manifest (organizational, existing) exited $WM_RC and wrote no manifest"
else
  m="$(mval "$WM_FILE" mode)"; d="$(mval "$WM_FILE" deployment)"; k="$(mval "$WM_FILE" "$PRE_KEY")"; r="$(mval "$WM_FILE" remote_url)"
  [ "$m" = "org" ] \
    && pass "A4 — an organizational adoptee with a pre-existing manifest is .mode=[org] (adopt_jq_edit branch)" \
    || fail_ "A4" ".mode is [$m], want [org] — the adopt_jq_edit branch writes the wrong vocabulary"
  [ "$d" = "organizational" ] \
    && pass "A5 — and .deployment keeps [organizational] (adopt_jq_edit branch)" \
    || fail_ "A5" ".deployment is [$d], want [organizational]"
  # A6 (CONTROL) — the adoptee's own key and remote survived, so this really
  # was the EDIT branch. Without it A4/A5 could be passing on the create path
  # with the pre-existing manifest never read.
  if [ "$k" = "$PRE_VAL" ] && [ "$r" = "$PRE_REMOTE" ]; then
    pass "A6 (control) — the adoptee's own manifest key and remote_url survived, so the adopt_jq_edit branch is what ran"
  else
    fail_ "A6 (control)" "the pre-existing manifest was not edited but replaced ($PRE_KEY=[$k] remote_url=[$r]) — A4/A5 are measuring the wrong branch"
  fi
fi

# A7 — THE ORACLE, pinned rather than restated. The claim "adoption must be
# born with a scaffolded project's shape" is only meaningful while init.sh
# still spells the mode token this way. Read init.sh as SOURCE; it ends in an
# unconditional `main "$@"` and cannot be run for this.
if [ "$(_countf "$REPO_ROOT/init.sh" '_RESOLVED_MODE="org"')" -ge 1 ]; then
  pass "A7 — init.sh's own scaffolding path still translates organizational to the token [org], so the two birth paths agree"
else
  fail_ "A7" "init.sh no longer carries _RESOLVED_MODE=\"org\" — the vocabulary this suite pins has moved; re-derive it before trusting A1/A4"
fi

echo "=== H — the real host_verify_protection, all three drivers ==="

for drv in github gitlab bitbucket; do
  # H*1 (CONTROL) — the fixture meets the personal bar. True at base.
  hv "$REPO_ROOT" "$drv" "personal"
  [ "$HV_RC" -eq 0 ] \
    && pass "H1 $drv (control) — the fixture PASSES at mode=personal (rc=$HV_RC)" \
    || fail_ "H1 $drv (control)" "the fixture failed the personal bar (rc=$HV_RC): $(printf '%s' "$HV_ERR" | head -2 | tr '\n' ' ')"

  # H*2 (CONTROL) — and FAILS at the org bar, naming an org-only rule. True at
  # base, and this is the case that makes H3 mean something: it proves the
  # fixture reaches the org-only block at all.
  hv "$REPO_ROOT" "$drv" "org"
  case "$HV_RC:$HV_ERR" in
    0:*) fail_ "H2 $drv (control)" "the fixture PASSED at mode=org — the org-only block is not reachable with this fixture, so H3 would prove nothing" ;;
    *"org mode requires"*) pass "H2 $drv (control) — the fixture FAILS at mode=org naming an org-only rule (rc=$HV_RC)" ;;
    *) fail_ "H2 $drv (control)" "mode=org failed (rc=$HV_RC) but named no org-only rule: $(printf '%s' "$HV_ERR" | head -2 | tr '\n' ' ')" ;;
  esac

  # H*3 — THE DISCRIMINATOR. At base this returns 0, having silently run the
  # personal-tier subset of an ORGANIZATIONAL project's checks.
  hv "$REPO_ROOT" "$drv" "organizational"
  [ "$HV_RC" -ne 0 ] \
    && pass "H3 $drv — mode=organizational is REFUSED (rc=$HV_RC), not run as personal" \
    || fail_ "H3 $drv" "mode=organizational returned 0 — the org-only assertions were skipped and the project was told it passed"

  # H*4 — and it refuses on the VOCABULARY, naming the word it got. A
  # non-zero exit alone would also be satisfied by a fixture that merely
  # started failing; this pins WHY.
  case "$HV_ERR" in
    *"mode must be"*organizational*) pass "H4 $drv — the refusal names the vocabulary and the offending word" ;;
    *) fail_ "H4 $drv" "mode=organizational did not refuse on the mode vocabulary: $(printf '%s' "$HV_ERR" | head -2 | tr '\n' ' ')" ;;
  esac
done

# H5/H6 — THE OPERATOR-VISIBLE HALF, on a fixture that also misses the SHARED
# bar so that a failure BANNER is actually printed. The banner interpolates
# $mode, so at base an unknown mode produced "(organizational mode):" over a
# list containing only personal-tier failures — a report naming a tier it
# never verified. H6 cannot be vacuous: the default fixture passes the shared
# rules and prints no banner at all, which is why this case needs its own.
printf '%s\n' "$PROT_SHARED_DEFICIENT" > "$FIXDIR/gh-protection.json"

hv "$REPO_ROOT" "github" "org"
case "$HV_RC:$HV_ERR" in
  0:*) fail_ "H5 (control)" "the shared-deficient fixture PASSED at mode=org — it prints no banner, so H6 would prove nothing" ;;
  *"(org mode)"*) pass "H5 (control) — on a shared-deficient fixture, mode=org prints a banner reading '(org mode)' (rc=$HV_RC)" ;;
  *) fail_ "H5 (control)" "mode=org failed (rc=$HV_RC) without the expected banner: $(printf '%s' "$HV_ERR" | head -2 | tr '\n' ' ')" ;;
esac

hv "$REPO_ROOT" "github" "organizational"
case "$HV_ERR" in
  *"organizational mode"*)
    fail_ "H6" "the banner claims to have verified 'organizational mode' while listing only personal-tier failures: $(printf '%s' "$HV_ERR" | head -3 | tr '\n' ' ')" ;;
  *)
    pass "H6 — nothing printed claims to have verified an 'organizational mode' the driver does not know" ;;
esac

printf '%s\n' "$PROT_ORG_DEFICIENT" > "$FIXDIR/gh-protection.json"

echo "=== E — end to end: the mode adoption writes, fed to the verifier ==="

# E1 — the consequence, joined. Adopt an organizational project, read the
# `mode` its manifest carries, and hand THAT to the real verifier. At base the
# manifest says "organizational", the verifier returns 0, and not one org-only
# rule is ever evaluated: an organizational project is certified against the
# personal bar. At head the manifest says "org" and the verifier holds it to
# the org bar, which this fixture does not meet.
wm "$REPO_ROOT" "organizational" "fresh"
if [ "$WM_RC" -ne 0 ] || [ ! -f "$WM_FILE" ]; then
  fail_ "E1 setup" "adopt_write_manifest (organizational) exited $WM_RC"
else
  e_mode="$(mval "$WM_FILE" mode)"
  hv "$REPO_ROOT" "github" "$e_mode"
  if [ "$HV_RC" -eq 0 ]; then
    fail_ "E1" "an adopted ORGANIZATIONAL project's mode [$e_mode] verified CLEAN against the github driver — the org-only rules never ran"
  else
    case "$HV_ERR" in
      *"org mode requires"*) pass "E1 — an adopted organizational project's mode [$e_mode] is held to the org bar (rc=$HV_RC, an org-only rule is named)" ;;
      *"mode must be"*)      pass "E1 — an adopted organizational project's mode [$e_mode] is at least REFUSED rather than silently passed (rc=$HV_RC)" ;;
      *) fail_ "E1" "mode [$e_mode] failed (rc=$HV_RC) for neither reason this case is about: $(printf '%s' "$HV_ERR" | head -2 | tr '\n' ' ')" ;;
    esac
  fi
fi

echo "=== M — markers and mutation proofs on mirrors ==="

MARK="BL-268-MODE-VOCABULARY"

# M0 — one marker per fixed file, four in total. A mutation that silently hit
# a second site would show up here first.
for f in "scripts/lib/adopt/adopt-state.sh" "scripts/host-drivers/github.sh" \
         "scripts/host-drivers/gitlab.sh" "scripts/host-drivers/bitbucket.sh"; do
  n="$(_count "$REPO_ROOT/$f" "$MARK")"
  [ "$n" = "1" ] \
    && pass "M0 — '$MARK' occurs exactly once in $f" \
    || fail_ "M0" "'$MARK' occurs $n times in $f (need exactly 1)"
done

# mirror <dir> — a copy of scripts/ to mutate. Never the real tree.
mirror() { mkdir -p "$1" && cp -Rp "$REPO_ROOT/scripts" "$1/"; }

# apply <file> <sed-expr> — edit in place, and PROVE the edit landed: the
# result must still parse and must differ from the original. Prints 1 or 0.
apply() {
  local f="$1" expr="$2" before tmp
  before="$(mktemp)"; cp "$f" "$before"
  tmp="$(mktemp)"
  sed "$expr" "$before" > "$tmp" && mv "$tmp" "$f"
  if ! bash -n "$f" 2>/dev/null || [ "$(_changed_lines "$before" "$f")" -lt 2 ]; then
    rm -f "$before"; printf '0\n'; return 0
  fi
  rm -f "$before"; printf '1\n'
}

TRANSLATE_LINE='[ "$mode" = "organizational" ] && mode="org"'
EDIT_LINE='--arg h "$host" --arg m "$mode" --arg d "$ADOPT_DEPLOYMENT" --argjson p "$poc_json" || return 1'
CREATE_LINE='jq -n --arg h "$host" --arg m "$mode" --arg d "$ADOPT_DEPLOYMENT" --argjson p "$poc_json" \'

# MP1 — drop the translation on a mirror, restoring base's `mode`. A1 and A4
# must re-open on BOTH branches while A2/A5 (the deployment half) and the
# personal controls stay green — which is what proves A1/A4 discriminate the
# mode field specifically.
MP1="$(newtmp)/fw"
if ! mirror "$MP1"; then
  fail_ "MP1 setup" "could not mirror scripts/"
elif [ "$(_count "$MP1/scripts/lib/adopt/adopt-state.sh" '^  \[ "\$mode" = "organizational" \] && mode="org"$')" != "1" ]; then
  fail_ "MP1 setup" "the translation line is not a unique single line — the mutation did not apply cleanly"
elif [ "$(apply "$MP1/scripts/lib/adopt/adopt-state.sh" 's#^  \[ "\$mode" = "organizational" \] && mode="org"$#  :#')" != "1" ]; then
  fail_ "MP1 setup" "the mutation did not apply cleanly"
else
  wm "$MP1" "organizational" "fresh";    mp1_m_fresh="$(mval "$WM_FILE" mode)"; mp1_d_fresh="$(mval "$WM_FILE" deployment)"
  wm "$MP1" "organizational" "existing"; mp1_m_edit="$(mval "$WM_FILE" mode)";  mp1_d_edit="$(mval "$WM_FILE" deployment)"
  wm "$MP1" "personal" "fresh";          mp1_m_pers="$(mval "$WM_FILE" mode)"
  if [ "$mp1_m_fresh" = "organizational" ] && [ "$mp1_m_edit" = "organizational" ] \
     && [ "$mp1_d_fresh" = "organizational" ] && [ "$mp1_d_edit" = "organizational" ] \
     && [ "$mp1_m_pers" = "personal" ]; then
    pass "MP1 (MUTATION) — without the translation both branches write .mode=[organizational] while .deployment is untouched and personal still works: A1/A4 are what stop it"
  else
    fail_ "MP1 (MUTATION)" "removing the translation did not reproduce base (fresh mode=[$mp1_m_fresh] dep=[$mp1_d_fresh]; existing mode=[$mp1_m_edit] dep=[$mp1_d_edit]; personal mode=[$mp1_m_pers]) — A1/A4 may be passing for another reason"
  fi
fi

# MP2 — point the adopt_jq_edit branch's `deployment` back at `$mode`, base's
# other half. Only A5 sees it; A2 (the create branch) must stay green, which
# is what proves the two branches are covered SEPARATELY.
MP2="$(newtmp)/fw"
if ! mirror "$MP2"; then
  fail_ "MP2 setup" "could not mirror scripts/"
elif [ "$(_countf "$MP2/scripts/lib/adopt/adopt-state.sh" "$EDIT_LINE")" != "1" ]; then
  fail_ "MP2 setup" "the adopt_jq_edit arg line is not a unique single line"
elif [ "$(apply "$MP2/scripts/lib/adopt/adopt-state.sh" 's#--arg d "\$ADOPT_DEPLOYMENT" --argjson p "\$poc_json" || return 1$#--arg d "$mode" --argjson p "$poc_json" || return 1#')" != "1" ]; then
  fail_ "MP2 setup" "the adopt_jq_edit deployment mutation did not apply cleanly"
else
  wm "$MP2" "organizational" "existing"; mp2_d_edit="$(mval "$WM_FILE" deployment)"; mp2_m_edit="$(mval "$WM_FILE" mode)"
  wm "$MP2" "organizational" "fresh";    mp2_d_fresh="$(mval "$WM_FILE" deployment)"
  if [ "$mp2_d_edit" = "org" ] && [ "$mp2_m_edit" = "org" ] && [ "$mp2_d_fresh" = "organizational" ]; then
    pass "MP2 (MUTATION) — with the edit branch's deployment sourced from \$mode it writes [org] while the create branch still writes [organizational]: A5 is what stops it"
  else
    fail_ "MP2 (MUTATION)" "the edit-branch deployment mutation was not caught (edit dep=[$mp2_d_edit] mode=[$mp2_m_edit]; fresh dep=[$mp2_d_fresh]) — A5 may be passing for another reason"
  fi
fi

# MP3 — the same on the `jq -n` create branch. Only A2 sees it; A5 stays green.
MP3="$(newtmp)/fw"
if ! mirror "$MP3"; then
  fail_ "MP3 setup" "could not mirror scripts/"
elif [ "$(_countf "$MP3/scripts/lib/adopt/adopt-state.sh" "$CREATE_LINE")" != "1" ]; then
  fail_ "MP3 setup" "the jq -n arg line is not a unique single line"
elif [ "$(apply "$MP3/scripts/lib/adopt/adopt-state.sh" 's#^    jq -n --arg h "\$host" --arg m "\$mode" --arg d "\$ADOPT_DEPLOYMENT" --argjson p "\$poc_json" \\$#    jq -n --arg h "$host" --arg m "$mode" --arg d "$mode" --argjson p "$poc_json" \\#')" != "1" ]; then
  fail_ "MP3 setup" "the jq -n deployment mutation did not apply cleanly"
else
  wm "$MP3" "organizational" "fresh";    mp3_d_fresh="$(mval "$WM_FILE" deployment)"; mp3_m_fresh="$(mval "$WM_FILE" mode)"
  wm "$MP3" "organizational" "existing"; mp3_d_edit="$(mval "$WM_FILE" deployment)"
  if [ "$mp3_d_fresh" = "org" ] && [ "$mp3_m_fresh" = "org" ] && [ "$mp3_d_edit" = "organizational" ]; then
    pass "MP3 (MUTATION) — with the create branch's deployment sourced from \$mode it writes [org] while the edit branch still writes [organizational]: A2 is what stops it"
  else
    fail_ "MP3 (MUTATION)" "the create-branch deployment mutation was not caught (fresh dep=[$mp3_d_fresh] mode=[$mp3_m_fresh]; edit dep=[$mp3_d_edit]) — A2 may be passing for another reason"
  fi
fi

# MP4-MP6 — excise the mode gate from each driver in turn. The mutant must
# return 0 on `organizational` AND say nothing, i.e. be indistinguishable from
# `personal` — that is the defect stated exactly — while `org` still fails, so
# the mirror is otherwise intact.
mpn=4
for drv in github gitlab bitbucket; do
  MPD="$(newtmp)/fw"
  tag="MP$mpn"
  mpn=$((mpn + 1))
  if ! mirror "$MPD"; then
    fail_ "$tag setup" "could not mirror scripts/"
    continue
  fi
  tgt="$MPD/scripts/host-drivers/$drv.sh"
  before="$(mktemp)"; cp "$tgt" "$before"
  # The refusal line is unique per driver; the gate is the four lines
  # `case` / `personal|org) ;;` / refusal / `esac` around it.
  ref="$(grep -n 'host_verify_protection: mode must be' "$before" | head -1 | cut -d: -f1)"
  if [ -z "$ref" ] || [ "$(_count "$before" 'host_verify_protection: mode must be')" != "1" ]; then
    fail_ "$tag setup" "the $drv refusal line is not a unique single line (found at [$ref])"
    rm -f "$before"; continue
  fi
  open=$((ref - 2)); armn=$((ref - 1)); close=$((ref + 1))
  l_open="$(sed -n "${open}p" "$before")"; l_arm="$(sed -n "${armn}p" "$before")"; l_close="$(sed -n "${close}p" "$before")"
  if [ "$l_open" != '  case "$mode" in' ] || [ "$l_arm" != '    personal|org) ;;' ] || [ "$l_close" != '  esac' ]; then
    fail_ "$tag setup" "the $drv gate is not the expected four lines (open=[$l_open] arm=[$l_arm] close=[$l_close])"
    rm -f "$before"; continue
  fi
  { head -n $((open - 1)) "$before"; tail -n +$((close + 1)) "$before"; } > "$tgt"
  if ! bash -n "$tgt" 2>/dev/null \
     || [ "$(_count "$tgt" 'host_verify_protection: mode must be')" != "0" ] \
     || [ "$(_count "$tgt" '^host_verify_protection() {$')" != "1" ] \
     || [ "$(_changed_lines "$before" "$tgt")" -lt 4 ]; then
    fail_ "$tag setup" "the $drv gate removal did not apply cleanly"
    rm -f "$before"; continue
  fi
  rm -f "$before"
  hv "$MPD" "$drv" "organizational"; mut_rc="$HV_RC"; mut_err="$HV_ERR"
  hv "$MPD" "$drv" "org";            org_rc="$HV_RC"
  hv "$MPD" "$drv" "personal";       per_rc="$HV_RC"
  if [ "$mut_rc" -eq 0 ] && [ -z "$mut_err" ] && [ "$org_rc" -ne 0 ] && [ "$per_rc" -eq 0 ]; then
    pass "$tag (MUTATION) — without the gate, $drv reads mode=organizational exactly as personal (rc=0, silent) while mode=org still fails: H3 $drv is what stops it"
  else
    fail_ "$tag (MUTATION)" "removing the $drv gate did not reproduce base (organizational rc=$mut_rc err=[$(printf '%s' "$mut_err" | head -1)] org rc=$org_rc personal rc=$per_rc) — H3 $drv may be passing for another reason"
  fi
done

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] && exit 0
exit 1
