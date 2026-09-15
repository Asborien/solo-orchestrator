#!/usr/bin/env bash
# scripts/install-filesystem-gates.sh — BL-030 strict-mode hook installer.
#
# Idempotently adds (or removes) a marked block in .git/hooks/pre-commit
# that sources .git/hooks/framework-gate.sh. Composes with existing chains
# (gitleaks/Semgrep/TDD) without modifying them.
#
# BL-112: this block is APPENDED BELOW the SOIF pre-commit fallback's managed
# region on purpose (BL-099 refreshes that region in place and must not clobber
# this block). That only works because the fallback's terminal exit is CONDITIONAL
# — see `# BL-112-STRICT-GATE` in scripts/lib/hook-templates.sh. An unconditional
# `exit $FAILED` up there makes everything below it dead code, which is exactly
# the bug BL-112 fixes. Pinned by tests/test-bl112-commit-enforcement.sh.
#
# Usage:
#   install-filesystem-gates.sh --install <project_root>
#   install-filesystem-gates.sh --uninstall <project_root>

set -euo pipefail

MARK_OPEN='# >>> SOIF framework gate (BL-030) — do not edit; managed by install-filesystem-gates.sh'
MARK_CLOSE='# <<< SOIF framework gate'

usage() {
  echo "Usage: $0 --install|--uninstall <project_root>" >&2
  exit 2
}

