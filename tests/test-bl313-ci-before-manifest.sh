#!/usr/bin/env bash
# tests/test-bl313-ci-before-manifest.sh
#
# `## BL-313:` — A GENERATED GITHUB CI WORKFLOW MUST BE GREEN BEFORE THE
# LANGUAGE MANIFEST EXISTS, AND MUST NOT BE WEAKENED ONCE IT DOES.
#
# Every ci/github/<lang>.yml opens its `test` job with a toolchain that
# assumes the language manifest is already committed: setup-node with
# `cache: 'npm'` (which fails hard — "Dependencies lock file is not found" —
# before `npm ci` even runs), `pip install -r requirements.txt`, `./gradlew
# build`, `dotnet restore`, `flutter pub get`, `go build`, `cargo build`,
# `swift package resolve`. A project born from init.sh has none of those
# files until Phase 2, so the `test` check is red on every pull request the
# operator opens in Phase 0 and 1 — the intake, the manifesto, every
# approval-log row. Measured 2026-09-22 on a project scaffolded from
# f8841de: the setup-node step failed at 00:57:19Z with that exact error and
# the job never reached a `run:` step.
#
# The fix guards every manifest-dependent step with the template's own
# idiom — `if: hashFiles('<manifest>') != ''`, already used on the three
# governance steps — and adds ONE notice step (`== ''`) that says what was
# skipped and why. hashFiles returns '' when nothing matches (GitHub Actions
# expressions reference), so the guards are false on an empty tree and true
# the moment the manifest lands; nothing that exists today is weakened, and
# a package.json committed WITHOUT its lockfile still fails setup-node loudly,
# which is the correct verdict under the framework's pin-and-commit rule.
#
# CASES — all on the real tree, `test` job only (the `sast` job scans the
# tree and needs no manifest):
#   T0  the template list is derived (find), meets a floor of 10 (9 language templates plus other.yml), and every
#       template has a census row — a new language cannot slip in unguarded
#   T1  exactly one notice step per template, guarded `== ''` on the census
#       manifest, and its body carries a `::notice::` annotation; the step
#       carries no key but name, if and run (review finding R-480-3:
#       continue-on-error or working-directory on it turns a Phase 2 tree
#       with no manifest green, and no other check could see either)
#   T2  every toolchain step — everything that is not checkout, not the
#       notice, not the secret scan and not `Governance -` — is guarded
#       `!= ''` on the same manifest; floor of 3 such steps per template.
#       python.yml's install, tool and security steps are gated on its
#       decision step (`## BL-318:` G3) instead; they count as guarded only
#       when that `deps` step carries exactly the census guard, and the
#       fail-closed step's condition must be that guard `&&` #499's (Karl,
#       2026-10-16)
#   T3  checkout and the gitleaks secret scan are NOT guarded, and no
#       governance step's own guard names the manifest (the fix must not
#       turn a Phase-0 tree into an unscanned one)
#   T4  a shell evaluation of the guards: over an EMPTY fixture every
#       toolchain step skips and the notice runs; with the first census
#       sample file present every toolchain step runs and the notice skips.
#       This evaluates the `hashFiles(<patterns>) != ''` / `== ''` forms the
#       templates carry, python's installer gates, and nothing else — `act`
#       is not available here, so the workflow itself is not executed; the
#       assertion is on the rendered YAML plus this evaluation of its
#       conditions. For python the decision step's own script IS executed
#       over the fixture, so the installer it would choose is measured, not
#       re-implemented: over an empty tree it is never reached; with
#       requirements.txt it chooses pip, and the uv-path steps and the fail-closed
#       step are `alt`.
#   T5  past Phase 1 a missing manifest FAILS, it does not skip green: the
#       notice step's `run:` script is extracted and EXECUTED under
#       `"$BASH" -e -o pipefail` (stricter than the runner's default `bash -e {0}`, under the
#       interpreter this suite itself runs under) against nine
#       fixtures — `.claude/phase-state.json` at current_phase 3, 2 and
#       "2" quoted (rc 1, `::error::`; R-480-2: every other phase reader
#       accepts a quoted phase), at 1 and with no phase-state (rc 0,
#       `::notice::`), a new project's manifest at phase 0 (rc 0,
#       `::notice::`), and an ADOPTED project's record, indented as jq
#       writes it or minified, at phase 0 and 1 (rc 1, an `::error::` that
#       says it is adopted) and at 3 (rc 1). A review of the first cut
#       found the gap: a Poetry or Pipenv project (the framework's own
#       Python guidance) has no requirements.txt, and on a Phase 3 tree
#       every toolchain step skipped and the check went green — "a check
#       that cannot run must not pass". Review finding R-480-1 found the
#       same for adoption, which always lands at phase 0: an adopted
#       project whose manifest is none of the census files (setup.py, a
#       nested package.json) went from red to green with nothing built.
#   T7  the other half of R-480-1: with a manifest present an adopted tree
#       simulates exactly as a new one does, every census sample.
#   T6  one case per language: every manifest name in the census, placed
#       ALONE in a fixture, enables every toolchain step and skips the
#       notice. The census carries the manifests the harness itself
#       recognises (process-checklist.sh's lockfile list and the platform
#       modules' lockfile notes, plus uv.lock for python), so a compliant
#       project is never "manifest absent". For python a manifest the
#       decision step cannot install from (pyproject.toml, Pipfile or
#       uv.lock alone) stops the job there — the step exits non-zero (a loud
#       red, never a skip; #499's suite pins its ::error:: text) — and the
#       samples must reach both the pip path
#       (requirements.txt) and the uv path (pyproject.toml+uv.lock).
# MUTANTS (on a mirror of templates/, never the real tree): remove one
# guard, invert one guard, guard the secret scan, delete the notice step,
# delete the phase check's `exit 1`, drop one manifest name from every
# guard of one template, drop the manifest guard from python's fail-closed
# condition, delete python's decision-step guard, add continue-on-error to
# typescript's notice step and working-directory to go's and python's (R-480-3),
# delete java's adoption `exit 1` (R-480-1), put back dart's unquoted phase read
# (R-480-2). Each proves it landed (changed-line count) and names the case
# that fails.
#
# WHY `other.yml` IS OUT: its toolchain steps are TODO comments and its
# dependency-audit step exits 1 by design until the operator configures a
# scanner — there is no manifest to guard on and the red is deliberate.
#
# The census below is the SPEC, in bl254's documented-census idiom — it is
# not derived from the templates, because a manifest read off the file it
# is meant to check would agree with itself. Row format:
#   <lang>|<hashFiles argument list, verbatim>|<samples, space-separated>
# A sample is one file name, or several joined by `+` placed together. The
# first sample is what T4 uses; T6 uses each in turn.
#
# REGISTRATION: content-pin only — no init.sh on any executed line, not an
# aggregator -> BOTH tests/full-project-test-suite.sh and the tests.yml
# unit list. Hermetic: reads tracked files, writes only under mktemp.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GH_DIR="$REPO_ROOT/templates/pipelines/ci/github"

PASSED=0
FAILED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }

TOPTMP="$(mktemp -d)"
trap 'rm -rf "$TOPTMP"' EXIT INT TERM
newtmp() { mktemp -d "$TOPTMP/fixXXXXXX"; }

_num() { case "$1" in ''|null|*[!0-9]*) printf '0\n' ;; *) printf '%s\n' "$1" ;; esac }
_changed_lines() {
  local n=""
  n=$(diff "$1" "$2" 2>/dev/null | grep -c '^[<>]')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}
# count_in <file> <fixed-string> — occurrences, never a pipe (no SIGPIPE under pipefail)
count_in() { local n=""; n=$(grep -cF -- "$2" "$1" 2>/dev/null); _num "$n"; }

