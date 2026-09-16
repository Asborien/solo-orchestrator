#!/usr/bin/env bash
# scripts/install-contributor-hooks.sh — BL-096 (ergonomics F10): the
# contributor hook bootstrap as ONE command instead of a copy-pasted recipe.
#
#   bash scripts/install-contributor-hooks.sh
#
# init.sh installs gates for USER projects; contributors working on the
# framework itself would otherwise have to hand-run a recipe from
# CONTRIBUTING.md, and discovering that at PR time means local commits never
# faced the gates CI enforces.
#
# ── BL-239: THIS SCRIPT USED TO INSTALL A NO-OP AND SAY OTHERWISE ───────────
# It did `cp scripts/pre-commit-gate.sh .git/hooks/pre-commit` and printed
# "Local commits now face the same gates CI runs." They faced NOTHING.
# `pre-commit-gate.sh` is a PreToolUse hook: with no flags it reads tool-input
# JSON on stdin and "no output" means ALLOW. Git invokes a pre-commit hook with
# NO arguments and no such JSON, so every commit took the allow path and exited
# 0 SILENTLY. Measured, hermetically, both ways on the same fixture commit:
#
#   cp the gate (the old behaviour)      -> commit rc=0, 0 lines of gate output
#   the hook init.sh generates (below)   -> commit rc=0, 3 lines: the gitleaks
#                                           and semgrep arms actually ran, and
#                                           semgrep reported SAST NOT ENFORCED
#                                           per `# BL-112-SAST-NOTRUN`
#
# A false claim inside the one script whose entire job is installing
# enforcement. That is why this now emits the SAME hooks init.sh does, from the
# SAME library — `scripts/lib/hook-templates.sh` is the one owner, so the
# contributor hook and the generated-project hook cannot drift:
#
#   .git/hooks/pre-commit   soif_write_precommit_hook       (gitleaks, SAST,
#                                                            test co-location,
#                                                            blocked-commit ledger)
#   .git/hooks/commit-msg   soif_emit_tdd_commitmsg_block   (BL-072 TDD ordering
#                                                            + BL-006 Build-Loop
#                                                            message check)
#
# The commit-msg half was previously not installed AT ALL for contributors, so
# the TDD-ordering gate and the Build-Loop message check never ran on a
# framework contributor's commits either.
#
# Idempotent — re-running refreshes both hooks to the current templates.
#
# Refuses outside a framework checkout root: it must find `./.git` and the
# template library at the invocation directory, so it cannot stamp framework
# hooks into an unrelated repo by accident.
set -euo pipefail

ROOT="$(pwd)"

if [ ! -d "$ROOT/.git" ] || [ ! -f "$ROOT/scripts/lib/hook-templates.sh" ]; then
  echo "[FAIL] not a framework checkout root: need ./.git and ./scripts/lib/hook-templates.sh here." >&2
  echo "  Run from the root of your solo-orchestrator clone:" >&2
  echo "    bash scripts/install-contributor-hooks.sh" >&2
  exit 1
fi

# BL-261-CONTRIB-SEMGREP-PRECONDITIONS — the SAST arm's config is laid below as a
# symlink to the tracked template (the BL-261 laying block, further down). Both
# things that can stop that are checked HERE, before a single hook is written:
# a refusal must leave the checkout exactly as it found it. The paths live
# outside the laying block so the summary can still name the file when the
# block is mutated away in the suite.
_sg_src="$ROOT/templates/semgrep/soif-dom-sinks.yml"
_sg_dst="$ROOT/.semgrep/soif-dom-sinks.yml"
if [ ! -f "$_sg_src" ]; then
  echo "[FAIL] $_sg_src is missing — it is tracked, so this checkout is incomplete; refusing to install hooks whose SAST arm could not resolve its config." >&2
  exit 1
fi
if [ -e "$_sg_dst" ] && [ ! -L "$_sg_dst" ]; then
  echo "[FAIL] $_sg_dst exists and is NOT a symlink — refusing to overwrite it. Remove it and re-run to link the tracked template." >&2
  exit 1
fi

# shellcheck source=./lib/hook-templates.sh
. "$ROOT/scripts/lib/hook-templates.sh"

for _fn in soif_write_precommit_hook soif_emit_tdd_commitmsg_block soif_write_prepush_hook; do
  if ! command -v "$_fn" >/dev/null 2>&1; then
    echo "[FAIL] $ROOT/scripts/lib/hook-templates.sh does not provide $_fn — refusing to install a hook this script cannot generate." >&2
    exit 1
  fi
done

mkdir -p "$ROOT/.git/hooks"

# BL-096-CONTRIB-HOOK-INSTALL: the load-bearing action — the REAL hooks, from
# the same emitters init.sh uses, executable, at the paths git consults.
soif_write_precommit_hook "$ROOT/.git/hooks/pre-commit"                # BL-239-CONTRIB-PRECOMMIT

CM="$ROOT/.git/hooks/commit-msg"                                       # BL-239-CONTRIB-COMMITMSG
if [ ! -f "$CM" ]; then
  printf '%s\n' '#!/usr/bin/env bash' > "$CM"
fi
if grep -qF "$SOIF_TDD_OPEN" "$CM" 2>/dev/null; then
  : # already present — idempotent, same predicate init.sh uses
else
  soif_emit_tdd_commitmsg_block >> "$CM"
fi
chmod +x "$CM"

