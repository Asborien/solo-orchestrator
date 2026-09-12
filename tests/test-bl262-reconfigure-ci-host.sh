#!/usr/bin/env bash
# tests/test-bl262-reconfigure-ci-host.sh
#
# `## BL-262:` — `reconfigure-project.sh` REGENERATES THE CI PIPELINE AT A PATH
# THAT CANNOT EXIST, AND REPORTS SUCCESS.
#
# The `language` arm of scripts/reconfigure-project.sh built its template path
# as `templates/pipelines/ci/<lang>.yml`, omitting the per-host directory that
# the templates actually live in (`ci/{github,gitlab,bitbucket}/<lang>.yml`).
# The path therefore never resolves on ANY host, the `[ -f ]` guard falls to
# `print_warn "CI template not found"`, and the script continues to its
# `[OK] Reconfiguration complete.` banner at rc 0. The operator asked for a
# language change and was told it happened; the CI pipeline still runs the old
# language's jobs.
#
# The second half is the destination. The same block hardcoded
# `cp … .github/workflows/ci.yml`, so even with the source path corrected a
# GitLab or Bitbucket project would have had a GitHub-shaped file written to a
# path its host never reads. init.sh switches the destination by host and
# returns early for `other`; this block had no host awareness at all
# (`grep -c host scripts/reconfigure-project.sh` -> 0).
#
# This is the SAME defect class as `## BL-229:`, in a file BL-229 named as a
# writer it did not convert — scripts/lib/host.sh's own sync-sibling note lists
# `scripts/reconfigure-project.sh` among the HOST_CI_PATH copies left behind.
# The fix therefore asks the shared resolver (`# BL-229-HOST-PIPELINE-PATHS`)
# for the destination rather than minting a fourth copy of the mapping.
#
# Cases pin CONTENT, not existence. A fix that resolves the per-host source
# directory but keeps the hardcoded destination still writes a real file — it
# writes the WRONG one to the WRONG place, and an existence check calls that
# green. Each host's fixture template carries a distinct marker string.
#
# Hermetic: temp dirs only, a SYNTHETIC orchestrator source (no dependence on
# the real templates/ tree), no network, no init.sh invocation. bash 3.2 safe.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RECONF="$REPO_ROOT/scripts/reconfigure-project.sh"

PASSED=0
FAILED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }

TOPTMP="$(mktemp -d)"
trap 'rm -rf "$TOPTMP"' EXIT INT TERM
newtmp() { mktemp -d "$TOPTMP/fixXXXXXX"; }

[ -f "$RECONF" ] || { echo "  [FAIL] setup — $RECONF not found"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  [FAIL] setup — jq is required"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }

# Distinctive per-host payloads. If the wrong host's template is copied, or the
# right one is copied to the wrong destination, these are what disagree.
GH_MARK='BL262-CI-TEMPLATE-GITHUB'
GL_MARK='BL262-CI-TEMPLATE-GITLAB'
BB_MARK='BL262-CI-TEMPLATE-BITBUCKET'

# mk_src <dir> [--omit-github-typescript] — a synthetic orchestrator source
# carrying only what this arm reads: the three per-host CI template dirs.
mk_src() {
  local d="$1" omit="${2:-}"
  mkdir -p "$d/templates/pipelines/ci/github" \
           "$d/templates/pipelines/ci/gitlab" \
           "$d/templates/pipelines/ci/bitbucket" || return 1
  printf '%s\n' "$GL_MARK" > "$d/templates/pipelines/ci/gitlab/typescript.yml"
  printf '%s\n' "$BB_MARK" > "$d/templates/pipelines/ci/bitbucket/typescript.yml"
  if [ "$omit" != "--omit-github-typescript" ]; then
    printf '%s\n' "$GH_MARK" > "$d/templates/pipelines/ci/github/typescript.yml"
  fi
  return 0
}

# mk_proj <dir> <src> <host|--no-manifest> [scripts_dir] — a fixture PROJECT.
# Carries scripts/ the way a generated project does (init.sh copies them in),
# because reconfigure-project.sh resolves PROJECT_ROOT from its own location.
# Deliberately has no init.sh and no templates/generated, so the framework
# self-contamination guard (_soif_dir_is_framework) does not fire on it.
mk_proj() {
  local d="$1" src="$2" host="$3" scripts="${4:-$REPO_ROOT/scripts}"
  local cfg="$d/.claude"
  mkdir -p "$cfg" || return 1
  cp -Rp "$scripts" "$d/scripts" || return 1
  printf '{"source_dir": "%s"}\n' "$src" > "$cfg/orchestrator-source.json"
  printf '{"context": {"language": "python", "platform": "web"}}\n' > "$cfg/tool-preferences.json"
  case "$host" in
    --no-manifest)    : ;;                                        # no manifest at all  -> host.sh rc 1
    --empty-manifest) printf '{}\n' > "$cfg/manifest.json" ;;     # manifest, no .host  -> host.sh rc 2
    *)                printf '{"host": "%s"}\n' "$host" > "$cfg/manifest.json" ;;
  esac
  return 0
}