CENSUS_FILE="$TOPTMP/census.txt"
cat > "$CENSUS_FILE" <<'EOF'
typescript|'package.json'|package.json
python|'requirements.txt', 'pyproject.toml', 'Pipfile', 'uv.lock'|requirements.txt pyproject.toml Pipfile uv.lock pyproject.toml+uv.lock
java|'**/*.gradle*', '**/pom.xml'|build.gradle.kts pom.xml
kotlin|'**/*.gradle*', '**/pom.xml'|build.gradle.kts pom.xml
go|'go.mod'|go.mod
rust|'Cargo.toml'|Cargo.toml
csharp|'**/*.sln', '**/*.csproj'|App.sln App.csproj
dart|'pubspec.yaml'|pubspec.yaml
swift|'Package.swift'|Package.swift
EOF
census_args()    { awk -F'|' -v l="$1" '$1==l {print $2; exit}' "$CENSUS_FILE"; }
census_samples() { awk -F'|' -v l="$1" '$1==l {print $3; exit}' "$CENSUS_FILE"; }
census_sample()  { local s=""; s="$(census_samples "$1")"; printf '%s\n' "${s%% *}"; }

# template_list <github-templates-dir> — the ONE derivation every case uses:
# regular *.yml files directly in the directory, sorted, dotfiles excluded.
# A first cut used find here and a `*.yml` glob in the gap walker; an
# AppleDouble `._x.yml` sidecar (macOS tar into a container) was then counted
# by one and skipped by the other, and the tallies disagreed. One list.
template_list() {
  find "$1" -maxdepth 1 -type f -name '*.yml' ! -name '.*' 2>/dev/null | LC_ALL=C sort
}

# steps_of <template> — one line per step of the `test` job:
#   <name-or-uses>\t<if-expression or ->\t<1 if the body carries ::notice::>\t<id or ->\t<keys>
# <keys> is every key of the step, comma-joined in order (the `- ` line's own
# key first), so a key the step must not carry can be seen (R-480-3).
# Scoped to the `test` job (indent-2 key) so the `sast` job's steps never
# enter the census; a step opens at indent-6 `- `, its keys sit at indent 8.
steps_of() {
  awk '
    function flush() { if (name != "") print name "\t" cond "\t" note "\t" id "\t" keys; name = "" }
    BEGIN { injob = 0; name = ""; cond = "-"; note = 0; id = "-"; keys = "" }
    /^  test:[[:space:]]*$/ { injob = 1; next }
    injob && /^  [A-Za-z_][A-Za-z0-9_-]*:/ { flush(); injob = 0 }
    injob && /^      - / {
      flush()
      name = $0
      keys = $0; sub(/^      - /, "", keys); sub(/:.*/, "", keys)
      sub(/^      - (name|uses):[[:space:]]*/, "", name)
      cond = "-"; note = 0; id = "-"
      next
    }
    injob && /^        [A-Za-z_][A-Za-z0-9_-]*:/ { k = $0; sub(/^        /, "", k); sub(/:.*/, "", k); keys = keys "," k }
    injob && /^        if:[[:space:]]/ { cond = $0; sub(/^        if:[[:space:]]*/, "", cond) }
    injob && /^        id:[[:space:]]/ { id = $0; sub(/^        id:[[:space:]]*/, "", id) }
    injob && /::notice::/ { note = 1 }
    END { flush() }
  ' "$1"
}

# THE PYTHON DECISION STEP (`## BL-318:` G3, PR #499). python.yml installs
# through one step, `id: deps` ("Find the dependency file"), and gates every
# install, tool and security step on its answer instead of on the manifest:
# `steps.deps.outputs.installer == 'uv'` or `== 'pip'`, plus a fail-closed step
# for no answer. Per Karl's 2026-10-16 decision the decision step carries the
# census guard itself, and the fail-closed condition carries it in front, so a
# tree with no manifest skips the decision and every step gated on it. Those
# gates count as guarded only when the template's `deps` step carries exactly
# the census guard (manifest_gaps), and simulate EXECUTES the template's own
# decision script over the fixture to learn which installer it would choose.
GATE_INST_UV="steps.deps.outputs.installer == 'uv'"
GATE_INST_PIP="steps.deps.outputs.installer == 'pip'"
INST_NONE_TAIL=" && steps.deps.outputs.installer != 'uv' && steps.deps.outputs.installer != 'pip'"

# deps_script <template> — the `run: |` block of the step whose `id:` is
# `deps`, de-indented. Empty if the template has none.
deps_script() {
  awk '
    /^      - / { instep = 0; inrun = 0 }
    /^        id:[[:space:]]*deps[[:space:]]*$/ { instep = 1 }
    instep && /^        run:[[:space:]]*\|[[:space:]]*$/ { inrun = 1; next }
    instep && inrun && /^          / { line = $0; sub(/^          /, "", line); print line; next }
    instep && inrun && /^[[:space:]]*$/ { next }
    instep && inrun { inrun = 0 }
  ' "$1"
}

# run_deps <script-file> <fixture-root> — executes the decision script as a
# `shell: bash` step runs (it declares one): prints uv or pip (its
# GITHUB_OUTPUT answer), fail (non-zero: the job stops there, loudly), or
# empty (it exited 0 and answered nothing).
run_deps() {
  local rc=0 out="" gh=""
  gh="$(mktemp "$TOPTMP/ghout.XXXXXX")"
  ( cd "$2" && GITHUB_OUTPUT="$gh" "$BASH" --noprofile --norc -eo pipefail "$1" ) >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then printf 'fail\n'; return 0; fi
  out="$(awk '/^installer=/ { sub(/^installer=/, ""); print; exit }' "$gh")"
  printf '%s\n' "${out:-empty}"
}

# notice_script <template> <want-skip-cond> — the `run: |` block of the step
# whose `if:` is <want-skip-cond>, de-indented (the block sits at indent 10),
# so T5 can EXECUTE it. Empty output if the step or its block is absent.
notice_script() {
  awk -v want="$2" '
    BEGIN { instep = 0; inrun = 0 }
    /^      - / { instep = 0; inrun = 0 }
    /^        if:[[:space:]]/ { c = $0; sub(/^        if:[[:space:]]*/, "", c); if (c == want) instep = 1 }
    instep && /^        run:[[:space:]]*\|[[:space:]]*$/ { inrun = 1; next }
    instep && inrun && /^          / { line = $0; sub(/^          /, "", line); print line; next }
    instep && inrun && /^[[:space:]]*$/ { next }
    instep && inrun { inrun = 0 }
  ' "$1"
}

# run_notice <script-file> <fixture-root> — executes the notice script the way
# the runner does (`-e -o pipefail`, cwd = the checked-out tree) under THIS
# suite's interpreter (`$BASH`), so the version the suite is run with is the
# version the subject runs under — PATH bash would silently be another one.
# Prints "<rc> <annotation kind>", the kind being error, notice, or none.
run_notice() {
  local rc=0 out="" kind="none"
  out="$(cd "$2" && "$BASH" -e -o pipefail "$1" 2>&1)" || rc=$?
  case "$out" in
    *"::error::"*)  kind="error" ;;
    *"::notice::"*) kind="notice" ;;
  esac
  printf '%s %s\n' "$rc" "$kind"
}

