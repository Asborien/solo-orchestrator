#!/usr/bin/env bash
# tests/test-bl260-verify-install-context.sh
#
# `## BL-260:` — TWO AUTO-FIXERS IN verify-install.sh THAT COULD NEVER RUN.
#
# ARM 1 (`# BL-260-CONTEXT-STATE`). `has_context()` requires PLATFORM, LANGUAGE
# and TRACK, and `load_context()` had exactly two sources for them:
# `.claude/tool-preferences.json` — the file `fix_tool_prefs` exists to CREATE,
# so it cannot be its own precondition — and `grep 'Platform:'`-style anchors in
# a SCAFFOLDED CLAUDE.md, which an adopted project that kept its own CLAUDE.md
# does not have. So on a brownfield adoption all three stayed empty for ever:
# the row was listed as auto-fixable and `--auto-fix` declined it on every pass,
# `check_tools` skipped itself, and `fix_claude_md` / `fix_ci_pipeline` refused.
# The fix reads the same three values from the state files the wizard and
# adoption already write (`.claude/intake-progress.json`,
# `.claude/phase-state.json`), behind `-z` guards so an EMPTY recorded value
# cannot win.
#
# ARM 2 (`# BL-260-PLUGIN-VERB`). `fix_superpowers` ran `claude plugins add
# superpowers`. `add` IS NOT A SUBCOMMAND — the real CLI advertises `install|i`
# and answers `add` with rc 1 and `error: unknown command 'add'` — so the fixer
# could never work on any host, adopted or scaffolded. The fix uses `install`
# AND the marketplace-qualified id, because the detector six lines above keys on
# `.enabledPlugins["superpowers@claude-plugins-official"]`: a bare `superpowers`
# can resolve through another marketplace and record a key the detector does not
# read, which is a fixer that "succeeds" and leaves the row red.
#
# HERMETIC. The project, the HOME, and the `claude` CLI are all fixtures; no
# network, no host tool is installed, and nothing outside the temp tree is
# written. The `claude` shim mirrors the real CLI's command dispatch (`plugin`
# and `plugins` are one group; the group validates its VERB first) and case L1
# ANCHORS that shim against the real CLI when one is on PATH.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFY="$REPO_ROOT/scripts/verify-install.sh"

PASSED=0
FAILED=0
SKIPPED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }
skip_() { echo "  [SKIP] $1 — $2"; SKIPPED=$((SKIPPED + 1)); }

TOPTMP="$(mktemp -d)"
trap 'rm -rf "$TOPTMP"' EXIT INT TERM
newtmp() { mktemp -d "$TOPTMP/fixXXXXXX"; }

# The REAL CLI, resolved ONCE and before any fixture PATH shadows it. Used only
# by L1, and only for `--help` and a verb the CLI rejects before it resolves
# anything — no install, no network, no state.
REAL_CLAUDE="$(command -v claude 2>/dev/null || true)"

[ -f "$VERIFY" ] || { echo "  [FAIL] setup — $VERIFY not found"; echo ""; echo "Results: 0 passed, 1 failed, 0 skipped"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  [FAIL] setup — jq is required"; echo ""; echo "Results: 0 passed, 1 failed, 0 skipped"; exit 1; }

# Values pinned BY VALUE below. They are deliberately not the host's own, so a
# fixer that guessed instead of reading the state files would be visible.
FX_PLATFORM_VAL="web"
FX_LANGUAGE_VAL="typescript"
FX_TRACK_VAL="full"

# ── mk_claude_shim DIR ──────────────────────────────────────────────────────
# A `claude` that validates its verb the way the real one does and records its
# argv. Anchored by L1.
mk_claude_shim() {
  local d="$1"
  mkdir -p "$d" || return 1
  cat > "$d/claude" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BL260_SHIM_LOG:?BL260_SHIM_LOG unset}"
group="${1:-}"
shift 2>/dev/null || true
case "$group" in
  plugin|plugins) ;;
  mcp) exit 0 ;;
  *) printf "error: unknown command '%s'\n" "$group" >&2; exit 1 ;;
esac
verb="${1:-}"
case "$verb" in
  install|i|list|enable|disable|uninstall|remove|update|validate|details|init|new|marketplace|prune|autoremove|tag|eval|help)
    exit 0 ;;
  *) printf "error: unknown command '%s'\n" "$verb" >&2; exit 1 ;;