[ $# -lt 2 ] && usage
ACTION="$1"
PROJECT_ROOT="$2"
# BL-209-HOOKSDIR — resolve the hooks dir through git, not a `.git/hooks`
# literal. This arm is 4 of BL-209's 36 census lines; the fix shape is the one
# that entry specifies. Three shapes broke the literal, and all three ended with
# the BL-030 gate absent or unreachable while every diagnostic still read
# strict — `prepare_initial_state_for_commit()` in init.sh runs this with
# >/dev/null 2>&1, so the operator saw only
# "enforcement degraded":
#   1. linked worktree — `.git` is a FILE, so `-d` refused a valid repo
#   2. hooks/ absent (init.templateDir without one) — the first `cat >` died
#   3. core.hooksPath set — gate written where git never looks, silently, exit 0
# Resolved from `--git-common-dir`, NOT `--git-path hooks`. Both agree in a
# normal checkout and in a linked worktree — hooks are per-REPOSITORY, so a
# worktree shares the common gitdir's hooks/ — but they DIVERGE the moment
# `core.hooksPath` is set, because `--git-path hooks` HONOURS it. That is wrong
# for both arms: `--install` refuses a configured hooksPath outright (below), so
# the only directory this script ever writes to is the common one, and
# `--uninstall` must look THERE. Resolved through `--git-path`, uninstall read a
# directory install never used, found no hook, and silently removed nothing —
# leaving the marker block and framework-gate.sh behind to revive if hooksPath
# was later unset. A silent no-op in the enforcement lane. `--git-common-dir`
# cannot be redirected by hooksPath, so the two arms agree by construction.
# THE GUARD ASKS WHETHER PROJECT_ROOT *IS* A REPO ROOT, not whether it sits
# somewhere inside one. An earlier cut of this arm used
# `rev-parse --is-inside-work-tree`, which answers the second question and so
# WIDENED the guard main had:
#   * a plain directory NESTED in a repo returns rc 0, and `--git-common-dir`
#     resolves relative to the REPO rather than to PROJECT_ROOT — so the
#     installer would have written the BL-030 gate into an enclosing repository
#     the caller never named. Reachable through reconfigure-project.sh: a
#     project whose `.git` was removed, sitting inside a monorepo or a tracked
#     ~/code.
#   * a bare repo and a `.git` directory both give rc 0 while PRINTING "false" —
#     the same read-the-status-not-the-value trap `# BL-209-HOOKSPATH-REFUSE`
#     below lectures about, inverted. There the exit status is the answer; here
#     the VALUE is.
# `--show-toplevel` compared by PHYSICAL path is the right question, and it
# keeps every BL-209 win: in a linked worktree `--show-toplevel` IS the worktree
# root, which is exactly what the caller passed.
_soif_top="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)" || _soif_top=""
_soif_top_phys=""
[ -n "$_soif_top" ] && _soif_top_phys="$(cd "$_soif_top" 2>/dev/null && pwd -P)"
# `|| _soif_want_phys=""`: `set -euo pipefail` is on, and a bare `x="$(cd …)"`
# that fails ABORTS the script with no diagnostic — measured, `--install
# /nonexistent` exited 1 with zero bytes of output while main printed
# "[FAIL] not a git repo". The two rev-parse calls above already take their rc
# explicitly; this `cd` did not. An empty value falls into that same arm.
_soif_want_phys="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)" || _soif_want_phys=""   # BL-209-ROOT-RC
if [ -z "$_soif_top_phys" ] || [ "$_soif_top_phys" != "$_soif_want_phys" ]; then
  echo "[FAIL] not a git repo: $PROJECT_ROOT" >&2
  [ -n "$_soif_top_phys" ] && \
    echo "       It sits inside the repository at $_soif_top_phys — refusing to install a gate into a repository you did not name." >&2
  exit 1
fi

# BL-209-FALLBACK-RC — `set -euo pipefail` is on at the top of this script, so a FAILING
# rev-parse would kill the script on the assignment and the literal fallback
# below could never run — the silent-no-diagnostics mode this arm exists to end.
# BL-176's own `_soif_git_path` guards the same call with `|| p=""`; this did
# not, and reproduced as `rc=1` with no output. Take the rc explicitly.
HOOKS_DIR="$(git -C "$PROJECT_ROOT" rev-parse --git-common-dir 2>/dev/null)" || HOOKS_DIR=""
[ -n "$HOOKS_DIR" ] && HOOKS_DIR="$HOOKS_DIR/hooks"
[ -n "$HOOKS_DIR" ] || HOOKS_DIR=".git/hooks"
# `--git-common-dir` returns a path relative to the repo it was asked about
# (absolute in a linked worktree, where it names the common gitdir), so anchor a
# relative answer to PROJECT_ROOT — this script is routinely called from another
# cwd. (An earlier cut of this comment said `--git-path`, which is the option the
# twenty lines above argue is WRONG here and which mutant MU3 exists to reject.
# A reader following the comment reached the opposite conclusion from the code.)
case "$HOOKS_DIR" in
  /*) : ;;
  *)  HOOKS_DIR="$PROJECT_ROOT/$HOOKS_DIR" ;;
esac
HOOK="$HOOKS_DIR/pre-commit"
GATE="$HOOKS_DIR/framework-gate.sh"

write_gate_script() {
  cat > "$GATE" <<'GATE_EOF'
#!/usr/bin/env bash
# .git/hooks/framework-gate.sh — BL-030 strict-mode framework gate.
# Self-no-ops if enforcement_level != "strict" (defense in depth).

set -uo pipefail
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -d "$PROJECT_ROOT/.claude" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

LEVEL=$(jq -r '.enforcement_level // "strict"' "$PROJECT_ROOT/.claude/manifest.json" 2>/dev/null)
[ "$LEVEL" != "strict" ] && exit 0

# Delegate to process-checklist.sh + pre-commit-gate.sh in terminal mode.
SCRIPTS="$PROJECT_ROOT/scripts"
[ -x "$SCRIPTS/process-checklist.sh" ] || exit 0
[ -x "$SCRIPTS/pre-commit-gate.sh" ]   || exit 0

# BL-112-GATE-EXIT — the verdict MUST be captured from the checker itself.
# These two arms used to read `if ! "$SCRIPTS/…"; then EXIT=$?; … exit $EXIT; fi`.
# Inside the then-branch of `if ! cmd`, `$?` is the status of the NEGATION — which
# is 0 whenever cmd failed. So EXIT was ALWAYS 0 and the gate printed its [FAIL]
# and then `exit 0`: the commit landed anyway. Combined with BL-112's F8 (the gate
# was unreachable dead code) this gate was hollow twice over. Run the checker,
# capture ITS status, and branch on that. `set -e` is deliberately not enabled in
# this hook, so a non-zero checker does not abort before we can record the block.
#
# 1. Phase-prereq + check_commit_ready.
"$SCRIPTS/process-checklist.sh" --check-commit-ready 2>&1
EXIT=$?
if [ "$EXIT" -ne 0 ]; then
  bash "$SCRIPTS/install-filesystem-gates.sh" __record_block "$PROJECT_ROOT" "process-checklist" 2>/dev/null || true
  exit "$EXIT"
fi

# 2. pre-commit-gate.sh in terminal mode.
"$SCRIPTS/pre-commit-gate.sh" --terminal-mode
EXIT=$?
if [ "$EXIT" -ne 0 ]; then
  bash "$SCRIPTS/install-filesystem-gates.sh" __record_block "$PROJECT_ROOT" "pre-commit-gate" 2>/dev/null || true
  exit "$EXIT"
fi

# BL-161-NO-ROUTINE-PASS — a CLEAN terminal commit records NO row in the tracked
# ledger (.claude/bypass-audit.json records ONLY real events). Drop a NON-TRACKED
# gate-ran receipt (.claude/last-gate-pass.txt, gitignored like
# .claude/last-checked-commit.txt) so the PASS terminal stays provably reached
# without leaving the working tree perpetually one row dirty (Dogfood-4 F-DF4-007).
bash "$SCRIPTS/install-filesystem-gates.sh" __record_pass "$PROJECT_ROOT" 2>/dev/null || true
exit 0
GATE_EOF
  chmod +x "$GATE"
}

# Internal: write a terminal_commit_blocked audit row — a REAL enforcement event.
# Called by framework-gate.sh via re-invocation on a BLOCKED terminal commit.
#
# BL-161-NO-ROUTINE-PASS — this writer records ONLY the blocked event. A CLEAN
# commit no longer appends a terminal_commit_passed row here (that routine receipt
# left the working tree perpetually one row dirty — Dogfood-4 F-DF4-007); the PASS
# path drops a non-tracked receipt instead (see record_gate_pass_receipt).
# terminal_commit_passed stays a schema-valid LEGACY type — old ledgers keep their
# rows — it is simply no longer EMITTED. The `kind` arg is retained for the
# __record_block call signature; blocked is the only kind this function writes.
record_audit_row() {
  local kind="$1"          # "blocked" — the only real event recorded here
  local proj="$2"
  local gate_name="${3:-}"
  local audit="$proj/.claude/bypass-audit.json"
  [ -f "$audit" ] || echo "[]" > "$audit"
  command -v jq >/dev/null 2>&1 || return 0
  local ts row tmp type
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  type="terminal_commit_blocked"
  row=$(jq -nc \
    --arg ts "$ts" \
    --arg t "$type" \
    --arg g "$gate_name" \
    '{timestamp:$ts, session_id:null, type:$t, actor:"user_terminal", enforcement_level_at_event:"strict", details:{gate:$g}, user_response:"n/a", final_outcome:"abandoned"}')
  tmp=$(mktemp)
  if jq --argjson r "$row" '. + [$r]' "$audit" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$audit"
  else
    rm -f "$tmp"
  fi
}

# Internal: a CLEAN terminal commit's gate-ran receipt.
# BL-161-NO-ROUTINE-PASS — does NOT touch the tracked ledger. Writes a NON-TRACKED
# sidecar .claude/last-gate-pass.txt (the sanctioned mirror of
# .claude/last-checked-commit.txt — both gitignored in
# templates/generated/gitignore-base.tmpl) so the PASS terminal is provably
# reached without dirtying the tracked working tree. Best-effort: any failure is
# swallowed — a receipt hiccup must never affect the commit that already passed.
record_gate_pass_receipt() {
  local proj="$1"
  mkdir -p "$proj/.claude" 2>/dev/null || true
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$proj/.claude/last-gate-pass.txt" 2>/dev/null || true
}

case "$ACTION" in
  --install)
    # BL-209-HOOKSPATH-REFUSE — "set" is read off git's EXIT STATUS, never the
    # value: a set-but-empty hooksPath reads rc=0 with no output and runs no
    # hook from .git/hooks at all, so keying "set" on output emptiness
    # reproduces the false PASS this guard exists to remove. BL-145 declines to
    # WRITE into a configured hooksPath, so this refuses rather than relocating.
    #
    # SYNC SIBLINGS — `# BL-084-TIER-KEY` kind. This predicate and its value
    # read exist THREE times now: `_bl145_hookspath_is_set` and
    # `_bl145_configured_hookspath` in scripts/verify-install.sh (:540, :549),
    # and here. Change one, change all three.
    #
    # They are NOT shared, and the reason is a signature difference rather than
    # neglect. The `_bl145_*` pair read the CURRENT DIRECTORY's config (bare
    # `git config`); this installer is routinely invoked from another cwd with
    # the project as an argument, so it must read `git -C "$PROJECT_ROOT"`.
    # Sharing them means adding a repo parameter and updating the six
    # verify-install.sh call sites — a signature change across a governance
    # script, not a move. The durable repair is to hoist them into
    # scripts/lib/helpers-core.sh behind a fence, exactly as
    # `# BL-095-STATE-READERS-BEGIN` (:983-:1038) did for the state readers,
    # because verify-install.sh is not sourceable (`guard_not_in_framework` at
    # :20). That is a refactor and is recorded on `## BL-209:` rather than
    # taken here.
    if git -C "$PROJECT_ROOT" config core.hooksPath >/dev/null 2>&1; then
      # `--path` tilde-expands; the plain read is the fallback for git builds
      # that reject it. BOTH take their rc explicitly: `set -euo pipefail` is on,
      # and a bare `_hp="$(git …)"` that fails aborts the script with no
      # diagnostic — the same silent mode `# BL-209-FALLBACK-RC` above exists to
      # end. `_bl145_configured_hookspath` guards the identical call the same way.
      _hp="$(git -C "$PROJECT_ROOT" config --path core.hooksPath 2>/dev/null)" || _hp=""
      if [ -z "$_hp" ]; then
        _hp="$(git -C "$PROJECT_ROOT" config core.hooksPath 2>/dev/null)" || _hp=""
      fi
      # A hooksPath that RESOLVES TO THIS REPO'S OWN HOOKS DIRECTORY is not a
      # redirection — a gate written there WILL run. Refusing it made the
      # message below false in that case, and because `git config` reads the
      # whole chain, a GLOBAL core.hooksPath (husky, pre-commit, corporate
      # dotfiles) refused every install with no way around it: through
      # reconfigure-project.sh that rc 1 hit rollback, so such an operator
      # could not switch a project to strict at all. Compare directories.
      _hp_phys=""
      case "$_hp" in
        /*) _hp_phys="$(cd "$_hp" 2>/dev/null && pwd -P)" || _hp_phys="" ;;
        ?*) _hp_phys="$(cd "$PROJECT_ROOT" 2>/dev/null && cd "$_hp" 2>/dev/null && pwd -P)" || _hp_phys="" ;;
      esac
      _hd_phys="$(mkdir -p "$HOOKS_DIR" 2>/dev/null; cd "$HOOKS_DIR" 2>/dev/null && pwd -P)" || _hd_phys=""
      if [ -z "$_hp_phys" ] || [ "$_hp_phys" != "$_hd_phys" ]; then   # BL-209-HOOKSPATH-SAME-DIR
        echo "[FAIL] core.hooksPath is set to '${_hp:-(empty)}' — git runs hooks from there, not from $HOOKS_DIR, so a gate written to $HOOKS_DIR would never run." >&2
        echo "       This installer will not write into a configured hooksPath (it can be shared across repos or tracked in the project)." >&2
        echo "       To let the framework manage the commit-time gate: git config --unset core.hooksPath" >&2
        exit 1
      fi
    fi
    mkdir -p "$HOOKS_DIR" \
      || { echo "[FAIL] could not create the git hooks directory: $HOOKS_DIR" >&2; exit 1; }
    write_gate_script
    if [ ! -f "$HOOK" ]; then
      cat > "$HOOK" <<'EOF'
#!/usr/bin/env bash
EOF
      chmod +x "$HOOK"
    fi
    if grep -qF "$MARK_OPEN" "$HOOK"; then
      exit 0
    fi
    {
      echo ""
      echo "$MARK_OPEN"
      # BL-209-GATE-PATH — same resolution in the emitted hook. In a worktree
      # --show-toplevel is the WORKTREE root, where .git is a file, so the old
      # `[ -f ... ]` test was false and this block fell through: strict mode with
      # no gate and no output.
      echo 'SOIF_GATE="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)/hooks/framework-gate.sh"'
      echo 'if [ -f "$SOIF_GATE" ]; then'
      echo '  bash "$SOIF_GATE" || exit $?'
      echo 'fi'
      echo "$MARK_CLOSE"
    } >> "$HOOK"
    chmod +x "$HOOK"
    ;;
  --uninstall)
    [ -f "$HOOK" ] || exit 0
    if ! grep -qF "$MARK_OPEN" "$HOOK"; then
      exit 0
    fi
    tmp=$(mktemp)
    # `close` is a built-in awk function — rename the variable to avoid
    # BSD awk's strict reserved-word check. `open` is safe but renamed
    # for symmetry / readability.
    awk -v open_mark="$MARK_OPEN" -v close_mark="$MARK_CLOSE" '
      BEGIN { skipping = 0 }
      {
        if (skipping == 0 && $0 == open_mark) { skipping = 1; next }
        if (skipping == 1 && $0 == close_mark) { skipping = 0; next }
        if (skipping == 0) { print }
      }
    ' "$HOOK" > "$tmp"
    mv "$tmp" "$HOOK"
    chmod +x "$HOOK"
    ;;
  __record_block)
    record_audit_row "blocked" "$2" "${3:-unknown}"
    ;;
  __record_pass)
    # BL-161-NO-ROUTINE-PASS — a clean pass writes a non-tracked receipt, not a
    # tracked ledger row.
    record_gate_pass_receipt "$2"
    ;;
  *)
    usage
    ;;
esac