# manifest_gaps <github-templates-dir> — one line per violation:
#   <file>: <class>: <detail>
# classes: census-missing notice-count notice-manifest notice-text notice-key
#          guard-missing guard-wrong toolchain-floor checkout-guarded
#          gitleaks-guarded governance-manifest gate-unanchored
manifest_gaps() {
  local d="$1" f="" lang="" args="" want_run="" want_skip="" steps="" name="" cond="" note="" sid=""
  local n_notice=0 n_tool=0 short="" list="" deps_ok=0 k="" skeys=""
  list="$TOPTMP/gaps.list.$$"
  template_list "$d" > "$list"
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    lang="${f##*/}"; lang="${lang%.yml}"
    [ "$lang" = "other" ] && continue
    args="$(census_args "$lang")"
    if [ -z "$args" ]; then
      printf '%s: census-missing: no census row for language %s\n' "$lang.yml" "$lang"
      continue
    fi
    want_run="hashFiles($args) != ''"
    want_skip="hashFiles($args) == ''"
    steps="$TOPTMP/steps.$lang.$$"
    steps_of "$f" > "$steps"
    n_notice=0; n_tool=0; deps_ok=0
    # a step gated on the decision is guarded only through a decision step
    # that itself carries exactly the census guard
    W="$want_run" awk -F'\t' '$4 == "deps" && $2 == ENVIRON["W"] { f = 1 } END { exit !f }' "$steps" && deps_ok=1
    while IFS="$(printf '\t')" read -r name cond note sid skeys; do
      short="${name%% #*}"
      case "$name" in
        actions/checkout@*)
          [ "$cond" = "-" ] || printf '%s: checkout-guarded: checkout carries if: %s\n' "$lang.yml" "$cond" ;;
        'Security - Secret detection (gitleaks)')
          [ "$cond" = "-" ] || printf '%s: gitleaks-guarded: secret scan carries if: %s\n' "$lang.yml" "$cond" ;;
        'Governance - '*)
          case "$cond" in
            *"$args"*) printf '%s: governance-manifest: %s is guarded on the manifest (%s)\n' "$lang.yml" "$short" "$cond" ;;
          esac ;;
        *)
          if [ "$cond" = "$want_skip" ]; then
            n_notice=$((n_notice + 1))
            [ "$note" = "1" ] || printf '%s: notice-text: the skip step (%s) prints no ::notice:: annotation\n' "$lang.yml" "$short"
            # R-480-3: the skip step carries name, if and run and nothing else.
            # continue-on-error would let its exit 1 through; working-directory,
            # shell or env would run its check somewhere else or otherwise; each
            # turns a Phase 2 tree with no manifest green.
            for k in $(printf '%s\n' "$skeys" | tr ',' ' '); do
              case "$k" in name|if|run) ;; *) printf '%s: notice-key: the skip step (%s) carries %s:, and may carry only name, if and run\n' "$lang.yml" "$short" "$k" ;; esac
            done
          elif [ "$cond" = "$want_run" ]; then
            n_tool=$((n_tool + 1))
          elif [ "$cond" = "$GATE_INST_UV" ] || [ "$cond" = "$GATE_INST_PIP" ] || [ "$cond" = "$want_run$INST_NONE_TAIL" ]; then
            [ "$deps_ok" = 1 ] || printf '%s: gate-unanchored: %s is gated on the decision step, which is not guarded %s\n' "$lang.yml" "$short" "$want_run"
          elif [ "$cond" = "-" ]; then
            printf '%s: guard-missing: %s has no if: guard\n' "$lang.yml" "$short"
          else
            case "$cond" in
              *"== ''"*) printf '%s: notice-manifest: a skip step (%s) is guarded on %s, not on %s\n' "$lang.yml" "$short" "$cond" "$want_skip" ;;
              *)         printf '%s: guard-wrong: %s carries if: %s, expected %s\n' "$lang.yml" "$short" "$cond" "$want_run" ;;
            esac
          fi ;;
      esac
    done < "$steps"
    [ "$n_notice" -eq 1 ] || printf '%s: notice-count: %s skip step(s) guarded %s, expected exactly 1\n' "$lang.yml" "$n_notice" "$want_skip"
    [ "$n_tool" -ge 3 ]   || printf '%s: toolchain-floor: only %s guarded toolchain step(s), floor 3\n' "$lang.yml" "$n_tool"
  done < "$list"
}

# hf_nonempty <root> <hashFiles-args> — rc 0 iff any file under <root> matches
# any pattern in the argument list. The list is what the templates carry:
# single-quoted literals, comma-separated. A leading `**/` means any depth;
# anything else is a path from the root. This is the only form evaluated.
hf_nonempty() {
  local root="$1" rest="$2" pat="" hit=""
  while [ -n "$rest" ]; do
    pat="${rest%%,*}"
    if [ "$pat" = "$rest" ]; then rest=""; else rest="${rest#*,}"; fi
    pat="${pat#"${pat%%[! ]*}"}"
    pat="${pat#\'}"; pat="${pat%\'}"
    case "$pat" in
      '**/'*)
        hit="$(find "$root" -type f -name "${pat#\*\*/}" -print 2>/dev/null | head -1)"
        [ -n "$hit" ] && return 0 ;;
      *) [ -f "$root/$pat" ] && return 0 ;;
    esac
  done
  return 1
}

# eval_guard <root> <if-expression> — prints run|skip|alt|unknown. SIM_INST
# holds what the decision step chose in this simulation (uv, pip, or empty when
# it did not run): a step gated on the decision skips with it when it did not
# run, and is `alt` when the answer it gave rules the step out (the other
# installer's path; the fail-closed step once an installer was chosen).
SIM_INST=""
eval_guard() {
  local root="$1" cond="$2" args="" want=""
  case "$cond" in
    -) printf 'run\n'; return ;;
    "$GATE_INST_UV"|"$GATE_INST_PIP")
      want="${cond#steps.deps.outputs.installer == \'}"; want="${want%\'}"
      if [ -z "$SIM_INST" ]; then printf 'skip\n'
      elif [ "$SIM_INST" = "$want" ]; then printf 'run\n'
      else printf 'alt\n'; fi ;;
    "hashFiles("*") != ''$INST_NONE_TAIL")
      args="${cond#hashFiles(}"; args="${args%%) != \'\'*}"
      if ! hf_nonempty "$root" "$args"; then printf 'skip\n'
      elif [ "$SIM_INST" = uv ] || [ "$SIM_INST" = pip ]; then printf 'alt\n'
      else printf 'run\n'; fi ;;
    "${INST_NONE_TAIL# && }")
      # the fail-closed condition WITHOUT the manifest guard: it runs whenever
      # no installer was chosen, an empty tree included
      if [ "$SIM_INST" = uv ] || [ "$SIM_INST" = pip ]; then printf 'alt\n'; else printf 'run\n'; fi ;;
    "hashFiles("*") != ''")
      args="${cond#hashFiles(}"; args="${args%) != \'\'}"
      if hf_nonempty "$root" "$args"; then printf 'run\n'; else printf 'skip\n'; fi ;;
    "hashFiles("*") == ''")
      args="${cond#hashFiles(}"; args="${args%) == \'\'}"
      if hf_nonempty "$root" "$args"; then printf 'skip\n'; else printf 'run\n'; fi ;;
    *) printf 'unknown\n' ;;
  esac
}