esac
SHIM
  chmod +x "$d/claude" || return 1
  [ -x "$d/claude" ] || return 1
  return 0
}

# ── mk_fixture PLATFORM LANGUAGE ────────────────────────────────────────────
# An ADOPTED project: its own CLAUDE.md with no scaffolded identity block, the
# two state files adoption and the intake wizard write, and no
# tool-preferences.json — the file arm 1's fixer exists to create.
#
# The fixture HOME carries a ~/.claude-dev-framework/.git directory so
# `fix_framework_clone` is never REGISTERED; without it, `--auto-fix` reaches a
# real `git clone` of the CDF over the network. Nothing here may touch a remote.
# Sets: FX_DIR FX_PROJ FX_HOME FX_SHIM FX_LOG
mk_fixture() {
  local plat="$1" lang="$2"
  FX_DIR="$(newtmp)"
  FX_PROJ="$FX_DIR/proj"
  FX_HOME="$FX_DIR/home"
  FX_SHIM="$FX_DIR/bin"
  FX_LOG="$FX_DIR/claude-argv.log"
  mkdir -p "$FX_PROJ/.claude" "$FX_HOME/.claude" "$FX_HOME/.claude-dev-framework/.git" || return 1
  : > "$FX_LOG" || return 1
  mk_claude_shim "$FX_SHIM" || return 1

  printf '# bl260-adopted-project\n\nThis project kept its own CLAUDE.md.\n' \
    > "$FX_PROJ/CLAUDE.md" || return 1

  # The scaffolded CLAUDE.md anchors must be ABSENT — they are the other source
  # load_context() had, and the fixture is dishonest if it carries them.
  if grep -qE '^[^|]*(Platform:|Primary Language:|Track:)' "$FX_PROJ/CLAUDE.md"; then
    return 1
  fi

  jq -n --arg p "$plat" --arg l "$lang" --arg t "$FX_TRACK_VAL" \
    '{version:1, started_at:"2026-09-13T00:00:00Z", last_section:1, completed_sections:[1],
      source:"adopt-project.sh", project_name:"bl260-adopted-project",
      platform:$p, track:$t, deployment:"personal", language:$l, description:"",
      answers:{}}' > "$FX_PROJ/.claude/intake-progress.json" || return 1

  # Exactly what adopt_write_phase_state emits: a track, and no platform or
  # language at all.
  jq -n --arg t "$FX_TRACK_VAL" \
    '{project:"bl260-adopted-project", framework_version:"1.0", current_phase:0,
      track:$t, deployment:"personal", poc_mode:null, compliance_ready:false,
      review_gate_enforced:true,
      gates:{phase_0_to_1:null, phase_1_to_2:null, phase_2_to_3:null, phase_3_to_4:null}}' \
    > "$FX_PROJ/.claude/phase-state.json" || return 1

  # manifest.json present so the CDF-manifest row passes; settings.json carries
  # no superpowers key (arm 2's fixable) and DOES carry context7 + qdrant, so
  # fix_context7 is never registered and no npx is ever reached.
  jq -n '{host:"other", mode:"personal", remote_url:"", deployment:"personal",
          poc_mode:null, enforcement_level:"strict"}' \
    > "$FX_PROJ/.claude/manifest.json" || return 1
  jq -n '{enabledPlugins:{}, mcpServers:{context7:{}, qdrant:{}}}' \
    > "$FX_HOME/.claude/settings.json" || return 1

  [ -f "$FX_PROJ/.claude/tool-preferences.json" ] && return 1
  return 0
}

# ── run_verify SCRIPT MODE ──────────────────────────────────────────────────
# Runs verify-install.sh from inside the fixture project. Sets FX_OUT (a file)
# and FX_RC.
run_verify() {
  local script="$1" mode="$2"
  FX_OUT="$FX_DIR/verify$RANDOM.txt"
  ( cd "$FX_PROJ" && HOME="$FX_HOME" \
      PATH="$FX_SHIM:$PATH" BL260_SHIM_LOG="$FX_LOG" \
      bash "$script" "$mode" > "$FX_OUT" 2>&1 )
  FX_RC=$?
  return 0
}

# ── mirror_scripts → prints the mirrored scripts dir ────────────────────────
mirror_scripts() {
  local m
  m="$(newtmp)/fw"
  mkdir -p "$m" || return 1
  cp -Rp "$REPO_ROOT/scripts" "$m/" || return 1
  printf '%s\n' "$m/scripts"
  return 0
}