# BL-243-CONTRIB-PREPUSH: the framework repo had NO installation path for the
# push-time review gate, so the repo whose review record motivated the gate got
# it only by hand — and the hand-installed copy went stale silently, degrading
# open with no warning while the shipped body degraded loudly. Refreshed
# unconditionally here, like the pre-commit body above: this script is the
# contributor's "make my hooks current" command, and a hook it declines to
# refresh is the drift it exists to end. init.sh keeps its never-clobber rule,
# because there the existing hook may be the operator's own.
soif_write_prepush_hook "$ROOT/.git/hooks/pre-push"                    # BL-243-CONTRIB-PREPUSH

# BL-261-CONTRIB-SEMGREP-CONFIG-BEGIN — the emitted pre-commit hook --config's
# `.semgrep/soif-dom-sinks.yml` by repo-relative path (# BL-131-DOM-SINKS),
# passed UNCONDITIONALLY so a missing file makes semgrep exit >=2 and the
# NOTRUN arm fires loudly. Only init.sh lays that file, in GENERATED projects —
# so in this checkout the SAST arm was PERMANENTLY inert and every commit
# printed `SAST NOT ENFORCED` (`## BL-261:`). Lay it here as a RELATIVE SYMLINK
# to the tracked template: one source of truth, no second copy for `## BL-175:`
# to lose track of, the hook text (and the # BL-194-HOOK-SEMGREP-POLICY parity
# `tests/test-bl147-ci-template-integrity.sh` derives from it) untouched, and
# a template that moves DANGLES the link so the arm goes loud, never quiet.
# `.semgrep/` is gitignored — a local artifact like .git/hooks, never tracked.
# A REGULAR file at the path is somebody's own work — refused UP FRONT with the
# other preconditions (# BL-261-CONTRIB-SEMGREP-PRECONDITIONS), before any hook
# is written, so a refusal leaves the checkout exactly as it was.
mkdir -p "$ROOT/.semgrep"
rm -f "$_sg_dst"                                   # only ever a symlink or absent here
ln -s ../templates/semgrep/soif-dom-sinks.yml "$_sg_dst"
if [ ! -f "$_sg_dst" ] || ! cmp -s "$_sg_src" "$_sg_dst"; then
  echo "[FAIL] $_sg_dst does not resolve to templates/semgrep/soif-dom-sinks.yml after linking." >&2
  exit 1
fi
echo "[OK] .semgrep/soif-dom-sinks.yml -> templates/semgrep/soif-dom-sinks.yml (symlink, untracked; the SAST arm's config resolves here)"
# BL-261-CONTRIB-SEMGREP-CONFIG-END

# VERIFY WHAT WAS INSTALLED, rather than reporting on what was intended. A hook
# that is not executable, or that git will not run, is the defect this entry is
# about; saying "installed" without looking is how it survived.
_fail=0
for h in pre-commit commit-msg pre-push; do
  p="$ROOT/.git/hooks/$h"
  if [ ! -x "$p" ]; then echo "[FAIL] $p is not executable" >&2; _fail=1; continue; fi
  if [ ! -s "$p" ]; then echo "[FAIL] $p is empty" >&2; _fail=1; continue; fi
  echo "[OK] .git/hooks/$h installed ($(wc -c < "$p" | tr -d ' ') bytes, executable)"
done
[ "$_fail" -eq 0 ] || exit 1

echo ""
echo "[OK] Contributor hooks installed from scripts/lib/hook-templates.sh —"
echo "     the same emitters init.sh uses for generated projects."
echo "     Re-run any time to refresh all three to the current templates."
echo ""

# REPORT WHICH ARMS CAN ACTUALLY FIRE HERE, rather than listing the arms the
# hook contains. Listing them is what the old message did — "Local commits now
# face the same gates CI runs" was true about the FILE and false about the
# BEHAVIOUR. These hooks are shaped for a GENERATED project, and in the
# framework checkout some of their arms have nothing to run against.
echo "     Arms, as they stand in THIS checkout:"
if command -v gitleaks >/dev/null 2>&1; then
  echo "       gitleaks        LIVE   ($(gitleaks version 2>&1 | head -1))"
else
  echo "       gitleaks        INERT  (not installed — the arm WARNs, never blocks)"
fi
# BL-261-SEMGREP-LIVE-PREDICATE — LIVE means the arm can actually FIRE here:
# the tool is on PATH AND the config the hook names resolves. Either alone is
# INERT, and the line says which (a directory existing is not a config).
if command -v semgrep >/dev/null 2>&1 && [ -f "$_sg_dst" ]; then
  echo "       SAST (semgrep)  LIVE   ($(semgrep --version 2>/dev/null | head -1); config -> templates/semgrep/soif-dom-sinks.yml)"
elif ! command -v semgrep >/dev/null 2>&1; then
  echo "       SAST (semgrep)  INERT  (semgrep is not installed — the arm WARNs"
  echo "                              'SAST NOT ENFORCED' on every commit, never blocks)"
else
  echo "       SAST (semgrep)  INERT  (.semgrep/soif-dom-sinks.yml does not resolve —"
  echo "                              the arm WARNs 'SAST NOT ENFORCED', never blocks)"
fi
echo "       BL-006 msg gate INERT  (framework repo, not a scaffolded project —"
echo "                              the hook says so itself and allows the commit)"
echo ""
echo "     So in the framework repo this is a SECRET-DETECTION gate plus SAST over"
echo "     the staged markup files the DOM-sink ruleset scopes (*.html, *.vue —"
echo "     \`## BL-261:\`). It is still not 'the same gates CI runs': the message"
echo "     gate is inert here and CI runs no SAST over this repo's own source."
echo "     CI is the authority; see \`## BL-239:\`."