# simulate <template> <lang> <root> — prints
#   "<tool_run> <tool_skip> <notice_verdict> <unknown> <decision> <alt>"
# decision: none (the template has no `deps` step), skip (its guard was
# false), uv or pip (what the template's own decision script chose, executed
# over <root>), fail (it exited non-zero: the job stops there, loudly, and no
# later step is counted), empty (it exited 0 and chose nothing).
# alt: steps not run because of the answer the decision gave (the other
# installer's path, and the fail-closed step once an installer was chosen).
simulate() {
  local f="$1" lang="$2" root="$3" args="" want_skip="" steps="" name="" cond="" note="" sid="" v="" ds="" skeys=""
  local tr=0 ts=0 nv="absent" unk=0 alt=0 dec="none"
  args="$(census_args "$lang")"
  want_skip="hashFiles($args) == ''"
  steps="$(mktemp "$TOPTMP/sim.XXXXXX")"
  steps_of "$f" > "$steps"
  SIM_INST=""
  while IFS="$(printf '\t')" read -r name cond note sid skeys; do
    case "$name" in
      actions/checkout@*|'Security - Secret detection (gitleaks)'|'Governance - '*) continue ;;
    esac
    v="$(eval_guard "$root" "$cond")"
    if [ "$cond" = "$want_skip" ]; then
      nv="$v"
      continue
    fi
    case "$v" in run) tr=$((tr + 1)) ;; skip) ts=$((ts + 1)) ;; alt) alt=$((alt + 1)) ;; *) unk=$((unk + 1)) ;; esac
    if [ "$sid" = "deps" ]; then
      if [ "$v" = "run" ]; then
        ds="$(mktemp "$TOPTMP/deps.XXXXXX")"
        deps_script "$f" > "$ds"
        dec="$(run_deps "$ds" "$root")"
        case "$dec" in uv|pip) SIM_INST="$dec" ;; fail) break ;; esac
      else
        dec="skip"
      fi
    fi
  done < "$steps"
  SIM_INST=""
  printf '%s %s %s %s %s %s\n' "$tr" "$ts" "$nv" "$unk" "$dec" "$alt"
}

# mk_mirror <dir> — templates/ only; enough for every function above
mk_mirror() {
  mkdir -p "$1" || return 1
  cp -Rp "$REPO_ROOT/templates" "$1/" || return 1
  return 0
}

echo "=== T — the invariants on the real tree ==="

# T0 — derived list, floor, census coverage
GH_LIST="$TOPTMP/gh.txt"
template_list "$GH_DIR" > "$GH_LIST"
n_gh=$(_num "$(grep -c . "$GH_LIST")")
n_lang=$((n_gh - 1))
if [ "$n_gh" -ge 10 ]; then
  pass "T0 — $n_gh github CI templates found (floor 10 incl. other.yml)"
else
  fail_ "T0" "found $n_gh github CI templates, expected >=10 — the derivation is vacuous"
fi
census_miss=""
while IFS= read -r f; do
  lang="${f##*/}"; lang="${lang%.yml}"
  [ "$lang" = "other" ] && continue
  [ -n "$(census_args "$lang")" ] || census_miss="$census_miss $lang"
done < "$GH_LIST"
census_orphan=""
while IFS='|' read -r lang _ _; do
  [ -f "$GH_DIR/$lang.yml" ] || census_orphan="$census_orphan $lang"
done < "$CENSUS_FILE"
if [ -z "$census_miss" ] && [ -z "$census_orphan" ]; then
  pass "T0 — census covers every language template ($n_lang) and names no absent one"
else
  fail_ "T0" "census/template mismatch — templates without a row:${census_miss:- none}; rows without a template:${census_orphan:- none}"
fi

GAPS="$TOPTMP/gaps.txt"
manifest_gaps "$GH_DIR" > "$GAPS"

# T1 — the notice step
n_t1=$(( $(count_in "$GAPS" ': notice-count: ') + $(count_in "$GAPS" ': notice-manifest: ') + $(count_in "$GAPS" ': notice-text: ') + $(count_in "$GAPS" ': notice-key: ') ))
if [ "$n_t1" -eq 0 ]; then
  pass "T1 — every language template ($n_lang) carries exactly one ::notice:: skip step guarded == '' on its manifest"
else
  fail_ "T1" "$n_t1 notice violation(s): $(grep -E ': notice-(count|manifest|text|key): ' "$GAPS" | head -3 | tr '\n' ';' | cut -c1-240)"
fi

# T2 — every toolchain step guarded
n_t2=$(( $(count_in "$GAPS" ': guard-missing: ') + $(count_in "$GAPS" ': guard-wrong: ') + $(count_in "$GAPS" ': toolchain-floor: ') + $(count_in "$GAPS" ': census-missing: ') + $(count_in "$GAPS" ': gate-unanchored: ') ))
n_guarded=0
n_gated=0
while IFS= read -r f; do
  lang="${f##*/}"; lang="${lang%.yml}"
  [ "$lang" = "other" ] && continue
  args="$(census_args "$lang")"
  [ -n "$args" ] || continue
  steps_of "$f" > "$TOPTMP/t2.txt"
  n_guarded=$((n_guarded + $(count_in "$TOPTMP/t2.txt" "	hashFiles($args) != ''	")))
  n_gated=$((n_gated + $(count_in "$TOPTMP/t2.txt" "	steps.deps.outputs.installer == ") + $(count_in "$TOPTMP/t2.txt" "	hashFiles($args) != ''$INST_NONE_TAIL	")))
done < "$GH_LIST"
if [ "$n_t2" -eq 0 ]; then
  pass "T2 — every toolchain step is guarded != '' on its manifest ($n_guarded guarded directly across $n_lang templates, plus $n_gated python step(s) gated on a decision step that is)"
else
  fail_ "T2" "$n_t2 guard violation(s): $(grep -E ': (guard-missing|guard-wrong|toolchain-floor|census-missing|gate-unanchored): ' "$GAPS" | head -3 | tr '\n' ';' | cut -c1-240)"
fi

# T3 — nothing weakened: checkout, secret scan and governance stay unconditional on the manifest
n_t3=$(( $(count_in "$GAPS" ': checkout-guarded: ') + $(count_in "$GAPS" ': gitleaks-guarded: ') + $(count_in "$GAPS" ': governance-manifest: ') ))
if [ "$n_t3" -eq 0 ]; then
  pass "T3 — checkout, the gitleaks secret scan and the governance steps are not guarded on the manifest in any template"
else
  fail_ "T3" "$n_t3 weakening(s): $(grep -E ': (checkout-guarded|gitleaks-guarded|governance-manifest): ' "$GAPS" | head -3 | tr '\n' ';' | cut -c1-240)"
fi

# T4 — evaluate the guards over an empty tree and over a scaffolded one
# mk_sample <dir> <sample> — a sample is one file name, or several joined by +
mk_sample() {
  local p=""
  for p in $(printf '%s\n' "$2" | tr '+' ' '); do : > "$1/$p" || return 1; done
}
t4_bad=""
t4_tool=0
t4_alt=0
while IFS= read -r f; do
  lang="${f##*/}"; lang="${lang%.yml}"
  [ "$lang" = "other" ] && continue
  [ -n "$(census_args "$lang")" ] || continue
  E="$(newtmp)"; M="$(newtmp)"
  sample="$(census_sample "$lang")"
  mk_sample "$M" "$sample"
  set -- $(simulate "$f" "$lang" "$E")
  e_run="$1"; e_skip="$2"; e_notice="$3"; e_unk="$4"; e_dec="$5"; e_alt="$6"
  set -- $(simulate "$f" "$lang" "$M")
  m_run="$1"; m_skip="$2"; m_notice="$3"; m_unk="$4"; m_dec="$5"; m_alt="$6"
  # empty: nothing runs, the notice does, and a decision step is never reached
  if [ "$e_run" -ne 0 ] || [ "$e_skip" -lt 3 ] || [ "$e_notice" != "run" ] || [ "$e_unk" -ne 0 ] || [ "$e_alt" -ne 0 ] \
     || { [ "$e_dec" != "none" ] && [ "$e_dec" != "skip" ]; }; then
    t4_bad="$t4_bad $lang(empty:run=$e_run,skip=$e_skip,notice=$e_notice,unknown=$e_unk,decision=$e_dec)"
  fi
  # the first sample: nothing skipped for want of a manifest, and where there
  # is a decision step it chose an installer (the other installer's steps are alt)
  if [ "$m_skip" -ne 0 ] || [ "$m_run" -lt 3 ] || [ "$m_notice" != "skip" ] || [ "$m_unk" -ne 0 ] \
     || { [ "$m_dec" != "none" ] && [ "$m_dec" != "uv" ] && [ "$m_dec" != "pip" ]; }; then
    t4_bad="$t4_bad $lang(with-$sample:run=$m_run,skip=$m_skip,notice=$m_notice,unknown=$m_unk,decision=$m_dec)"
  fi
  t4_tool=$((t4_tool + m_run))
  t4_alt=$((t4_alt + m_alt))