# run_reconf <proj> <outfile> — drive the real script; echo its rc.
run_reconf() {
  local d="$1" out="$2" rc=0
  ( cd "$d" && bash scripts/reconfigure-project.sh \
      --field language --old python --new typescript ) > "$out" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# what_landed <proj> — the CI destinations any host could have used, one per
# line, for a "nothing was written" assertion that names what it found.
what_landed() {
  local d="$1" f
  for f in ".github/workflows/ci.yml" ".gitlab-ci.yml" "bitbucket-pipelines.yml"; do
    [ -f "$d/$f" ] && printf '%s\n' "$f"
  done
  return 0
}

# ── T0: HONEST-OUTCOME CONTROL — true at base AND after the fix ─────────────
# The first cut of this suite was 0 passed / 7 failed at base. A red with no
# passing control cannot distinguish "the defect is real" from "the harness
# never drove the script": every case would read the same way if `run_reconf`
# silently did nothing. T0 is the floor. It asserts only what the language arm
# already did correctly before this entry — the recorded language changes, and
# the script says so — so it passes on unmodified main and must keep passing
# after the fix. It is a control, never a discriminator.
echo "T0: the language arm updates the recorded language (control: true before and after)"
S0="$(newtmp)/src"; P0="$(newtmp)/proj"
if ! mk_src "$S0" || ! mk_proj "$P0" "$S0" github; then
  fail_ "T0 setup" "could not build the fixture"
else
  O0="$(newtmp)/out"; RC0="$(run_reconf "$P0" "$O0")"
  lang0="$(jq -r '.context.language // "<<ABSENT>>"' "$P0/.claude/tool-preferences.json" 2>/dev/null || echo '<<UNREADABLE>>')"
  said0=no; grep -q 'Updated language in tool-preferences.json' "$O0" && said0=yes
  if [ "$lang0" = typescript ] && [ "$said0" = yes ]; then
    pass "T0 (control: language=$lang0, the script reported the update; rc=$RC0)"
  else
    fail_ "T0" "the harness is not driving the script: language=[$lang0] reported=$said0 (rc=$RC0); output was: $(head -c 300 "$O0")"
  fi
fi

# ── T1: github — correct destination AND the github template's content ──────
echo "T1: host github writes .github/workflows/ci.yml from the github template"
S1="$(newtmp)/src"; P1="$(newtmp)/proj"
if ! mk_src "$S1" || ! mk_proj "$P1" "$S1" github; then
  fail_ "T1 setup" "could not build the fixture"
else
  O1="$(newtmp)/out"; RC1="$(run_reconf "$P1" "$O1")"
  got1="$(cat "$P1/.github/workflows/ci.yml" 2>/dev/null || echo '<<ABSENT>>')"
  if [ "$got1" = "$GH_MARK" ]; then
    pass "T1 (rc=$RC1, content=$got1)"
  else
    fail_ "T1" "wanted [$GH_MARK] at .github/workflows/ci.yml, got [$got1] (rc=$RC1); script said: $(grep -c . "$O1") line(s), warn: $(grep -m1 'CI template not found' "$O1" || echo none)"
  fi
fi

# ── T2: gitlab — root .gitlab-ci.yml, gitlab content, and NOTHING under .github
echo "T2: host gitlab writes .gitlab-ci.yml from the gitlab template"
S2="$(newtmp)/src"; P2="$(newtmp)/proj"
if ! mk_src "$S2" || ! mk_proj "$P2" "$S2" gitlab; then
  fail_ "T2 setup" "could not build the fixture"
else
  O2="$(newtmp)/out"; RC2="$(run_reconf "$P2" "$O2")"
  got2="$(cat "$P2/.gitlab-ci.yml" 2>/dev/null || echo '<<ABSENT>>')"
  stray2="$( [ -f "$P2/.github/workflows/ci.yml" ] && echo yes || echo no )"
  if [ "$got2" = "$GL_MARK" ] && [ "$stray2" = no ]; then
    pass "T2 (rc=$RC2, content=$got2, no stray GitHub file)"
  else
    fail_ "T2" "wanted [$GL_MARK] at .gitlab-ci.yml with no .github/workflows/ci.yml; got content=[$got2] stray_github=$stray2 (rc=$RC2)"
  fi
fi

# ── T3: bitbucket — root bitbucket-pipelines.yml, bitbucket content ─────────
echo "T3: host bitbucket writes bitbucket-pipelines.yml from the bitbucket template"
S3="$(newtmp)/src"; P3="$(newtmp)/proj"
if ! mk_src "$S3" || ! mk_proj "$P3" "$S3" bitbucket; then
  fail_ "T3 setup" "could not build the fixture"
else
  O3="$(newtmp)/out"; RC3="$(run_reconf "$P3" "$O3")"
  got3="$(cat "$P3/bitbucket-pipelines.yml" 2>/dev/null || echo '<<ABSENT>>')"
  stray3="$( [ -f "$P3/.github/workflows/ci.yml" ] && echo yes || echo no )"
  if [ "$got3" = "$BB_MARK" ] && [ "$stray3" = no ]; then
    pass "T3 (rc=$RC3, content=$got3, no stray GitHub file)"
  else
    fail_ "T3" "wanted [$BB_MARK] at bitbucket-pipelines.yml with no .github/workflows/ci.yml; got content=[$got3] stray_github=$stray3 (rc=$RC3)"
  fi
fi

# ── T4: other — writes nothing, rc 0, AND SAYS SO ───────────────────────────
# "Wrote nothing" alone is satisfied by the defect itself, which writes nothing
# on every host. What separates a correct `other` from the bug is the REASON
# the operator is given: `other` is a deliberate no-op, not a missing template.
# So this case also asserts the script does NOT claim the template is missing.
echo "T4: host other writes nothing at rc 0 and says why (not 'template not found')"
S4="$(newtmp)/src"; P4="$(newtmp)/proj"
if ! mk_src "$S4" || ! mk_proj "$P4" "$S4" other; then
  fail_ "T4 setup" "could not build the fixture"
else
  O4="$(newtmp)/out"; RC4="$(run_reconf "$P4" "$O4")"
  landed4="$(what_landed "$P4" | tr '\n' ' ')"
  said4=no;  grep -qi "other" "$O4" && said4=yes
  falsewarn4=no; grep -q 'CI template not found' "$O4" && falsewarn4=yes
  if [ "$RC4" = 0 ] && [ -z "$landed4" ] && [ "$said4" = yes ] && [ "$falsewarn4" = no ]; then
    pass "T4 (rc=0, nothing written, host named, no false missing-template warning)"
  else
    fail_ "T4" "rc=$RC4 landed=[$landed4] named_other=$said4 false_missing_warning=$falsewarn4 (want 0/empty/yes/no)"
  fi
fi

# ── T5: unknown host — REFUSED, at non-zero rc, writing nothing ─────────────
# This case was written the other way first — asserting a warned fallback to
# GitHub, following init.sh's generate_ci. It is inverted deliberately; the
# reasoning is on `# BL-262-RECONFIG-CI-FAIL-CLOSED` in the script. In short:
# the resolver this fix asks (`host_pipeline_resolve`) fails closed at rc 4 BY
# DESIGN, and its comment names the failure it exists to prevent — a
# mis-recorded host silently producing a GitHub-shaped answer. A fallback here
# would write a GitHub-shaped ci.yml into a project that is not on GitHub and
# report `[OK]`, which trades this entry's silent no-op for a silent wrong
# write.
#
# THE ASSERTION IS THREE-PART ON PURPOSE. "rc != 0" alone would be satisfied by
# any crash; "wrote nothing" alone is satisfied by the DEFECT, which writes
# nothing on every host. Only rc + an empty destination set + a message that
# names the offending value together describe a refusal rather than a failure.
echo "T5: an unrecognised host is refused — nothing written, non-zero rc, value named"
S5="$(newtmp)/src"; P5="$(newtmp)/proj"
if ! mk_src "$S5" || ! mk_proj "$P5" "$S5" gitea; then
  fail_ "T5 setup" "could not build the fixture"
else
  O5="$(newtmp)/out"; RC5="$(run_reconf "$P5" "$O5")"
  landed5="$(what_landed "$P5" | tr '\n' ' ')"
  named5=no;  grep -q "gitea" "$O5" && named5=yes
  valid5=no;  grep -q 'github, gitlab, bitbucket' "$O5" && valid5=yes
  claimed5=no; grep -q 'Reconfiguration complete' "$O5" && claimed5=yes
  if [ "$RC5" != 0 ] && [ -z "$landed5" ] && [ "$named5" = yes ] \
     && [ "$valid5" = yes ] && [ "$claimed5" = no ]; then
    pass "T5 (rc=$RC5, refused, nothing written, named 'gitea' and the valid set, claimed no success)"
  else
    fail_ "T5" "rc=$RC5 landed=[$landed5] named_host=$named5 named_valid_set=$valid5 claimed_complete=$claimed5 (want non-zero/empty/yes/yes/no)"
  fi
fi

# ── T5b: the refusal is distinguishable from a MISSING host.sh ──────────────
# `## BL-231:` is the absent-vs-unreadable family. A refusal that says the same
# thing whether the host is wrong or the library is gone sends the operator to
# the wrong repair, so the two arms must be separable from the output alone.
echo "T5b: a missing scripts/lib/host.sh refuses with a DIFFERENT message"
S5B="$(newtmp)/src"; P5B="$(newtmp)/proj"
SCR5B="$(newtmp)/scripts"
if ! mk_src "$S5B" || ! cp -Rp "$REPO_ROOT/scripts" "$SCR5B" 2>/dev/null; then
  fail_ "T5b setup" "could not build the fixture"
else
  rm -f "$SCR5B/lib/host.sh"
  if ! mk_proj "$P5B" "$S5B" github "$SCR5B"; then
    fail_ "T5b setup" "could not build the project fixture"
  else
    O5B="$(newtmp)/out"; RC5B="$(run_reconf "$P5B" "$O5B")"
    landed5b="$(what_landed "$P5B" | tr '\n' ' ')"
    namedlib=no; grep -q 'lib/host.sh' "$O5B" && namedlib=yes
    # Must NOT reuse the unknown-host wording: the host here is perfectly valid.
    wronghost=no; grep -q 'Unrecognised git host' "$O5B" && wronghost=yes
    if [ "$RC5B" != 0 ] && [ -z "$landed5b" ] && [ "$namedlib" = yes ] && [ "$wronghost" = no ]; then
      pass "T5b (rc=$RC5B, refused, named the missing library, did not blame the host)"
    else
      fail_ "T5b" "rc=$RC5B landed=[$landed5b] named_library=$namedlib blamed_host=$wronghost (want non-zero/empty/yes/no)"
    fi
  fi
fi

# ── T6: a GENUINELY absent template warns, and names the HOST-QUALIFIED path ─
# The pre-fix code also warned — about a path no host ever uses. A warning
# naming `ci/typescript.yml` is indistinguishable to the operator from one
# naming `ci/github/typescript.yml`, but only the second is a real answer.
echo "T6: a genuinely absent template warns and names the host-qualified path"
S6="$(newtmp)/src"; P6="$(newtmp)/proj"
if ! mk_src "$S6" --omit-github-typescript || ! mk_proj "$P6" "$S6" github; then
  fail_ "T6 setup" "could not build the fixture"
else
  O6="$(newtmp)/out"; RC6="$(run_reconf "$P6" "$O6")"
  landed6="$(what_landed "$P6" | tr '\n' ' ')"
  warned6=no; grep -q 'CI template not found' "$O6" && warned6=yes
  qualified6=no; grep -q 'ci/github/typescript\.yml' "$O6" && qualified6=yes
  if [ "$warned6" = yes ] && [ "$qualified6" = yes ] && [ -z "$landed6" ]; then
    pass "T6 (warned, named ci/github/typescript.yml, wrote nothing)"
  else
    fail_ "T6" "rc=$RC6 warned=$warned6 host_qualified_path=$qualified6 landed=[$landed6] (want yes/yes/empty); warn line: $(grep -m1 'CI template not found' "$O6" || echo none)"
  fi
fi

# ── T7 / T7b: an ABSENT host is refused, not defaulted to github ────────────
# A first cut of this arm defaulted an absent host to github, and T7 pinned
# that. It contradicted T5 directly: T5 refuses an UNRECOGNISED host on the
# stated grounds that guessing GitHub is how a mis-recorded host silently
# produces a GitHub-shaped answer, while the absent case guessed exactly that.
# Nothing in the framework defaults a missing host to github — host.sh refuses
# at rc 2 naming the backfill, and verify-install.sh's _detect_pipeline_host
# infers from the git remote and yields `other`. The arm now delegates to the
# first of those, so BOTH absent shapes stop.
#
# The two shapes are separate cases because host.sh distinguishes them and the
# operator's next move differs: no manifest at all is a broken project; a
# manifest without `.host` is a pre-host-field project with a named repair.
echo "T7: a project with NO manifest is refused, not defaulted to github"
S7="$(newtmp)/src"; P7="$(newtmp)/proj"
if ! mk_src "$S7" || ! mk_proj "$P7" "$S7" --no-manifest; then
  fail_ "T7 setup" "could not build the fixture"
else
  O7="$(newtmp)/out"; RC7="$(run_reconf "$P7" "$O7")"
  got7="$(cat "$P7/.github/workflows/ci.yml" 2>/dev/null || echo '<<ABSENT>>')"
  landed7="$(what_landed "$P7" | paste -sd' ' -)"
  if [ "$RC7" -ne 0 ] && [ "$got7" = "<<ABSENT>>" ] && [ -z "$landed7" ] \
     && ! grep -q "CI pipeline regenerated" "$O7"; then
    pass "T7 (rc=$RC7, refused, nothing written, no GitHub default)"
  else
    fail_ "T7" "wanted a refusal with nothing written; rc=$RC7 ci.yml=[$got7] landed=[${landed7:-none}]"
  fi
fi

echo "T7b: a manifest with no 'host' field is refused, naming the backfill"
S7B="$(newtmp)/src"; P7B="$(newtmp)/proj"
if ! mk_src "$S7B" || ! mk_proj "$P7B" "$S7B" --empty-manifest; then
  fail_ "T7b setup" "could not build the fixture"
else
  O7B="$(newtmp)/out"; RC7B="$(run_reconf "$P7B" "$O7B")"
  landed7b="$(what_landed "$P7B" | paste -sd' ' -)"
  # host.sh owns the remedy text; this asserts the arm lets it through rather
  # than swallowing it, which is what makes the refusal actionable.
  if [ "$RC7B" -ne 0 ] && [ -z "$landed7b" ] \
     && grep -q -- "--backfill-host" "$O7B"; then
    pass "T7b (rc=$RC7B, refused, nothing written, host.sh's backfill remedy reached the operator)"
  else
    fail_ "T7b" "wanted a refusal naming --backfill-host; rc=$RC7B landed=[${landed7b:-none}] out=[$(head -2 "$O7B" | tr '\n' ' ')]"
  fi
fi

# ── Mutants ─────────────────────────────────────────────────────────────────
# EMBEDDED, not run by hand. A mutant recorded in prose is re-run by nobody; a
# mutant in the suite is re-run by CI on every push, which is the only version
# that keeps working after the branch that wrote it is merged.
#
# Each builds a MIRROR of scripts/ with one arm of the fix undone, asserts the
# mutation LANDED (parses, and changed the expected number of lines), and then
# re-drives the real script from that mirror. Each names the cases that must
# SURVIVE it as well as those that must die — a mutant that kills everything
# proves the cases are not separable.
echo ""
echo "=== Mutants ==="

# mk_mirror <destdir> <perl-expr> <min-changed> <label> — sets MIRROR on
# success; returns 1 and records the failure otherwise.
#
# IT REPORTS THROUGH A GLOBAL, NOT THROUGH STDOUT, AND THAT IS NOT STYLE. A
# first cut echoed the mirror path and was called as `MM1="$(mk_mirror ...)"`.
# `fail_` writes to stdout, so on the setup-failure path its diagnostic was
# CAPTURED INTO MM1 instead of printed — the caller then saw a non-empty string,
# read it as success, and ran the mutant against an unmutated mirror. The
# FAILED counter was lost with it, because the increment happened in the
# substitution's subshell. Measured: at base every mutant reported a case-level
# failure and not one reported a setup failure, which is precisely backwards.
MIRROR=""
mk_mirror() {
  local dest="$1" expr="$2" minch="$3" label="$4" changed
  MIRROR=""
  cp -Rp "$REPO_ROOT/scripts" "$dest" 2>/dev/null || {
    fail_ "$label setup" "could not mirror scripts/"; return 1; }
  perl -pi -e "$expr" "$dest/reconfigure-project.sh" || {
    fail_ "$label setup" "the mutation could not be applied"; return 1; }
  if ! bash -n "$dest/reconfigure-project.sh" 2>/dev/null; then
    fail_ "$label setup" "the mutated mirror does not parse"; return 1
  fi
  changed=$(diff "$REPO_ROOT/scripts/reconfigure-project.sh" "$dest/reconfigure-project.sh" \
            | grep -c '^[<>]')
  if [ "$changed" -lt "$minch" ]; then
    fail_ "$label setup" "the mutation did not land (only $changed changed line(s), wanted >= $minch) — the arm this mutant reverts is not present"
    return 1
  fi
  MIRROR="$dest"
  return 0
}

# ── M1: drop the per-host segment from the TEMPLATE path ────────────────────
# The first half of the defect, restored on its own. The destination logic is
# untouched, so `other` still returns early and an unrecognised host is still
# refused — only the cases that read template CONTENT notice.
echo "M1: the \$host segment removed from the template path"
mk_mirror "$(newtmp)/scripts" 's{ci/\$ci_host/\$ci_template}{ci/\$ci_template}' 2 M1
MM1="$MIRROR"
if [ -n "$MM1" ]; then
  m1_died=0
  for h in github gitlab bitbucket; do
    SM="$(newtmp)/src"; PM="$(newtmp)/proj"
    mk_src "$SM" && mk_proj "$PM" "$SM" "$h" "$MM1" || continue
    OM="$(newtmp)/out"; run_reconf "$PM" "$OM" >/dev/null
    [ -z "$(what_landed "$PM")" ] && m1_died=$((m1_died + 1))
  done
  # T4 (other) and T5 (refusal) must be unaffected: neither reaches the path.
  SM4="$(newtmp)/src"; PM4="$(newtmp)/proj"; m1_other_ok=no
  if mk_src "$SM4" && mk_proj "$PM4" "$SM4" other "$MM1"; then
    OM4="$(newtmp)/out"
    [ "$(run_reconf "$PM4" "$OM4")" = 0 ] && grep -q 'CI template not found' "$OM4" \
      || m1_other_ok=yes
  fi
  if [ "$m1_died" -eq 3 ] && [ "$m1_other_ok" = yes ]; then
    pass "M1 (all three host cases go dark; the 'other' arm correctly survives)"
  else
    fail_ "M1" "expected all 3 host cases to write nothing and 'other' to survive; hosts_dark=$m1_died other_survived=$m1_other_ok"
  fi
fi

# ── M2: restore the hardcoded GitHub destination ────────────────────────────
# The half an existence check cannot see. The SOURCE resolves correctly, so a
# real file is written every time — it is written to the wrong place, with the
# wrong host's content. Only T2/T3's content pin and stray-file assertion catch
# it; T1 (github) passes, because for GitHub the hardcode is the right answer.
echo "M2: the destination hardcoded back to .github/workflows/ci.yml"
mk_mirror "$(newtmp)/scripts" 's{cp "\$template_path" "\$ci_target"}{cp "\$template_path" ".github/workflows/ci.yml"}; s{mkdir -p "\$\(dirname "\$ci_target"\)"}{mkdir -p .github/workflows}' 2 M2
MM2="$MIRROR"
if [ -n "$MM2" ]; then
  m2_stray=0; m2_github_ok=no
  for h in gitlab bitbucket; do
    SM="$(newtmp)/src"; PM="$(newtmp)/proj"
    mk_src "$SM" && mk_proj "$PM" "$SM" "$h" "$MM2" || continue
    OM="$(newtmp)/out"; run_reconf "$PM" "$OM" >/dev/null
    [ -f "$PM/.github/workflows/ci.yml" ] && m2_stray=$((m2_stray + 1))
  done
  SMG="$(newtmp)/src"; PMG="$(newtmp)/proj"
  if mk_src "$SMG" && mk_proj "$PMG" "$SMG" github "$MM2"; then
    OMG="$(newtmp)/out"; run_reconf "$PMG" "$OMG" >/dev/null
    [ "$(cat "$PMG/.github/workflows/ci.yml" 2>/dev/null)" = "$GH_MARK" ] && m2_github_ok=yes
  fi
  if [ "$m2_stray" -eq 2 ] && [ "$m2_github_ok" = yes ]; then
    pass "M2 (gitlab and bitbucket both get a stray GitHub file; T1 correctly survives)"
  else
    fail_ "M2" "expected 2 stray GitHub files on non-GitHub hosts and github unaffected; stray=$m2_stray github_ok=$m2_github_ok"
  fi
fi

# ── M3: fall back to GitHub instead of refusing an unrecognised host ────────
# This is the decision `# BL-262-RECONFIG-CI-FAIL-CLOSED` records, expressed as
# a mutant so the decision is enforced rather than merely written down. It is
# the shape the fix ALMOST shipped with, following init.sh's generate_ci.
echo "M3: an unrecognised host normalised to GitHub instead of refused"
mk_mirror "$(newtmp)/scripts" 's{^(\s*)print_fail "Unrecognised git host.*$}{$1ci_host="github"; ci_target=".github/workflows/ci.yml"; print_warn "Unknown host; defaulting to GitHub"}; s{^\s*\[ -n "\$ci_resolve_err" \].*$}{}' 1 M3
MM3="$MIRROR"
if [ -n "$MM3" ]; then
  # Strip the remaining refusal body so the arm actually falls through.
  perl -0pi -e 's{(print_warn "Unknown host; defaulting to GitHub"\n)(?:\s*echo "       .*?\n)+\s*exit 1\n}{$1}s' "$MM3/reconfigure-project.sh"
  if bash -n "$MM3/reconfigure-project.sh" 2>/dev/null; then
    SM5="$(newtmp)/src"; PM5="$(newtmp)/proj"
    if mk_src "$SM5" && mk_proj "$PM5" "$SM5" gitea "$MM3"; then
      OM5="$(newtmp)/out"; RCM5="$(run_reconf "$PM5" "$OM5")"
      landedm5="$(what_landed "$PM5" | tr '\n' ' ')"
      if [ "$RCM5" = 0 ] && [ -n "$landedm5" ]; then
        pass "M3 (the GitHub fallback returns: rc=0 and [$landedm5] written for host 'gitea' — T5 is what refuses it)"
      else
        fail_ "M3" "the fallback mutant did not restore the old behaviour: rc=$RCM5 landed=[$landedm5]"
      fi
    fi
  else
    fail_ "M3 setup" "the mutated mirror does not parse"
  fi
fi


# ── M4: default an ABSENT host to GitHub instead of refusing ────────────────
# The companion to M3, and the one that catches the self-contradiction this
# rework removed: the arm shipped a first cut that refused an UNRECOGNISED host
# (M3) while defaulting an ABSENT one to github. Both halves now stop, and both
# halves have a mutant, so neither can silently come back.
echo "M4: an absent host defaulted to GitHub instead of refused"
mk_mirror "$(newtmp)/scripts" 's{^(\s*)print_fail "Cannot determine the git host.*$}{$1ci_host="github"}' 1 M4
MM4="$MIRROR"
if [ -n "$MM4" ]; then
  # Strip the rest of the refusal body so the arm falls through to the default.
  perl -0pi -e 's{(\s*ci_host="github"\n)(?:\s*echo "       .*?\n)+\s*exit 1\n}{$1}s' "$MM4/reconfigure-project.sh"
  if bash -n "$MM4/reconfigure-project.sh" 2>/dev/null; then
    SM6="$(newtmp)/src"; PM6="$(newtmp)/proj"
    if mk_src "$SM6" && mk_proj "$PM6" "$SM6" --no-manifest "$MM4"; then
      OM6="$(newtmp)/out"; RCM6="$(run_reconf "$PM6" "$OM6")"
      landedm6="$(what_landed "$PM6" | tr '\n' ' ')"
      if [ "$RCM6" = 0 ] && [ -n "$landedm6" ]; then
        pass "M4 (the absent-host GitHub default returns: rc=0 and [$landedm6] written with no recorded host — T7 is what refuses it)"
      else
        fail_ "M4" "the absent-host default mutant did not restore the old behaviour: rc=$RCM6 landed=[$landedm6]"
      fi
    else
      fail_ "M4 setup" "could not build the mutant's fixture"
    fi
  else
    fail_ "M4 setup" "the mutated mirror does not parse"
  fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] && exit 0
exit 1