M_CTX="# BL-260-CONTEXT-STATE"
M_VERB="# BL-260-PLUGIN-VERB"

# ================================================================
echo "=== A — arm 1: an adopted project's context reaches has_context() ==="
# ================================================================

if ! mk_fixture "$FX_PLATFORM_VAL" "$FX_LANGUAGE_VAL"; then
  fail_ "A setup" "could not build the adopted-project fixture"
else
  run_verify "$VERIFY" "--auto-fix"

  if [ ! -s "$FX_OUT" ] || ! grep -q 'Installation Verification Report' "$FX_OUT"; then
    fail_ "A0" "verify-install produced no report (rc=$FX_RC)"
  else
    pass "A0 — verify-install ran to a report inside the fixture project (rc=$FX_RC)"

    # A1 — THE DISCRIMINATOR. Before the fix this row is dispatched and REFUSED
    # on every pass, and the file never appears.
    if [ -f "$FX_PROJ/.claude/tool-preferences.json" ] \
       && grep -q 'Fixed: tool-preferences.json missing' "$FX_OUT"; then
      pass "A1 — --auto-fix ran fix_tool_prefs and wrote .claude/tool-preferences.json"
    else
      fail_ "A1" "tool-preferences.json was not written; report says: $(grep -c 'Could not fix: tool-preferences.json missing' "$FX_OUT") refusal line(s)"
    fi

    # A2 — the same empty context silently skipped the whole tool check.
    if grep -q 'Tool check skipped — no project context' "$FX_OUT"; then
      fail_ "A2" "check_tools still skipped itself for want of project context"
    else
      pass "A2 — check_tools no longer skips itself for want of project context"
    fi

    # A3 — BY VALUE, not just present. A copy-paste slip that reads language
    # from .platform leaves has_context() true and A1/A2 green; only this sees
    # it. Read with jq so a shifted or absent key cannot pass as a substring.
    if [ -f "$FX_PROJ/.claude/tool-preferences.json" ]; then
      got="$(jq -r '[(.context.platform // "<<ABSENT>>"), (.context.language // "<<ABSENT>>"), (.context.track // "<<ABSENT>>")] | @tsv' \
              "$FX_PROJ/.claude/tool-preferences.json" 2>/dev/null)"
      want="$(printf '%s\t%s\t%s' "$FX_PLATFORM_VAL" "$FX_LANGUAGE_VAL" "$FX_TRACK_VAL")"
      if [ "$got" = "$want" ]; then
        pass "A3 — the written context is the state files' values BY VALUE [$got]"
      else
        fail_ "A3" "context is [$got], want [$want]"
      fi
    else
      fail_ "A3" "no tool-preferences.json to read"
    fi
  fi
fi

# A4 — THE CONTROL, and it passes on unfixed code too, by construction. An
# adoption that has not yet run the intake records platform and language as
# EMPTY STRINGS (adopt_render_intake_progress writes `platform: ""`). The fix
# must still decline: reading a recorded blank as an answer would be a fact
# nobody gave. This is what the `-z` guards and `// empty` are for.
if ! mk_fixture "" ""; then
  fail_ "A4 setup" "could not build the empty-context fixture"
else
  run_verify "$VERIFY" "--auto-fix"
  if [ ! -f "$FX_PROJ/.claude/tool-preferences.json" ] \
     && grep -q 'Tool check skipped — no project context' "$FX_OUT"; then
    pass "A4 (control) — a project whose recorded platform/language are EMPTY is still declined, not guessed"
  else
    fail_ "A4 (control)" "an empty recorded context was treated as an answer (prefs written: $([ -f "$FX_PROJ/.claude/tool-preferences.json" ] && echo yes || echo no))"
  fi
fi

# ================================================================
echo "=== P — arm 2: fix_superpowers runs a verb the CLI actually has ==="
# ================================================================

if ! mk_fixture "$FX_PLATFORM_VAL" "$FX_LANGUAGE_VAL"; then
  fail_ "P setup" "could not build the fixture"