done < "$GH_LIST"
if [ -z "$t4_bad" ]; then
  pass "T4 — over an empty tree every toolchain step skips, no decision step is reached, and the notice runs; with the first manifest present $t4_tool toolchain steps run, the notice skips, and $t4_alt step(s) do not run because of the installer chosen (the other path, and the fail-closed step) ($n_lang templates)"
else
  fail_ "T4" "guard evaluation disagrees with the intent:$t4_bad"
fi

# T5 — the notice step EXECUTED: past Phase 1 it fails, and an ADOPTED project
# fails at any phase (R-480-1: adoption lands at phase 0 with its code already
# there, so "nothing to build yet" is never true of it); only a new project
# before Phase 2 gets the notice.
# mk_phase_fixture <dir> <phase|none> — <phase> is written as given, so `"2"`
# writes a quoted phase (R-480-2: every other reader accepts one)
mk_phase_fixture() {
  mkdir -p "$1/.claude" || return 1
  [ "$2" = "none" ] && return 0
  printf '{\n  "current_phase": %s,\n  "phase_gates": {}\n}\n' "$2" > "$1/.claude/phase-state.json"
}
# mk_manifest <dir> <adopted|adopted-min|new> — .claude/manifest.json. `adopted`
# is the shape adoption writes: soif_adoption_stamp merges
# `.adoption = {schemaVersion: 2, adopted: true, ...}` with jq, whose default
# output is this indented form (`# BF-ADOPT-STAMP-MERGE`); `adopted-min` is the
# same record minified; `new` is a project init.sh made, with no adoption block.
mk_manifest() {
  mkdir -p "$1/.claude" || return 1
  case "$2" in
    adopted)     printf '{\n  "host": "github",\n  "adoption": {\n    "schemaVersion": 2,\n    "adopted": true,\n    "adoptedAt": "2026-10-16T00:00:00Z",\n    "adoptedAtCommit": "0000000000000000000000000000000000000000",\n    "scannerReportSha256": ""\n  }\n}\n' ;;
    adopted-min) printf '{"host":"github","adoption":{"schemaVersion":2,"adopted":true,"adoptedAt":"2026-10-16T00:00:00Z"}}\n' ;;
    new)         printf '{\n  "host": "github",\n  "mode": "greenfield"\n}\n' ;;
  esac > "$1/.claude/manifest.json"
}
# notice_said <script-file> <fixture-root> — what the notice script printed
notice_said() { ( cd "$2" && "$BASH" -e -o pipefail "$1" 2>&1 ); }
# t5_check <template> <lang> — prints violations, one per line
t5_check() {
  local f="$1" lang="$2" args="" want_skip="" script="" fx="" v="" spec="" ph="" mf="" want="" said=""
  args="$(census_args "$lang")"
  want_skip="hashFiles($args) == ''"
  script="$TOPTMP/notice.$lang.$$.sh"
  notice_script "$f" "$want_skip" > "$script"
  if [ ! -s "$script" ]; then
    printf '%s: no run: | block on the notice step\n' "$lang.yml"; return
  fi
  if [ "$(count_in "$script" 'current_phase')" -lt 1 ] || [ "$(count_in "$script" 'exit 1')" -lt 2 ]; then
    printf '%s: notice script does not read current_phase and exit 1 twice (phase, adoption)\n' "$lang.yml"
  fi
  # <phase>/<manifest>/<expected>
  for spec in 3/-/1error 2/-/1error '"2"/-/1error' 1/-/0notice none/-/0notice \
              0/new/0notice 0/adopted/1adopted 1/adopted-min/1adopted 3/adopted/1error; do
    ph="${spec%%/*}"; mf="${spec#*/}"; mf="${mf%%/*}"; want="${spec##*/}"
    fx="$(newtmp)"; mk_phase_fixture "$fx" "$ph"
    [ "$mf" = "-" ] || mk_manifest "$fx" "$mf"
    v="$(run_notice "$script" "$fx")"
    case "$want" in
      1error)   [ "$v" = "1 error" ]  || printf '%s: at current_phase %s (manifest %s) expected "1 error", got "%s"\n' "$lang.yml" "$ph" "$mf" "$v" ;;
      0notice)  [ "$v" = "0 notice" ] || printf '%s: at current_phase %s (manifest %s) expected "0 notice", got "%s"\n' "$lang.yml" "$ph" "$mf" "$v" ;;
      1adopted)
        said="$(notice_said "$script" "$fx")"
        case "$v:$said" in
          "1 error:"*"This project was adopted"*) ;;
          *) printf '%s: adopted (%s) at current_phase %s expected "1 error" naming the adoption, got "%s"\n' "$lang.yml" "$mf" "$ph" "$v" ;;
        esac ;;
    esac
  done
}
t5_bad="$TOPTMP/t5.txt"; : > "$t5_bad"
while IFS= read -r f; do
  lang="${f##*/}"; lang="${lang%.yml}"
  [ "$lang" = "other" ] && continue
  [ -n "$(census_args "$lang")" ] || continue
  t5_check "$f" "$lang" >> "$t5_bad"
done < "$GH_LIST"
if [ ! -s "$t5_bad" ]; then
  pass "T5 — executed: every notice step exits 1 with ::error:: at current_phase 2 (bare or quoted) and 3 and for an adopted project at phase 0 or 1 (indented or minified record), and exits 0 with ::notice:: for a new project at phase 0 or 1 or with no phase-state ($n_lang templates, 9 fixtures each)"
else
  fail_ "T5" "$(grep -c . "$t5_bad") violation(s): $(head -3 "$t5_bad" | tr '\n' ';' | cut -c1-240)"
fi

# T7 — R-480-1's other half: with a manifest present, adoption changes nothing.
# Every census sample, simulated with and without an adopted record at phase 0,
# gives the same result, and the notice skips in both.
t7_bad=""; t7_n=0
while IFS= read -r f; do
  lang="${f##*/}"; lang="${lang%.yml}"
  [ "$lang" = "other" ] && continue
  [ -n "$(census_args "$lang")" ] || continue
  for sample in $(census_samples "$lang"); do
    M="$(newtmp)"; mk_sample "$M" "$sample"
    MA="$(newtmp)"; mk_sample "$MA" "$sample"; mk_phase_fixture "$MA" 0; mk_manifest "$MA" adopted
    r_new="$(simulate "$f" "$lang" "$M")"; r_ad="$(simulate "$f" "$lang" "$MA")"
    t7_n=$((t7_n + 1))
    set -- $r_ad
    if [ "$r_new" != "$r_ad" ] || [ "$3" != "skip" ]; then
      t7_bad="$t7_bad $lang/$sample(new=[$r_new] adopted=[$r_ad])"
    fi
  done
done < "$GH_LIST"
if [ -z "$t7_bad" ]; then
  pass "T7 — with a manifest present an adopted tree runs exactly what a new one runs, notice skipped ($t7_n samples across $n_lang templates)"
else
  fail_ "T7" "adoption changed a tree that has its manifest:$t7_bad"
fi

# T6 — one case per language: each census manifest name ALONE enables the
# toolchain — the notice skips and nothing is skipped for want of a manifest.
# Where the template has a decision step (python), a manifest it cannot
# install from stops the job at that step, loudly (it exits non-zero; #499's
# suite pins its ::error:: text), never a silent green; and across the samples
# the decision must reach both installers, so the uv and pip paths are each
# proven reachable.
while IFS= read -r f; do
  lang="${f##*/}"; lang="${lang%.yml}"
  [ "$lang" = "other" ] && continue
  [ -n "$(census_args "$lang")" ] || continue
  t6_bad=""; t6_n=0; t6_loud=""; t6_seen=""
  for sample in $(census_samples "$lang"); do
    M="$(newtmp)"; mk_sample "$M" "$sample"
    set -- $(simulate "$f" "$lang" "$M")
    t6_n=$((t6_n + 1))
    t6_seen="$t6_seen $5"
    case "$5" in
      fail)
        if [ "$2" -ne 0 ] || [ "$1" -lt 1 ] || [ "$3" != "skip" ] || [ "$4" -ne 0 ]; then
          t6_bad="$t6_bad $sample(run=$1,skip=$2,notice=$3,unknown=$4,decision=$5)"
        else
          t6_loud="$t6_loud $sample"
        fi ;;
      none|uv|pip)
        if [ "$2" -ne 0 ] || [ "$1" -lt 3 ] || [ "$3" != "skip" ] || [ "$4" -ne 0 ]; then
          t6_bad="$t6_bad $sample(run=$1,skip=$2,notice=$3,unknown=$4,decision=$5)"
        fi ;;
      *) t6_bad="$t6_bad $sample(decision=$5)" ;;
    esac
  done
  case "$t6_seen" in
    *" none"*) ;;
    *) case "$t6_seen" in *" uv"*) ;; *) t6_bad="$t6_bad [no sample reaches the uv path:$t6_seen]" ;; esac
       case "$t6_seen" in *" pip"*) ;; *) t6_bad="$t6_bad [no sample reaches the pip path:$t6_seen]" ;; esac ;;
  esac
  if [ -z "$t6_bad" ]; then
    pass "T6-$lang — each of $t6_n manifest sample(s) alone enables the toolchain and skips the notice${t6_loud:+; the decision step stops the job loudly for:$t6_loud}"
  else
    fail_ "T6-$lang" "a recognised manifest alone still skips the toolchain:$t6_bad"
  fi
done < "$GH_LIST"

echo "=== MT — mutation proofs on a mirror ==="

# MT1 — remove the guard from the setup-node step in typescript.yml: T2 must name it.
MT1="$(newtmp)/fw"
if ! mk_mirror "$MT1"; then
  fail_ "MT1 setup" "could not mirror the framework"
else
  tgt="$MT1/templates/pipelines/ci/github/typescript.yml"
  before="$(mktemp "$TOPTMP/mt1.XXXXXX")"; cp "$tgt" "$before"
  awk '
    /^      - uses: actions\/setup-node@/ { innode = 1; print; next }
    innode && /^        if: hashFiles\(.package\.json.\) != ..$/ { innode = 0; next }
    /^      - / { innode = 0 }
    { print }
  ' "$before" > "$tgt"
  if [ "$(_changed_lines "$before" "$tgt")" -ne 1 ]; then
    fail_ "MT1 setup" "the mutation did not remove exactly one line — the setup-node guard is not in the shape this suite expects"
  else
    manifest_gaps "$MT1/templates/pipelines/ci/github" > "$TOPTMP/mt1.gaps"
    if [ "$(count_in "$TOPTMP/mt1.gaps" 'typescript.yml: guard-missing: actions/setup-node@')" -ge 1 ]; then
      pass "MT1 (MUTATION) — with the setup-node guard removed, T2 names typescript.yml's setup-node step"
    else
      fail_ "MT1 (MUTATION)" "removing the guard changed nothing — T2 is not reading the step it claims to"
    fi
  fi
fi

# MT2 — invert one toolchain guard in go.yml (!= -> ==): T1 sees two notice
# steps and T2 sees one toolchain step fewer; either alone would be a
# different defect, so both are asserted.
MT2="$(newtmp)/fw"
if ! mk_mirror "$MT2"; then
  fail_ "MT2 setup" "could not mirror the framework"
else
  tgt="$MT2/templates/pipelines/ci/github/go.yml"
  before="$(mktemp "$TOPTMP/mt2.XXXXXX")"; cp "$tgt" "$before"
  awk '
    /^      - name: Build$/ { inbuild = 1; print; next }
    inbuild && /^        if: hashFiles\(.go\.mod.\) != ..$/ { sub(/ != /, " == "); inbuild = 0 }
    /^      - / { inbuild = 0 }
    { print }
  ' "$before" > "$tgt"
  if [ "$(_changed_lines "$before" "$tgt")" -ne 2 ]; then
    fail_ "MT2 setup" "the mutation did not flip exactly one line — go.yml's Build guard is not in the shape this suite expects"
  elif [ "$(count_in "$tgt" "hashFiles('go.mod') == ''")" -ne 2 ]; then
    fail_ "MT2 setup" "the flipped text did not land — expected two == '' guards in the mutant"
  else
    manifest_gaps "$MT2/templates/pipelines/ci/github" > "$TOPTMP/mt2.gaps"
    if [ "$(count_in "$TOPTMP/mt2.gaps" 'go.yml: notice-count: 2 skip step(s)')" -ge 1 ] \
       && [ "$(count_in "$TOPTMP/mt2.gaps" 'go.yml: notice-text: the skip step (Build)')" -ge 1 ]; then
      pass "MT2 (MUTATION) — with one go.yml guard inverted, T1 counts two skip steps and names Build as a skip step with no notice"
    else
      fail_ "MT2 (MUTATION)" "inverting a guard changed nothing T1 can see: $(head -3 "$TOPTMP/mt2.gaps" | tr '\n' ';')"
    fi
  fi
fi

# MT3 — guard the gitleaks secret scan on the manifest in python.yml: T3 must
# refuse it. This is the weakening the fix must never introduce: a Phase-0
# tree with a leaked credential and no requirements.txt would go unscanned.
MT3="$(newtmp)/fw"
if ! mk_mirror "$MT3"; then
  fail_ "MT3 setup" "could not mirror the framework"
else
  tgt="$MT3/templates/pipelines/ci/github/python.yml"
  before="$(mktemp "$TOPTMP/mt3.XXXXXX")"; cp "$tgt" "$before"
  awk '
    { print }
    /^      - name: Security - Secret detection \(gitleaks\)$/ { print "        if: hashFiles('"'"'requirements.txt'"'"') != '"'"''"'"'" }
  ' "$before" > "$tgt"
  if [ "$(_changed_lines "$before" "$tgt")" -ne 1 ]; then
    fail_ "MT3 setup" "the mutation did not add exactly one line"
  else
    manifest_gaps "$MT3/templates/pipelines/ci/github" > "$TOPTMP/mt3.gaps"
    if [ "$(count_in "$TOPTMP/mt3.gaps" 'python.yml: gitleaks-guarded: ')" -ge 1 ]; then
      pass "MT3 (MUTATION) — a manifest guard on the secret scan is refused by T3"
    else
      fail_ "MT3 (MUTATION)" "guarding the secret scan changed nothing — T3 would let a Phase-0 tree go unscanned"
    fi
  fi
fi

# MT4 — delete the notice step from rust.yml: T1 must count zero.
MT4="$(newtmp)/fw"
if ! mk_mirror "$MT4"; then
  fail_ "MT4 setup" "could not mirror the framework"