else
  run_verify "$VERIFY" "--auto-fix"

  if grep -q 'Fixed: Superpowers plugin not installed' "$FX_OUT" \
     && ! grep -q 'Could not fix: Superpowers plugin not installed' "$FX_OUT"; then
    pass "P1 — fix_superpowers succeeded against a CLI that validates its verb"
  else
    fail_ "P1" "fix_superpowers was refused; shim saw: $(tr '\n' '|' < "$FX_LOG")"
  fi

  # P2 — the argv BY VALUE. This is the case that sees a fixer which INSTALLS
  # something (rc 0, P1 green) under a key the detector six lines above does
  # not read, and the one that keeps `--yes` out.
  want_argv="plugin install --scope user superpowers@claude-plugins-official"
  n="$(grep -cFx "$want_argv" "$FX_LOG" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" = "1" ]; then
    pass "P2 — the CLI was called exactly once as [$want_argv]"
  else
    fail_ "P2" "want exactly one [$want_argv]; shim log holds: $(tr '\n' '|' < "$FX_LOG")"
  fi
fi

# L1 — THE ANCHOR. Everything above trusts a shim; this checks the shim's one
# load-bearing claim against the real CLI. `--help` and a verb the CLI rejects
# at dispatch: no install, no network, no state written.
if [ -z "$REAL_CLAUDE" ]; then
  skip_ "L1 (live CLI anchor)" "no 'claude' on PATH — the shim's verb set is unanchored on this host"
else
  live_help="$("$REAL_CLAUDE" plugin --help 2>&1 || true)"
  live_err="$("$REAL_CLAUDE" plugin add bl260-no-such-plugin 2>&1 || true)"
  live_rc=0
  "$REAL_CLAUDE" plugin add bl260-no-such-plugin >/dev/null 2>&1 || live_rc=$?
  if printf '%s' "$live_help" | grep -qE '^[[:space:]]+install\|i[[:space:]]' \
     && [ "$live_rc" -ne 0 ] \
     && printf '%s' "$live_err" | grep -q "unknown command 'add'"; then
    pass "L1 (live) — the real CLI advertises 'install|i' and rejects 'add' (rc=$live_rc): the shim is faithful and the shipped verb was unusable"
  else
    fail_ "L1 (live)" "the real CLI does not behave as the shim assumes (add rc=$live_rc, stderr: $(printf '%s' "$live_err" | head -1))"
  fi
fi

# ================================================================
echo "=== M — markers ==="
# ================================================================

for mk in "$M_CTX" "$M_VERB"; do
  n="$(grep -cF "$mk" "$VERIFY" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" = "1" ]; then
    pass "M0 — '$mk' occurs exactly once in verify-install.sh"
  else
    fail_ "M0" "'$mk' occurs $n times in verify-install.sh (need exactly 1)"
  fi
done

# ================================================================
echo "=== MA — arm 1 mutations ==="
# ================================================================

# MA1 — EXCISE the state-file read entirely (the pre-fix load_context). A1 must
# go red.
MA1_DIR="$(mirror_scripts)"
if [ -z "$MA1_DIR" ] || [ ! -f "$MA1_DIR/verify-install.sh" ]; then
  fail_ "MA1 setup" "could not mirror scripts/"
else
  tgt="$MA1_DIR/verify-install.sh"
  open_ln="$(grep -nF "$M_CTX" "$tgt" | head -1 | cut -d: -f1)"
  close_ln="$(awk -v s="$open_ln" 'NR>=s && /^  fi$/ {print NR; exit}' "$tgt")"
  if [ -z "$open_ln" ] || [ -z "$close_ln" ] || [ "$close_ln" -le "$open_ln" ]; then
    fail_ "MA1 setup" "could not locate the block (open=$open_ln close=$close_ln)"
  else
    { head -n $((open_ln - 1)) "$tgt"; tail -n +$((close_ln + 1)) "$tgt"; } > "$tgt.mut"
    mv "$tgt.mut" "$tgt"
    if ! bash -n "$tgt" 2>/dev/null || [ "$(grep -cF "$M_CTX" "$tgt")" -ne 0 ]; then
      fail_ "MA1 setup" "the excision did not apply cleanly"
    elif ! mk_fixture "$FX_PLATFORM_VAL" "$FX_LANGUAGE_VAL"; then
      fail_ "MA1 setup" "could not build the mutant's fixture"
    else
      run_verify "$tgt" "--auto-fix"
      if [ ! -f "$FX_PROJ/.claude/tool-preferences.json" ]; then
        pass "MA1 (MUTATION) — with the state-file read excised, fix_tool_prefs is declined again: A1 is what stops it"
      else
        fail_ "MA1 (MUTATION)" "the excision changed nothing — A1 may be passing for another reason"
      fi
    fi
  fi