else
  tgt="$MT4/templates/pipelines/ci/github/rust.yml"
  before="$(mktemp "$TOPTMP/mt4.XXXXXX")"; cp "$tgt" "$before"
  # drop the step whose `if:` is the == '' guard: from its `- name:` line to the line before the next step
  awk '
    /^      - / { if (buf != "" && !drop) printf "%s", buf; buf = ""; drop = 0 }
    /^        if: hashFiles\(.Cargo\.toml.\) == ..$/ { drop = 1 }
    { buf = buf $0 "\n" }
    END { if (buf != "" && !drop) printf "%s", buf }
  ' "$before" > "$tgt"
  if [ "$(_changed_lines "$before" "$tgt")" -lt 3 ]; then
    fail_ "MT4 setup" "the mutation removed fewer than 3 lines — rust.yml's notice step is not in the shape this suite expects"
  elif [ "$(count_in "$tgt" "hashFiles('Cargo.toml') == ''")" -ne 0 ]; then
    fail_ "MT4 setup" "the == '' guard is still present in the mutant"
  else
    manifest_gaps "$MT4/templates/pipelines/ci/github" > "$TOPTMP/mt4.gaps"
    if [ "$(count_in "$TOPTMP/mt4.gaps" 'rust.yml: notice-count: 0 skip step(s)')" -ge 1 ]; then
      pass "MT4 (MUTATION) — with rust.yml's notice step deleted, T1 counts zero and names the file"
    else
      fail_ "MT4 (MUTATION)" "deleting the notice step changed nothing — T1 is not counting what it claims to"
    fi
  fi
fi

# MT5 — delete the phase check's `exit 1` from python.yml's notice step: T5
# must see rc 0 at phase 3 (the green-nobody-reads regression restored).
MT5="$(newtmp)/fw"
if ! mk_mirror "$MT5"; then
  fail_ "MT5 setup" "could not mirror the framework"
else
  tgt="$MT5/templates/pipelines/ci/github/python.yml"
  before="$(mktemp "$TOPTMP/mt5.XXXXXX")"; cp "$tgt" "$before"
  awk '
    /^        if: hashFiles\(.*\) == ..$/ { innotice = 1 }
    /^      - / { innotice = 0 }
    innotice && /^            exit 1$/ { innotice = 0; next }
    { print }
  ' "$before" > "$tgt"
  if [ "$(_changed_lines "$before" "$tgt")" -ne 1 ]; then
    fail_ "MT5 setup" "the mutation did not remove exactly one line — python.yml's notice step has no exit 1 at the expected indent"
  else
    t5_check "$tgt" python > "$TOPTMP/mt5.bad"
    if [ "$(count_in "$TOPTMP/mt5.bad" 'at current_phase 3 (manifest -) expected "1 error", got "0 error"')" -ge 1 ]; then
      pass "MT5 (MUTATION) — with the exit 1 deleted, T5 executes the notice at phase 3 and sees rc 0 — the regression is caught"
    else
      fail_ "MT5 (MUTATION)" "deleting exit 1 changed nothing T5 can see: $(head -2 "$TOPTMP/mt5.bad" | tr '\n' ';')"
    fi
  fi
fi

# MT6 — drop one recognised manifest name ('pyproject.toml') from EVERY guard
# of python.yml, self-consistently: T2 (guard-wrong against the census), T1
# (notice-manifest) and T6-python (pyproject.toml alone skips) must all fire.
MT6="$(newtmp)/fw"
PY_ARGS="'requirements.txt', 'pyproject.toml', 'Pipfile', 'uv.lock'"
if ! mk_mirror "$MT6"; then
  fail_ "MT6 setup" "could not mirror the framework"
else
  tgt="$MT6/templates/pipelines/ci/github/python.yml"
  before="$(mktemp "$TOPTMP/mt6.XXXXXX")"; cp "$tgt" "$before"
  sed "s#hashFiles($PY_ARGS)#hashFiles('requirements.txt', 'Pipfile', 'uv.lock')#" "$before" > "$tgt"
  n_ch="$(_changed_lines "$before" "$tgt")"
  n_g="$(count_in "$before" "hashFiles($PY_ARGS)")"
  if [ "$n_g" -lt 4 ] || [ "$n_ch" -ne $((2 * n_g)) ]; then
    fail_ "MT6 setup" "the mutation changed $n_ch line(s) for $n_g guard line(s) (expected >=4 guards, two changed lines each) — python.yml's guards are not in the census shape"
  elif [ "$(count_in "$tgt" "'pyproject.toml'")" -ne 0 ]; then
    fail_ "MT6 setup" "'pyproject.toml' still present in the mutant"
  else
    manifest_gaps "$MT6/templates/pipelines/ci/github" > "$TOPTMP/mt6.gaps"
    M6="$(newtmp)"; : > "$M6/pyproject.toml"
    set -- $(simulate "$tgt" python "$M6")
    # The mutant's notice no longer matches the census condition, so the
    # simulator counts it among the toolchain (run=1); the real toolchain
    # steps — and every step gated on the decision, which no longer runs —
    # must be the ones that SKIP on a pyproject.toml-only tree. That skip is
    # the regression, and it is what T6-python asserts.
    if [ "$(count_in "$TOPTMP/mt6.gaps" 'python.yml: guard-wrong: ')" -ge 1 ] \
       && [ "$(count_in "$TOPTMP/mt6.gaps" 'python.yml: notice-manifest: ')" -ge 1 ] \
       && [ "$2" -ge 3 ] && [ "$5" = "skip" ]; then
      pass "MT6 (MUTATION) — with pyproject.toml dropped from every python.yml guard ($n_g lines), T2 and T1 name the drift and a pyproject.toml-only tree skips $2 toolchain steps, the decision step among them"
    else
      fail_ "MT6 (MUTATION)" "dropping a manifest name was not caught: gaps=$(grep -c . "$TOPTMP/mt6.gaps") sim=run=$1,skip=$2,notice=$3,decision=$5"
    fi
  fi
fi

# MT7 — python.yml's fail-closed condition loses its manifest guard (back to
# #499's bare form): T2 must name the step, and over an EMPTY tree the step
# now runs — it exits 1, so a Phase 0 project with no dependency file is red
# again, which is the defect this entry fixes.
MT7="$(newtmp)/fw"
if ! mk_mirror "$MT7"; then
  fail_ "MT7 setup" "could not mirror the framework"
else
  tgt="$MT7/templates/pipelines/ci/github/python.yml"
  before="$(mktemp "$TOPTMP/mt7.XXXXXX")"; cp "$tgt" "$before"
  awk '
    /^        if: hashFiles\(.*\) != .. && steps\.deps\.outputs\.installer != .uv. && steps\.deps\.outputs\.installer != .pip.$/ { sub(/hashFiles\(.*\) != .. && /, "") }
    { print }
  ' "$before" > "$tgt"
  if [ "$(_changed_lines "$before" "$tgt")" -ne 2 ] \
     || [ "$(count_in "$tgt" "        if: steps.deps.outputs.installer != 'uv' && steps.deps.outputs.installer != 'pip'")" -ne 1 ]; then
    fail_ "MT7 setup" "the mutation did not turn exactly one guarded fail-closed condition into the bare one"
  else
    manifest_gaps "$MT7/templates/pipelines/ci/github" > "$TOPTMP/mt7.gaps"
    E7="$(newtmp)"
    set -- $(simulate "$tgt" python "$E7")
    if [ "$(count_in "$TOPTMP/mt7.gaps" 'python.yml: guard-wrong: Stop if no installer was chosen')" -ge 1 ] && [ "$1" -ge 1 ]; then
      pass "MT7 (MUTATION) — with the fail-closed condition's manifest guard removed, T2 names the step and over an empty tree $1 step(s) run (the fail-closed step: red at Phase 0) — T4's empty-tree arm"
    else
      fail_ "MT7 (MUTATION)" "removing the fail-closed guard was not caught: gaps=$(head -2 "$TOPTMP/mt7.gaps" | tr '\n' ';') sim=run=$1,skip=$2,decision=$5"
    fi
  fi
fi

# MT8 — delete the decision step's own guard in python.yml: T2 must name the
# step, and over an EMPTY tree the decision step runs and FAILS (#499's
# ::error::), so a Phase 0 project with no dependency file is red again.
MT8="$(newtmp)/fw"
if ! mk_mirror "$MT8"; then
  fail_ "MT8 setup" "could not mirror the framework"
else
  tgt="$MT8/templates/pipelines/ci/github/python.yml"
  before="$(mktemp "$TOPTMP/mt8.XXXXXX")"; cp "$tgt" "$before"
  awk '
    deps && /^        if: hashFiles\(/ { deps = 0; next }
    { deps = ($0 ~ /^        id: deps[[:space:]]*$/); print }
  ' "$before" > "$tgt"
  if [ "$(_changed_lines "$before" "$tgt")" -ne 1 ]; then
    fail_ "MT8 setup" "the mutation did not remove exactly one line — the decision step's guard is not on the line after its id"
  else
    manifest_gaps "$MT8/templates/pipelines/ci/github" > "$TOPTMP/mt8.gaps"
    E8="$(newtmp)"
    set -- $(simulate "$tgt" python "$E8")
    if [ "$(count_in "$TOPTMP/mt8.gaps" 'python.yml: guard-missing: Find the dependency file')" -ge 1 ] && [ "$5" = "fail" ]; then
      pass "MT8 (MUTATION) — with the decision step's guard deleted, T2 names it and over an empty tree the template's own decision script runs and fails — T4's empty-tree arm"
    else
      fail_ "MT8 (MUTATION)" "deleting the decision step's guard was not caught: gaps=$(head -2 "$TOPTMP/mt8.gaps" | tr '\n' ';') sim=run=$1,skip=$2,decision=$5"
    fi
  fi
fi

# ins_notice_key <template> <line> — insert <line> right after the notice
# step's `if: hashFiles(...) == ''` line; rc 0 iff exactly one line was added.
ins_notice_key() {
  local tgt="$1" line="$2" before=""
  before="$(mktemp "$TOPTMP/ink.XXXXXX")"; cp "$tgt" "$before"
  L="$line" awk '{ print } /^        if: hashFiles\(.*\) == ..$/ { print ENVIRON["L"] }' "$before" > "$tgt"
  [ "$(_changed_lines "$before" "$tgt")" -eq 1 ] && [ "$(count_in "$tgt" "$line")" -eq 1 ]
}
# MT9-MT11 — R-480-3: a key the notice step must not carry. Each was measured
# to survive every template suite before the notice-key check, and each turns
# a Phase 2 tree with no manifest green on Actions: continue-on-error lets the
# exit 1 through; working-directory runs the phase and adoption reads where
# .claude/ is not, so both read as "new project, phase 0".
for spec in "MT9|typescript|continue-on-error: true" "MT10|go|working-directory: .github" "MT11|python|working-directory: .github"; do
  id="${spec%%|*}"; rest="${spec#*|}"; mlang="${rest%%|*}"; mkey="${rest#*|}"
  MTD="$(newtmp)/fw"
  if ! mk_mirror "$MTD"; then
    fail_ "$id setup" "could not mirror the framework"
  elif ! ins_notice_key "$MTD/templates/pipelines/ci/github/$mlang.yml" "        $mkey"; then
    fail_ "$id setup" "the mutation did not add exactly one '$mkey' line to $mlang.yml's notice step"
  else
    manifest_gaps "$MTD/templates/pipelines/ci/github" > "$TOPTMP/$id.gaps"
    if [ "$(count_in "$TOPTMP/$id.gaps" "$mlang.yml: notice-key: the skip step")" -ge 1 ] \
       && [ "$(count_in "$TOPTMP/$id.gaps" "carries ${mkey%%:*}:")" -ge 1 ]; then
      pass "$id (MUTATION) — '$mkey' on $mlang.yml's notice step: T1 refuses the key"
    else
      fail_ "$id (MUTATION)" "'$mkey' on $mlang.yml's notice step SURVIVED: $(head -2 "$TOPTMP/$id.gaps" | tr '\n' ';')"
    fi
  fi
done

# MT12 — R-480-1: delete the adoption check's `exit 1` from java.yml's notice
# step: T5 must see an adopted phase-0 tree pass.
MT12="$(newtmp)/fw"
if ! mk_mirror "$MT12"; then
  fail_ "MT12 setup" "could not mirror the framework"
else
  tgt="$MT12/templates/pipelines/ci/github/java.yml"
  before="$(mktemp "$TOPTMP/mt12.XXXXXX")"; cp "$tgt" "$before"
  awk '
    /^        if: hashFiles\(.*\) == ..$/ { innotice = 1; ne = 0 }
    /^      - / { innotice = 0 }
    innotice && /^            exit 1$/ { ne++; if (ne == 2) next }
    { print }
  ' "$before" > "$tgt"
  if [ "$(_changed_lines "$before" "$tgt")" -ne 1 ] || [ "$(count_in "$tgt" 'This project was adopted')" -ne 1 ]; then
    fail_ "MT12 setup" "the mutation did not remove exactly the adoption check's exit 1"
  else
    t5_check "$tgt" java > "$TOPTMP/mt12.bad"
    if [ "$(count_in "$TOPTMP/mt12.bad" 'java.yml: adopted (adopted) at current_phase 0 expected "1 error"')" -ge 1 ]; then
      pass "MT12 (MUTATION) — with the adoption check's exit 1 deleted, T5 sees an adopted phase-0 tree with no build file pass"
    else
      fail_ "MT12 (MUTATION)" "deleting the adoption exit 1 changed nothing T5 can see: $(head -2 "$TOPTMP/mt12.bad" | tr '\n' ';')"
    fi
  fi
fi

# MT13 — R-480-2: put back the first cut's phase read (unquoted digits only)
# in dart.yml: T5's `"current_phase": "2"` fixture must pass again.
MT13="$(newtmp)/fw"
if ! mk_mirror "$MT13"; then
  fail_ "MT13 setup" "could not mirror the framework"
else
  tgt="$MT13/templates/pipelines/ci/github/dart.yml"
  before="$(mktemp "$TOPTMP/mt13.XXXXXX")"; cp "$tgt" "$before"
  NEWP="grep -o '\"current_phase\"[[:space:]]*:[[:space:]]*\"*[0-9][0-9]*\"*' .claude/phase-state.json 2>/dev/null | grep -o '[0-9][0-9]*' | head -1 || true)" \
  OLDP="          phase=\$(grep -o '\"current_phase\"[[:space:]]*:[[:space:]]*[0-9]*' .claude/phase-state.json 2>/dev/null | grep -o '[0-9]*\$' || true)" \
    awk 'index($0, ENVIRON["NEWP"]) { $0 = ENVIRON["OLDP"] } { print }' "$before" > "$tgt"
  if [ "$(_changed_lines "$before" "$tgt")" -ne 2 ] || [ "$(count_in "$tgt" "grep -o '[0-9]*\$' || true)")" -ne 1 ]; then
    fail_ "MT13 setup" "the mutation did not put back exactly one unquoted phase read"
  else
    t5_check "$tgt" dart > "$TOPTMP/mt13.bad"
    if [ "$(count_in "$TOPTMP/mt13.bad" 'dart.yml: at current_phase "2" (manifest -) expected "1 error", got "0 notice"')" -ge 1 ]; then
      pass "MT13 (MUTATION) — with the unquoted phase read put back, T5 sees a quoted current_phase \"2\" pass"
    else
      fail_ "MT13 (MUTATION)" "the unquoted phase read changed nothing T5 can see: $(head -2 "$TOPTMP/mt13.bad" | tr '\n' ';')"
    fi
  fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] && exit 0
exit 1