fi

# MA2 — keep the read, DROP the `-z` guards. phase-state carries no platform,
# so an unguarded second pass blanks the value intake-progress supplied. A1
# must go red. This is what makes "an EMPTY value must not win" load-bearing.
MA2_DIR="$(mirror_scripts)"
if [ -z "$MA2_DIR" ] || [ ! -f "$MA2_DIR/verify-install.sh" ]; then
  fail_ "MA2 setup" "could not mirror scripts/"
else
  tgt="$MA2_DIR/verify-install.sh"
  before="$(newtmp)/before"; cp "$tgt" "$before"
  sed -e 's|^      \[ -z "\$PLATFORM" \] && PLATFORM=|      PLATFORM=|' \
      -e 's|^      \[ -z "\$LANGUAGE" \] && LANGUAGE=|      LANGUAGE=|' \
      -e 's|^      \[ -z "\$TRACK" \]    && TRACK=|      TRACK=|' \
      "$before" > "$tgt"
  changed="$(diff "$before" "$tgt" | grep -c '^[<>]')"
  case "$changed" in ''|*[!0-9]*) changed=0 ;; esac
  if ! bash -n "$tgt" 2>/dev/null || [ "$changed" -ne 6 ]; then
    fail_ "MA2 setup" "the guard-removal mutation did not apply cleanly ($changed changed lines, want 6)"
  elif ! mk_fixture "$FX_PLATFORM_VAL" "$FX_LANGUAGE_VAL"; then
    fail_ "MA2 setup" "could not build the mutant's fixture"
  else
    run_verify "$tgt" "--auto-fix"
    if [ ! -f "$FX_PROJ/.claude/tool-preferences.json" ]; then
      pass "MA2 (MUTATION) — without the -z guards the later state file blanks the earlier answer: A1 is what stops it"
    else
      fail_ "MA2 (MUTATION)" "dropping the -z guards changed nothing — the guards are not load-bearing as written"
    fi
  fi
fi

# MA3 — a copy-paste slip: read LANGUAGE from `.platform`. has_context() stays
# true and the file IS written, so A0/A1/A2 all stay green. Only A3, which pins
# the values, sees it.
MA3_DIR="$(mirror_scripts)"
if [ -z "$MA3_DIR" ] || [ ! -f "$MA3_DIR/verify-install.sh" ]; then
  fail_ "MA3 setup" "could not mirror scripts/"
else
  tgt="$MA3_DIR/verify-install.sh"
  before="$(newtmp)/before"; cp "$tgt" "$before"
  sed -e "s|LANGUAGE=\$(jq -r '.language // empty' \"\$_ctx_src\"|LANGUAGE=\$(jq -r '.platform // empty' \"\$_ctx_src\"|" \
      "$before" > "$tgt"
  changed="$(diff "$before" "$tgt" | grep -c '^[<>]')"
  case "$changed" in ''|*[!0-9]*) changed=0 ;; esac
  if ! bash -n "$tgt" 2>/dev/null || [ "$changed" -ne 2 ]; then
    fail_ "MA3 setup" "the wrong-key mutation did not apply cleanly ($changed changed lines, want 2)"
  elif ! mk_fixture "$FX_PLATFORM_VAL" "$FX_LANGUAGE_VAL"; then
    fail_ "MA3 setup" "could not build the mutant's fixture"
  else
    run_verify "$tgt" "--auto-fix"
    got="$(jq -r '.context.language // "<<ABSENT>>"' "$FX_PROJ/.claude/tool-preferences.json" 2>/dev/null || printf '<<NOFILE>>')"
    if [ -f "$FX_PROJ/.claude/tool-preferences.json" ] && [ "$got" != "$FX_LANGUAGE_VAL" ]; then
      pass "MA3 (MUTATION) — reading language from .platform still writes the file (A1/A2 stay green) but records [$got]: A3 is what stops it"
    else
      fail_ "MA3 (MUTATION)" "the wrong-key mutation was invisible (language=[$got], file present: $([ -f "$FX_PROJ/.claude/tool-preferences.json" ] && echo yes || echo no))"
    fi
  fi
fi

# ================================================================
echo "=== MP — arm 2 mutations ==="
# ================================================================

# mutate_fixer MIRROR_DIR REPLACEMENT_LINE → 0 on a clean single-line swap
mutate_fixer() {
  local tgt="$1" repl="$2" before
  before="$(newtmp)/before"; cp "$tgt" "$before" || return 1
  awk -v repl="$repl" '
    /^  claude plugin install --scope user superpowers@claude-plugins-official$/ { print repl; next }
    { print }' "$before" > "$tgt" || return 1
  bash -n "$tgt" 2>/dev/null || return 1
  local changed
  changed="$(diff "$before" "$tgt" | grep -c '^[<>]')"
  case "$changed" in ''|*[!0-9]*) changed=0 ;; esac
  [ "$changed" -eq 2 ] || return 1
  return 0
}

# MP1 — restore the shipped `claude plugins add superpowers`. The shim rejects
# the verb exactly as the real CLI does (L1), so the fixer must be refused.
MP1_DIR="$(mirror_scripts)"
if [ -z "$MP1_DIR" ] || ! mutate_fixer "$MP1_DIR/verify-install.sh" "  claude plugins add superpowers"; then
  fail_ "MP1 setup" "could not restore the shipped command on a mirror"
elif ! mk_fixture "$FX_PLATFORM_VAL" "$FX_LANGUAGE_VAL"; then
  fail_ "MP1 setup" "could not build the mutant's fixture"
else
  run_verify "$MP1_DIR/verify-install.sh" "--auto-fix"
  if grep -q 'Could not fix: Superpowers plugin not installed' "$FX_OUT"; then
    pass "MP1 (MUTATION) — the shipped 'plugins add superpowers' is REFUSED by a verb-validating CLI: P1 is what stops it"
  else
    fail_ "MP1 (MUTATION)" "'plugins add' was accepted — the shim does not validate its verb, so P1 proves nothing"
  fi
fi

# MP2 — de-qualify the plugin id. The install SUCCEEDS (rc 0), so P1 stays
# green; the recorded key is not the one the detector reads. Only P2 sees it.
MP2_DIR="$(mirror_scripts)"
if [ -z "$MP2_DIR" ] || ! mutate_fixer "$MP2_DIR/verify-install.sh" "  claude plugin install --scope user superpowers"; then
  fail_ "MP2 setup" "could not de-qualify the plugin id on a mirror"
elif ! mk_fixture "$FX_PLATFORM_VAL" "$FX_LANGUAGE_VAL"; then
  fail_ "MP2 setup" "could not build the mutant's fixture"
else
  run_verify "$MP2_DIR/verify-install.sh" "--auto-fix"
  n="$(grep -cFx "plugin install --scope user superpowers@claude-plugins-official" "$FX_LOG" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if grep -q 'Fixed: Superpowers plugin not installed' "$FX_OUT" && [ "$n" = "0" ]; then
    pass "MP2 (MUTATION) — a bare 'superpowers' still reports Fixed (P1 stays green) but never names the detector's key: P2 is what stops it"
  else
    fail_ "MP2 (MUTATION)" "de-qualifying changed the reported outcome (qualified-argv count=$n) — P2's role is not what this claims"
  fi
fi

# MP3 — add `--yes`. The comment states the omission is deliberate: a fixer must
# not auto-accept running a marketplace-declared command on the operator's
# behalf. Only P2's exact argv keeps that decision enforced.
MP3_DIR="$(mirror_scripts)"
if [ -z "$MP3_DIR" ] || ! mutate_fixer "$MP3_DIR/verify-install.sh" "  claude plugin install --yes --scope user superpowers@claude-plugins-official"; then
  fail_ "MP3 setup" "could not add --yes on a mirror"
elif ! mk_fixture "$FX_PLATFORM_VAL" "$FX_LANGUAGE_VAL"; then
  fail_ "MP3 setup" "could not build the mutant's fixture"
else
  run_verify "$MP3_DIR/verify-install.sh" "--auto-fix"
  n="$(grep -cFx "plugin install --scope user superpowers@claude-plugins-official" "$FX_LOG" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if grep -q 'Fixed: Superpowers plugin not installed' "$FX_OUT" && [ "$n" = "0" ]; then
    pass "MP3 (MUTATION) — '--yes' still reports Fixed (P1 stays green): P2 is what stops the fixer auto-accepting a declared command"
  else
    fail_ "MP3 (MUTATION)" "adding --yes did not change the recorded argv (count=$n) — P2 is not pinning what this claims"
  fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed, $SKIPPED skipped"
[ "$FAILED" -eq 0 ] && exit 0
exit 1
