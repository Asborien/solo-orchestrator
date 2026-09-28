#!/usr/bin/env bash
# tests/test-bl311-adopt-mcp.sh — `## BL-311:` fixes 1 and 9: adoption checks
# for, and offers to set up, the two MCP servers a Claude Code session in the
# adopted project is checked for; every MCP reader honours CLAUDE_CONFIG_DIR;
# check-versions.sh reports registration, not installation.
#
# HERMETIC. Every case runs with a temp HOME and a temp CLAUDE_CONFIG_DIR, and
# with STUB `claude`, `docker`, `curl`, `uvx` and `npx` first on PATH — so no
# case reads the host's Claude configuration, starts a container or registers
# anything. The `claude` stub parses `mcp add` the way Claude Code 2.1.283 does
# (MEASURED against a scratch CLAUDE_CONFIG_DIR): `-e` is variadic, so a server
# name placed after the `-e` options is taken as an environment value and the
# command exits 1 with "Invalid environment variable format". It writes the
# entry where the real one does — `$CLAUDE_CONFIG_DIR/.claude.json` when that
# is set, `~/.claude.json` otherwise. The `curl` stub answers for
# localhost:6333 only while the `docker` stub has "started" the database. Every
# stub DRAINS its stdin and logs it if it got any, because a subprocess that
# reads the operator's answers is a defect this step can cause (S2/E2, M20).
#
# WHAT EACH CASE OWNS.
#   A1  a registration only in $CLAUDE_CONFIG_DIR is seen by every helper;
#       one only in ~/.claude.json is NOT while CLAUDE_CONFIG_DIR is set (A2),
#       and IS when it is unset (A3)
#   A4  settings.json follows CLAUDE_CONFIG_DIR too (a plugin-enabled Context7)
#   A5  the SessionStart hook derives the requirements from the same files
#   A6  check-versions.sh says NOT registered, not [OK], for servers that are
#       registered only in the file the session does not read
#   S*  THE STEP ON ITS OWN (adopt_mcp_resolve, sourced — seconds, not an
#       adoption): S1 nothing missing, no question; S2 "set it up now" — the
#       commands shown BEFORE the question, run as shown from the run's work
#       dir, registered in the session's config; S3 registered but silent +
#       skip — the note says EVERY edit is blocked; S4 unregistered + skip —
#       the note says the check is off; S5 a blank answer is skip; S6 end of
#       input is skip; S7 the commands fail — the receipt claims nothing;
#       S8 an answer not offered is refused; S9 a database that never answers
#       is not registered against
#   E*  WHOLE ADOPTIONS: E1 both present — no question, the Record row, and
#       the restart sentence BEFORE "NEXT"; E2 set it up now — no command read
#       the operator's answers, and the project collection is declared; E3
#       skip — the Record row and the closing pointer; E4 no `claude` command
#       (the CI shape) — an answer sequence written without this step still
#       completes; E5 registered but silent — the adopted project's own gate
#       DOES block a Write (the S3 sentence is true); E6 the dogfood shape — a
#       registration in ~/.claude.json only, a database running, uvx present,
#       skip — nothing declared for the project and its own gate ALLOWS a Write
#   M*  mutation proofs, one per guard, each required to die by its NAMED
#       assertion — see the M section.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSED=0; FAILED=0; SKIPPED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }
skip()  { echo "  [SKIP] $1 — $2"; SKIPPED=$((SKIPPED + 1)); }
_done() { echo; echo "Results: $PASSED passed, $FAILED failed, $SKIPPED skipped"; [ "$FAILED" -eq 0 ]; exit $?; }

echo "== BL-311 — the MCP servers on the adoption path, and CLAUDE_CONFIG_DIR =="
for t in git jq; do
  command -v "$t" >/dev/null 2>&1 || { skip "every case" "$t is not on PATH"; _done; }
done
WORK="$(mktemp -d)" || exit 1
# BL311_KEEP=1 keeps the fixtures for a post-mortem and prints where they are.
if [ "${BL311_KEEP:-0}" = "1" ]; then echo "  (fixtures kept in $WORK)"; else trap 'rm -rf "$WORK"' EXIT; fi

# ── the stubs ───────────────────────────────────────────────────────────────
# Each logs its argv, its cwd, and whether its stdin carried anything.
_mkstubs() {
  local d="$1" with_claude="${2:-yes}"
  mkdir -p "$d" || return 1
  cat > "$d/docker" <<'STUB'
#!/bin/bash
st="${STUB_STATE:?}"
{ printf 'docker'; for a in "$@"; do printf ' [%s]' "$a"; done; printf ' cwd=%s\n' "$PWD"; } >> "$st/calls.log"
if [ ! -t 0 ]; then x="$(cat)"; [ -n "$x" ] && echo "STDIN-HAD-DATA docker" >> "$st/calls.log"; fi
case "${1:-}" in
  info)  [ -f "$st/docker-up" ] ;;
  ps)    if [ "${2:-}" = "-a" ]; then [ -f "$st/qdrant-exists" ] && echo qdrant; else [ -f "$st/qdrant-up" ] && echo qdrant; fi; exit 0 ;;
  start) : > "$st/qdrant-up"; echo qdrant ;;
  run)   : > "$st/qdrant-exists"; [ -f "$st/docker-run-noop" ] || : > "$st/qdrant-up"; echo 0123abcd ;;
  *)     exit 0 ;;
esac
STUB
  cat > "$d/curl" <<'STUB'
#!/bin/bash
st="${STUB_STATE:?}"
u=""; for a in "$@"; do u="$a"; done
echo "curl $u" >> "$st/curl.log"
if [ ! -t 0 ]; then x="$(cat)"; [ -n "$x" ] && echo "STDIN-HAD-DATA curl" >> "$st/calls.log"; fi
case "$u" in
  *localhost:6333*|*127.0.0.1:6333*) [ -f "$st/qdrant-up" ] && exit 0; exit 7 ;;
esac
exit 7
STUB
  if [ "$with_claude" = yes ]; then
    cat > "$d/claude" <<'STUB'
#!/bin/bash
st="${STUB_STATE:?}"
{ printf 'claude'; for a in "$@"; do printf ' [%s]' "$a"; done; printf ' cwd=%s\n' "$PWD"; } >> "$st/calls.log"
if [ ! -t 0 ]; then x="$(cat)"; [ -n "$x" ] && echo "STDIN-HAD-DATA claude" >> "$st/calls.log"; fi
[ -f "$st/claude-fails" ] && { echo "stub claude: refusing on purpose" >&2; exit 1; }
[ "${1:-}" = mcp ] && [ "${2:-}" = add ] || exit 0
shift 2
name=""; envs=""
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    -s|--scope|-t|--transport) shift 2 ;;
    -e|--env)
      shift
      while [ $# -gt 0 ]; do
        case "$1" in -*) break ;; esac
        case "$1" in
          *=*) envs="$envs $1"; shift ;;
          *) echo "Invalid environment variable format: $1, environment variables should be added as: -e KEY1=value1 -e KEY2=value2" >&2; exit 1 ;;
        esac
      done ;;
    -*) shift ;;
    *) [ -z "$name" ] && name="$1"; shift ;;
  esac
done
[ -n "$name" ] && [ $# -gt 0 ] || { echo "stub claude: missing name or command" >&2; exit 1; }
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then f="$CLAUDE_CONFIG_DIR/.claude.json"; else f="$HOME/.claude.json"; fi
mkdir -p "$(dirname "$f")"; [ -f "$f" ] || echo '{}' > "$f"
e='{}'; for kv in $envs; do e="$(printf '%s' "$e" | jq --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k] = $v')"; done
jq --arg n "$name" --arg c "$1" --argjson e "$e" '.mcpServers[$n] = {type: "stdio", command: $c, env: $e}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
echo "Added stdio MCP server $name"
STUB
  fi
  printf '#!/bin/bash\nexit 0\n' > "$d/uvx"
  printf '#!/bin/bash\nexit 0\n' > "$d/npx"
  chmod +x "$d"/*
}
STUBS="$WORK/stubs"; _mkstubs "$STUBS" yes

# _mirror_without DIR NAME — every executable on PATH, symlinked, EXCEPT NAME:
# "this machine has no `claude`" without losing the rest of PATH. (Appending
# /usr/bin:/bin as a safety net would defeat it for a tool that lives there;
# asserted with `command -v` before it is trusted.)
_mirror_without() {
  local dir="$1" skipname="$2" d="" f="" n="" rest="$PATH:"
  mkdir -p "$dir" || return 1
  while [ -n "$rest" ]; do
    d="${rest%%:*}"; rest="${rest#*:}"
    [ -n "$d" ] && [ -d "$d" ] || continue
    for f in "$d"/*; do
      n="${f##*/}"
      [ "$n" = "$skipname" ] && continue
      [ -x "$f" ] && [ ! -e "$dir/$n" ] && ln -s "$f" "$dir/$n" 2>/dev/null
    done
  done
  return 0
}

# ── fixtures ────────────────────────────────────────────────────────────────
_base() {   # _base DIR — a small TypeScript project with its own history
  local p="$1"
  mkdir -p "$p/src" || return 1
  ( cd "$p" && git init -q . && git config user.email bl311@test.invalid && git config user.name "BL-311 Test" ) >/dev/null 2>&1
  printf '{"name":"acme","scripts":{"test":"exit 0"}}\n' > "$p/package.json"
  printf 'export const x = 1;\n' > "$p/src/index.ts"
  ( cd "$p" && git add -- package.json src/index.ts && git commit -q --no-verify -m "chore: their history" ) >/dev/null 2>&1
}
_register() {   # _register FILE qdrant|context7 [URL]
  local f="$1" s="$2" u="${3:-http://localhost:6333}"
  mkdir -p "$(dirname "$f")"; [ -f "$f" ] || echo '{}' > "$f"
  case "$s" in
    qdrant)   jq --arg u "$u" '.mcpServers.qdrant = {command: "uvx", env: {QDRANT_URL: $u}}' "$f" > "$f.tmp" ;;
    context7) jq '.mcpServers.context7 = {command: "npx", args: ["-y", "@upstash/context7-mcp"]}' "$f" > "$f.tmp" ;;
  esac
  mv "$f.tmp" "$f"
}
_case() {   # _case TAG — a fresh HOME, CLAUDE_CONFIG_DIR, stub state and adoptee
  # FRESH EVERY TIME, never reused by tag: the mutation pass re-runs these
  # cases, and a first draft that reused "$WORK/<tag>" had every adoption
  # mutant "killed" by "this project has already been adopted" — a failure
  # that says nothing about the guard under test. `mut` now requires each
  # mutant to die by its NAMED assertion, so that cannot hide again.
  C="$(mktemp -d "$WORK/$1.XXXXXX")" || return 1
  H="$C/home"; CFG="$C/cfg"; ST="$C/state"; P="$C/proj"
  mkdir -p "$H" "$CFG" "$ST" "$C/w" || return 1
  : > "$ST/calls.log"; : > "$ST/curl.log"
  _base "$P"
}
_n1() { local i=0 out=""; while [ "$i" -lt "$1" ]; do out="${out}1\n"; i=$((i + 1)); done; printf '%s' "$out"; }
FW="$REPO_ROOT"
RUN_PATH="$STUBS:$PATH"
# _adopt ANSWERS [ENV=VAL...] — a whole adoption of $P, with this case's HOME,
# CLAUDE_CONFIG_DIR and stubs.
_adopt() {
  local ans="$1"; shift
  ( cd "$P" && printf "$ans" | env PATH="$RUN_PATH" HOME="$H" CLAUDE_CONFIG_DIR="$CFG" STUB_STATE="$ST" \
      SOIF_ADOPT_GUARDRAILS_DIR="$WORK/no-guardrails" SOIF_ADOPT_QDRANT_WAIT=2 "$@" \
      bash "$FW/scripts/adopt-project.sh" ) > "$C/out" 2>&1
  RUN_RC=$?
}
# _step ANSWERS — the MCP step alone, sourced the way the driver sources it,
# run from inside the adoptee so a command that ignores the work dir shows it.
cat > "$WORK/harness.sh" <<'HARN'
set -uo pipefail
ADOPT_FRAMEWORK_ROOT="$1"; ADOPT_CORE_LIB_DIR="$1/scripts/lib"; ADOPT_WORK="$2"
. "$ADOPT_CORE_LIB_DIR/helpers-core.sh"
. "$1/scripts/lib/adopt/adopt-core.sh"
. "$1/scripts/lib/adopt/adopt-mcp.sh"
adopt_stdin_init
adopt_mcp_resolve "$3"; rc=$?
printf 'RC=%s\nRESULT=%s\n' "$rc" "$ADOPT_MCP_RESULT"
HARN
_step() {
  local ans="$1"
  ( cd "$P" && printf "$ans" | env PATH="$RUN_PATH" HOME="$H" CLAUDE_CONFIG_DIR="$CFG" STUB_STATE="$ST" \
      SOIF_ADOPT_QDRANT_WAIT=2 bash "$WORK/harness.sh" "$FW" "$C/w" "$P" ) > "$C/out" 2>&1
  STEP_RC="$(sed -n 's/^RC=//p' "$C/out" | tail -1)"
  STEP_RESULT="$(sed -n 's/^RESULT=//p' "$C/out" | tail -1)"
}
_cmd_line() { local w out="$1"; for w in $2; do out="$out [$w]"; done; printf '%s' "$out"; }   # argv as the stubs log it
_line_of() { grep -nF -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }
_record() { grep -F '| MCP servers (Qdrant, Context7) |' "$P/APPROVAL_LOG.md" 2>/dev/null | head -1; }
_calls_ran() { grep -qE '\[mcp\] \[add\]|docker \[(start|run)\]' "$ST/calls.log"; }
_plan() { grep -A"$1" 'This would run, exactly as written:' "$C/out" | tail -"$1" | tr '\n' '|'; }

QADD='claude mcp add -s user qdrant -e QDRANT_URL=http://localhost:6333 -e COLLECTION_NAME=claude-memory -- uvx --python 3.13 mcp-server-qdrant'
C7ADD='claude mcp add context7 --scope user -- npx -y @upstash/context7-mcp'
QRUN='docker run -d --name qdrant -p 6333:6333 -p 6334:6334 -v qdrant_storage:/qdrant/storage --restart unless-stopped qdrant/qdrant:latest'
QSTART='docker start qdrant'

# ── A — the config-location helpers, and their three consumers ─────────────
cat > "$WORK/unit.sh" <<'UNIT'
. "$1/scripts/lib/helpers-full.sh"
is_context7_mcp_registered && echo c7=yes || echo c7=no
is_qdrant_mcp_entry_present && echo qe=yes || echo qe=no
echo "reg=$(qdrant_mcp_reg_file)"
UNIT
_unit() { env HOME="$H" "$@" bash "$WORK/unit.sh" "$FW" 2>/dev/null; }

a1() {
  local out="" bad=""
  _case a1 >/dev/null
  _register "$CFG/.claude.json" qdrant; _register "$CFG/.claude.json" context7
  out="$(_unit CLAUDE_CONFIG_DIR="$CFG")"
  printf '%s\n' "$out" | grep -qx 'c7=yes' || bad="$bad [context7 not seen]"
  printf '%s\n' "$out" | grep -qx 'qe=yes' || bad="$bad [qdrant entry not seen]"
  printf '%s\n' "$out" | grep -qxF "reg=$CFG/.claude.json" || bad="$bad [reg file is not \$CLAUDE_CONFIG_DIR/.claude.json]"
  [ -z "$bad" ] && pass "A1 a registration only in \$CLAUDE_CONFIG_DIR/.claude.json is seen by all three helpers" || fail_ "A1" "$bad — $(printf '%s' "$out" | tr '\n' ' ')"

  _case a2 >/dev/null
  _register "$H/.claude.json" qdrant; _register "$H/.claude.json" context7
  out="$(_unit CLAUDE_CONFIG_DIR="$CFG")"
  if printf '%s\n' "$out" | grep -qx 'c7=no' && printf '%s\n' "$out" | grep -qx 'qe=no' && printf '%s\n' "$out" | grep -qx 'reg='; then
    pass "A2 a registration only in ~/.claude.json is NOT seen while CLAUDE_CONFIG_DIR is set — the session does not read that file"
  else fail_ "A2" "[a ~/.claude.json registration seen] $(printf '%s' "$out" | tr '\n' ' ')"; fi

  out="$(_unit CLAUDE_CONFIG_DIR=)"
  if printf '%s\n' "$out" | grep -qx 'c7=yes' && printf '%s\n' "$out" | grep -qx 'qe=yes' && printf '%s\n' "$out" | grep -qxF "reg=$H/.claude.json"; then
    pass "A3 with CLAUDE_CONFIG_DIR unset, ~/.claude.json is read as before"
  else fail_ "A3" "$(printf '%s' "$out" | tr '\n' ' ')"; fi
}

a4() {
  local out="" bad=""
  _case a4 >/dev/null
  jq -n '{enabledPlugins: {"context7@claude-plugins-official": true}}' > "$CFG/settings.json"
  out="$(_unit CLAUDE_CONFIG_DIR="$CFG")"
  printf '%s\n' "$out" | grep -qx 'c7=yes' || bad="$bad [plugin in \$CLAUDE_CONFIG_DIR/settings.json not seen]"
  mkdir -p "$H/.claude"; cp "$CFG/settings.json" "$H/.claude/settings.json"; rm -f "$CFG/settings.json"
  out="$(_unit CLAUDE_CONFIG_DIR="$CFG")"
  printf '%s\n' "$out" | grep -qx 'c7=no' || bad="$bad [plugin in ~/.claude/settings.json seen while CLAUDE_CONFIG_DIR is set]"
  [ -z "$bad" ] && pass "A4 settings.json follows CLAUDE_CONFIG_DIR too" || fail_ "A4" "$bad"
}

a5() {   # the SessionStart hook: home-only → not required; in CLAUDE_CONFIG_DIR → required
  local out=""
  _case a5 >/dev/null
  mkdir -p "$C/p5/.claude"
  _register "$H/.claude.json" qdrant; _register "$H/.claude.json" context7
  ( cd "$C/p5" && env HOME="$H" CLAUDE_CONFIG_DIR="$CFG" bash "$FW/scripts/session-test-gate-check.sh" </dev/null >/dev/null 2>&1 )
  out="$(jq -c '[.mcp_requirements.qdrant_required, .mcp_requirements.context7_required]' "$C/p5/.claude/tool-usage.json" 2>/dev/null)"
  _register "$CFG/.claude.json" qdrant; _register "$CFG/.claude.json" context7
  ( cd "$C/p5" && env HOME="$H" CLAUDE_CONFIG_DIR="$CFG" bash "$FW/scripts/session-test-gate-check.sh" </dev/null >/dev/null 2>&1 )
  out="$out $(jq -c '[.mcp_requirements.qdrant_required, .mcp_requirements.context7_required]' "$C/p5/.claude/tool-usage.json" 2>/dev/null)"
  if [ "$out" = "[false,false] [true,true]" ]; then
    pass "A5 the SessionStart hook requires a server registered in \$CLAUDE_CONFIG_DIR, and not one registered only in ~/.claude.json"
  else fail_ "A5" "requirements (home-only, then cfg) = '$out' (want '[false,false] [true,true]')"; fi
}

a6() {   # check-versions.sh, over the two rows the framework SHIPS
  local out="" bad=""
  _case a6 >/dev/null
  mkdir -p "$C/p6/templates/tool-matrix" "$C/p6/.claude"
  jq '{description: "fixture", schema_version: 1, scope: "common",
       tools: (.tools | map(select(.name == "Qdrant MCP" or .name == "Context7 MCP")))}' \
    "$FW/templates/tool-matrix/common.json" > "$C/p6/templates/tool-matrix/common.json"
  _register "$H/.claude.json" qdrant; _register "$H/.claude.json" context7
  out="$( cd "$C/p6" && env PATH="$RUN_PATH" HOME="$H" CLAUDE_CONFIG_DIR="$CFG" STUB_STATE="$ST" bash "$FW/scripts/check-versions.sh" 2>&1 )"
  printf '%s\n' "$out" | grep -q 'Qdrant MCP: NOT registered with Claude Code' || bad="$bad [Qdrant not reported NOT registered]"
  printf '%s\n' "$out" | grep -q 'Context7 MCP: NOT registered with Claude Code' || bad="$bad [Context7 not reported NOT registered]"
  printf '%s\n' "$out" | grep -q '\[OK\] Qdrant MCP\|\[OK\] Context7 MCP' && bad="$bad [an [OK] row for a server the session does not have]"
  printf '%s\n' "$out" | grep -qF "$CFG/.claude.json" || bad="$bad [the note does not name the file it read]"
  _register "$CFG/.claude.json" context7
  out="$( cd "$C/p6" && env PATH="$RUN_PATH" HOME="$H" CLAUDE_CONFIG_DIR="$CFG" STUB_STATE="$ST" bash "$FW/scripts/check-versions.sh" 2>&1 )"
  printf '%s\n' "$out" | grep -q 'Context7 MCP: NOT registered' && bad="$bad [Context7 registered in \$CLAUDE_CONFIG_DIR still reported NOT registered]"
  [ -z "$bad" ] && pass "A6 check-versions.sh reports NOT registered — not [OK] — for servers registered only in a file the session does not read, and sees one registered where it does" \
    || fail_ "A6" "$bad — $(printf '%s' "$out" | grep -i 'MCP' | tr '\n' '|' | cut -c1-400)"
}

# ── S — the step on its own ─────────────────────────────────────────────────
s1() {   # nothing missing: no question, nothing run
  _case s1 >/dev/null
  _register "$CFG/.claude.json" qdrant; _register "$CFG/.claude.json" context7
  : > "$ST/qdrant-up"; : > "$ST/docker-up"
  _step "set it up now\n"
  if [ "$STEP_RC" = 0 ] && ! grep -q 'Set them up now' "$C/out" && ! _calls_ran \
     && [ "$STEP_RESULT" = "Qdrant: registered and answering before adoption; Context7: registered before adoption" ]; then
    pass "S1 both registered and answering: no question, nothing run"
  else fail_ "S1" "[asked, or ran, with nothing missing] rc=$STEP_RC result='$STEP_RESULT' asked=$(grep -c 'Set them up now' "$C/out")"; fi
}

s2() {   # set it up now
  local bad="" lq="" l1="" c=""
  _case s2 >/dev/null
  : > "$ST/docker-up"
  _step "set it up now\n"
  [ "$STEP_RC" = 0 ] || bad="$bad [rc $STEP_RC]"
  lq="$(_line_of "$C/out" 'Set them up now?')"
  for c in "$C7ADD" "$QRUN" "$QADD"; do
    l1="$(grep -nxF -- "     $c" "$C/out" | head -1 | cut -d: -f1)"
    { [ -n "$l1" ] && [ -n "$lq" ] && [ "$l1" -lt "$lq" ]; } || bad="$bad [not shown before the question: $c]"
    grep -qF -- "$(_cmd_line "${c%% *}" "${c#* }")" "$ST/calls.log" || bad="$bad [not run as shown: $c]"
  done
  grep -E '\[mcp\] \[add\]|docker \[run\]' "$ST/calls.log" | grep -qF "cwd=$P" && bad="$bad [a command ran with the adoptee as its cwd]"
  grep -E '\[mcp\] \[add\]|docker \[run\]' "$ST/calls.log" | grep -vqF "cwd=$C/w" && bad="$bad [a command did not run from the work dir]"
  jq -e '.mcpServers.qdrant.env.QDRANT_URL == "http://localhost:6333" and .mcpServers.context7.command == "npx"' "$CFG/.claude.json" >/dev/null 2>&1 \
    || bad="$bad [the registrations are not in \$CLAUDE_CONFIG_DIR/.claude.json]"
  [ -e "$H/.claude.json" ] && bad="$bad [something wrote ~/.claude.json]"
  [ "$STEP_RESULT" = "Qdrant: set up by adoption, registered and answering; Context7: set up by adoption, registered" ] || bad="$bad [result '$STEP_RESULT']"
  [ -z "$bad" ] && pass "S2 set it up now: the three commands shown before the question, run exactly as shown from the work dir, registered in the session's config, and read back by the receipt" || fail_ "S2" "$bad"
}

s3() {   # registered but silent + skip
  local bad=""
  _case s3 >/dev/null
  _register "$CFG/.claude.json" qdrant
  : > "$ST/docker-up"; : > "$ST/qdrant-exists"
  _step "skip it\n"
  [ "$(_plan 2)" = "     $C7ADD|     $QSTART|" ] || bad="$bad [plan '$(_plan 2)' — the container exists, so 'docker start qdrant']"
  _calls_ran && bad="$bad [something ran]"
  grep -q 'EVERY file edit is BLOCKED until qdrant-find succeeds' "$C/out" || bad="$bad [the note does not say every edit is blocked]"
  [ "$STEP_RESULT" = "Qdrant: registered, NOT answering (skipped); Context7: NOT registered (skipped)" ] || bad="$bad [result '$STEP_RESULT']"
  [ -z "$bad" ] && pass "S3 registered but not answering + skip: the plan starts the existing container, and the note says every file edit is blocked" || fail_ "S3" "$bad"
}

s4() {   # unregistered, a database already answering + skip
  local bad=""
  _case s4 >/dev/null
  : > "$ST/docker-up"; : > "$ST/qdrant-up"; : > "$ST/qdrant-exists"
  _step "skip it\n"
  [ "$(_plan 2)" = "     $C7ADD|     $QADD|" ] || bad="$bad [plan '$(_plan 2)' — the database already answers, so only the two registrations]"
  grep -q "framework's check for it is off while it is not registered" "$C/out" || bad="$bad [the note does not say the check is off]"
  grep -q 'EVERY file edit is BLOCKED' "$C/out" && bad="$bad [a block claimed for servers registered nowhere]"
  [ -z "$bad" ] && pass "S4 not registered + skip: only the registrations are offered (the database already answers), and the note says the check is off — not that edits are blocked" || fail_ "S4" "$bad"
}

s5() {   # a blank answer is skip
  _case s5 >/dev/null
  : > "$ST/docker-up"
  _step "\n"
  if [ "$STEP_RC" = 0 ] && grep -q 'No answer — treated as skip it.' "$C/out" && ! _calls_ran; then
    pass "S5 a blank answer to the MCP question is 'skip it'"
  else fail_ "S5" "[not treated as skip] rc=$STEP_RC; $(grep -E 'REFUSED|BLOCKED' "$C/out" | head -1)"; fi
}

s6() {   # end of input is skip
  _case s6 >/dev/null
  : > "$ST/docker-up"
  _step ""
  if [ "$STEP_RC" = 0 ] && [ "$STEP_RESULT" = "Qdrant: NOT registered (skipped); Context7: NOT registered (skipped)" ] && ! _calls_ran; then
    pass "S6 end of input at the MCP question is 'skip it' (rc 0, nothing run) — it never refuses the way a mandatory question does"
  else fail_ "S6" "[end of input not treated as skip] rc=$STEP_RC result='$STEP_RESULT'"; fi
}

s7() {   # the commands fail: the receipt must not claim them
  local bad=""
  _case s7 >/dev/null
  : > "$ST/docker-up"; : > "$ST/claude-fails"
  _step "set it up now\n"
  grep -q 'That did not succeed: stub claude: refusing on purpose' "$C/out" || bad="$bad [the failure's own words were not shown]"
  [ "$STEP_RESULT" = "Qdrant: NOT registered after adoption tried; Context7: NOT registered after adoption tried" ] || bad="$bad [result claims a setup: '$STEP_RESULT']"
  [ -z "$bad" ] && pass "S7 the commands fail: the run shows why, and the result says NOT registered — the exit of a command is not a receipt" || fail_ "S7" "$bad"
}

s8() {   # an answer that is not offered
  _case s8 >/dev/null
  : > "$ST/docker-up"
  _step "maybe\n"
  if [ "$STEP_RC" = 1 ] && grep -q "\[REFUSED\] 'maybe' is not one of the answers offered for: setting up the MCP servers" "$C/out" && ! _calls_ran; then
    pass "S8 an answer that is not one of the two offered is refused, before anything runs"
  else fail_ "S8" "rc=$STEP_RC; $(grep -E 'REFUSED|BLOCKED' "$C/out" | head -1)"; fi
}

s9() {   # the database never answers: not registered against
  local bad=""
  _case s9 >/dev/null
  : > "$ST/docker-up"; : > "$ST/docker-run-noop"
  _step "set it up now\n"
  grep -qF -- "$(_cmd_line docker "${QRUN#* }")" "$ST/calls.log" || bad="$bad [docker run did not run]"
  grep -q '\[mcp\] \[add\] \[-s\] \[user\] \[qdrant\]' "$ST/calls.log" && bad="$bad [Qdrant was registered with no database behind it]"
  grep -q '\[mcp\] \[add\] \[context7\]' "$ST/calls.log" || bad="$bad [Context7, independent of it, was not set up]"
  [ -z "$bad" ] && pass "S9 a database that never answers is not registered against — that would make it required and block every edit — and Context7 still is" || fail_ "S9" "$bad"
}

# ── E — whole adoptions ─────────────────────────────────────────────────────
HAVE_GITLEAKS=0; command -v gitleaks >/dev/null 2>&1 && HAVE_GITLEAKS=1

e1() {   # both present; the Record row; the restart sentence before NEXT
  local bad="" rec="" l1="" l2=""
  _case e1 >/dev/null
  _register "$CFG/.claude.json" qdrant; _register "$CFG/.claude.json" context7
  : > "$ST/qdrant-up"; : > "$ST/docker-up"
  _adopt "$(_n1 12)"
  [ "$RUN_RC" -eq 0 ] || bad="$bad [rc $RUN_RC: $(grep -E 'BLOCKED|REFUSED' "$C/out" | head -1)]"
  grep -q 'Set them up now' "$C/out" && bad="$bad [asked anyway]"
  rec="$(_record)"
  printf '%s' "$rec" | grep -q 'Qdrant: registered and answering before adoption; Context7: registered before adoption' || bad="$bad [record row: '$rec']"
  [ -z "$bad" ] && pass "E1 a whole adoption with both present: no question, and the Adoption Record carries the MCP row" || fail_ "E1" "$bad"
  l1="$(_line_of "$C/out" 'FIRST: if a Claude Code session is open in this project, close it and start a new')"
  l2="$(_line_of "$C/out" 'NEXT: run this, and paste what it prints into Claude Code.')"
  if [ -n "$l1" ] && [ -n "$l2" ] && [ "$l1" -lt "$l2" ] && grep -q 'open cannot save a file here.' "$C/out"; then
    pass "E1b Act 2 tells the operator to close any open Claude Code session and start a new one, BEFORE 'NEXT'"
  else fail_ "E1b" "restart line at '${l1:-absent}', NEXT at '${l2:-absent}'"; fi
}

e2() {   # set it up now, whole adoption
  local bad="" rec=""
  _case e2 >/dev/null
  : > "$ST/docker-up"
  _adopt "1\nset it up now\n$(_n1 12)"
  [ "$RUN_RC" -eq 0 ] || bad="$bad [rc $RUN_RC: $(grep -E 'BLOCKED|REFUSED' "$C/out" | head -1)]"
  grep -q 'STDIN-HAD-DATA' "$ST/calls.log" && bad="$bad [a command read the operator's answers]"
  grep -E '\[mcp\] \[add\]|docker \[run\]' "$ST/calls.log" | grep -q 'cwd=.*adopt-work\.' || bad="$bad [the commands did not run from the run's work dir]"
  rec="$(_record)"
  printf '%s' "$rec" | grep -q 'Qdrant: set up by adoption, registered and answering; Context7: set up by adoption, registered' || bad="$bad [record row: '$rec']"
  [ -f "$P/.claude/settings.local.json" ] || bad="$bad [the project collection was not declared once Qdrant was registered]"
  [ -z "$bad" ] && pass "E2 set it up now inside a whole adoption: no command read the operator's answers, the Record says set up, and the project collection is declared" || fail_ "E2" "$bad"
}

e3() {   # skip, whole adoption
  local bad="" rec=""
  _case e3 >/dev/null
  : > "$ST/docker-up"
  _adopt "1\nskip it\n$(_n1 12)"
  [ "$RUN_RC" -eq 0 ] || bad="$bad [rc $RUN_RC]"
  _calls_ran && bad="$bad [something ran]"
  rec="$(_record)"
  printf '%s' "$rec" | grep -q 'Qdrant: NOT registered (skipped); Context7: NOT registered (skipped)' || bad="$bad [record row: '$rec']"
  grep -q 'Qdrant or Context7 is NOT set up' "$C/out" || bad="$bad [the closing does not point back at it]"
  [ -z "$bad" ] && pass "E3 skip inside a whole adoption: nothing run, the Record row says skipped, and the closing points back at the note" || fail_ "E3" "$bad"
}

e4() {   # no claude command: the CI shape
  local bad="" rec=""
  _case e4 >/dev/null
  _mkstubs "$C/stubs" no
  _mirror_without "$C/mirror" claude
  if PATH="$C/stubs:$C/mirror" command -v claude >/dev/null 2>&1; then
    fail_ "E4" "the isolated PATH still has a claude command — the fixture cannot measure its absence"; return
  fi
  RUN_PATH="$C/stubs:$C/mirror" _adopt "$(_n1 12)"
  [ "$RUN_RC" -eq 0 ] || bad="$bad [rc $RUN_RC: $(grep -E 'BLOCKED|REFUSED' "$C/out" | head -1)]"
  grep -q 'Set them up now' "$C/out" && bad="$bad [asked with nothing it could do]"
  grep -q 'Adoption cannot set up Context7 here: the claude command is not on PATH.' "$C/out" || bad="$bad [Context7 reason missing]"
  grep -q 'Adoption cannot set up Qdrant here: the claude command is not on PATH.' "$C/out" || bad="$bad [Qdrant reason missing]"
  grep -qF -- "  $C7ADD" "$C/out" || bad="$bad [no command for later]"
  rec="$(_record)"
  printf '%s' "$rec" | grep -q 'adoption could not act: the claude command is not on PATH' || bad="$bad [record row: '$rec']"
  [ -z "$bad" ] && pass "E4 no claude command: no question, the reason and the commands for later, and an answer sequence written without this step completes" || fail_ "E4" "$bad"
}

e5() {   # registered but silent + skip: the adopted project's own gate blocks, on Qdrant only
  local bad="" g=""
  _case e5 >/dev/null
  _register "$CFG/.claude.json" qdrant
  : > "$ST/docker-up"; : > "$ST/qdrant-exists"
  _adopt "1\nskip it\n$(_n1 12)"
  [ "$RUN_RC" -eq 0 ] || bad="$bad [rc $RUN_RC]"
  ( cd "$P" && env HOME="$H" CLAUDE_CONFIG_DIR="$CFG" bash scripts/session-test-gate-check.sh </dev/null >/dev/null 2>&1 )
  g="$( cd "$P" && printf '{"tool_name":"Write"}' | env HOME="$H" CLAUDE_CONFIG_DIR="$CFG" bash scripts/session-mcp-gate.sh 2>&1 )"
  printf '%s' "$g" | grep -q '"permissionDecision": "deny"' || bad="$bad [the project's gate ALLOWED a Write — S3's sentence would over-claim]"
  printf '%s' "$g" | grep -q 'qdrant-find' || bad="$bad [the block is not Qdrant's]"
  printf '%s' "$g" | grep -q 'context7 query-docs' && bad="$bad [Context7, registered nowhere, was required]"
  [ -z "$bad" ] && pass "E5 registered but not answering: the adopted project's own gate DOES block a Write, on Qdrant and not on the unregistered Context7 — the note's sentence is the gate's behaviour" || fail_ "E5" "$bad"
}

e6() {   # THE DOGFOOD SHAPE: registered only in ~/.claude.json, a clean
         # CLAUDE_CONFIG_DIR, a database running, uvx present — skip. Nothing may
         # be declared for the project, and a later session must be able to write.
  local bad="" g=""
  _case e6 >/dev/null
  _register "$H/.claude.json" qdrant; _register "$H/.claude.json" context7
  : > "$ST/docker-up"; : > "$ST/qdrant-up"; : > "$ST/qdrant-exists"
  _adopt "1\nskip it\n$(_n1 12)"
  [ "$RUN_RC" -eq 0 ] || bad="$bad [rc $RUN_RC]"
  grep -q 'Qdrant (memory across sessions): NOT registered for Claude Code.' "$C/out" || bad="$bad [the ~/.claude.json registration was read]"
  [ -e "$P/.claude/settings.local.json" ] && bad="$bad [a Qdrant declaration was written for a session that has no Qdrant]"
  jq -e '.mcp.qdrant_required == true' "$P/.claude/manifest.json" >/dev/null 2>&1 && bad="$bad [the manifest requires Qdrant]"
  ( cd "$P" && env HOME="$H" CLAUDE_CONFIG_DIR="$CFG" bash scripts/session-test-gate-check.sh </dev/null >/dev/null 2>&1 )
  [ -f "$P/.claude/tool-usage.json" ] || bad="$bad [the SessionStart hook wrote no ledger, so an allow would prove nothing]"
  g="$( cd "$P" && printf '{"tool_name":"Write"}' | env HOME="$H" CLAUDE_CONFIG_DIR="$CFG" bash scripts/session-mcp-gate.sh 2>&1 )"
  [ -z "$g" ] || bad="$bad [the project's gate did not allow a Write: $(printf '%s' "$g" | cut -c1-160)]"
  [ -z "$bad" ] && pass "E6 the dogfood shape: the ~/.claude.json registration is not the session's, nothing is declared for the project, and a session started afterwards can write" || fail_ "E6" "$bad"
}

e_cases() {
  if [ "$HAVE_GITLEAKS" -ne 1 ]; then
    skip "E1-E6" "gitleaks is not on PATH — a personal adoption stops at the secrets check without it"
    return 0
  fi
  e1; e2; e3; e4; e5; e6
}

if [ -n "${BL311_ONLY:-}" ]; then
  for _f in $BL311_ONLY; do "$_f"; done
  _done
fi
a1; a4; a5; a6
s1; s2; s3; s4; s5; s6; s7; s8; s9
e_cases

# ── M — mutation proofs ─────────────────────────────────────────────────────
# Each mutant replaces the ONE line ending in its marker, in a COPY of the
# framework, asserts the replacement landed by its own text and still parses,
# and re-runs only the case that must kill it — and the kill must come from
# the NAMED assertion. A mutation that did not apply is a harness FAILURE,
# never a kill.
_mirror_fw() { mkdir -p "$1" && cp -Rp "$REPO_ROOT/scripts" "$REPO_ROOT/templates" "$1/" && cp -p "$REPO_ROOT/init.sh" "$1/"; }
_mutate() {   # FILE MARKER REPLACEMENT
  local f="$1" n=""
  MUT_MARK="$2" MUT_REPL="$3" awk '
    { m = ENVIRON["MUT_MARK"]; L = length($0); K = length(m)
      if (L >= K && substr($0, L - K + 1) == m) { print ENVIRON["MUT_REPL"]; n++ } else print }
    END { print n + 0 > "/dev/stderr" }' "$f" > "$f.mut" 2> "$f.n" || return 1
  n="$(cat "$f.n")"; rm -f "$f.n"
  [ "$n" = "1" ] || { echo "sites=$n"; rm -f "$f.mut"; return 1; }
  mv "$f.mut" "$f" || return 1
  grep -qxF -- "$3" "$f" || { echo "replacement not found"; return 1; }
  bash -n "$f" 2>/dev/null || { echo "mutant does not parse"; return 1; }
  return 0
}
mut() {   # LABEL FILE MARKER REPLACEMENT CASE-FN WANT — WANT is the assertion text that must kill it
  local label="$1" rel="$2" marker="$3" repl="$4" fn="$5" want="$6" m="" r="" p0="" f0="" why=""
  case "$fn" in e*) if [ "$HAVE_GITLEAKS" -ne 1 ]; then skip "$label" "its killing case needs gitleaks"; return; fi ;; esac
  m="$WORK/mut-$(printf '%s' "$marker" | tr -c 'A-Za-z0-9' '-')"
  _mirror_fw "$m" || { fail_ "$label" "could not mirror the framework"; return; }
  r="$(_mutate "$m/$rel" "$marker" "$repl")" || { fail_ "$label" "the mutation did not apply ($r)"; return; }
  p0=$PASSED; f0=$FAILED
  FW="$m"; "$fn" > "$m.out" 2>&1; FW="$REPO_ROOT"
  # THE KILL MUST BE THE INTENDED ASSERTION. The first draft of this section
  # "killed" every adoption mutant with "this project has already been
  # adopted", because the cases reused their fixtures.
  why="$(grep '\[FAIL\]' "$m.out" | sed 's/^ *\[FAIL\] //' | tr '\n' ' ')"
  PASSED=$p0
  if [ "$FAILED" -le "$f0" ]; then FAILED=$f0; fail_ "$label" "the mutant survived"
  elif printf '%s' "$why" | grep -qF -- "$want"; then FAILED=$f0; pass "$label"
  else FAILED=$f0; fail_ "$label" "killed, but not by '$want': $(printf '%s' "$why" | cut -c1-240)"; fi
  rm -rf "$m" "$m.out"
}

# TWO GUARDS HAVE NO KILLING CASE, AND THAT IS MEASURED, NOT OVERLOOKED. The
# `</dev/null` on the setup commands (`# BL-311-MCP-RUN`) and on the
# registration probes (`# BL-311-MCP-PROBE-STDIN`): with either removed, the
# stubs — which drain and report any stdin they are given — received none,
# inside a whole adoption, while the Docker probe's identical omission (M20)
# handed its stub every remaining answer. Both survivors run inside a `( … )`
# subshell and M20 does not; the cause is not isolated. They stay because the
# consent rule asks for them, and they are reported as survivors rather than
# given a mutant that would pass for the wrong reason.
if [ "${BL311_SKIP_MUTANTS:-0}" = "1" ]; then skip "M1-M20" "BL311_SKIP_MUTANTS=1"; _done; fi
echo "== M — mutation proofs =="
mut "M1 helpers-core ignores CLAUDE_CONFIG_DIR for settings.json — killed by A4" \
  scripts/lib/helpers-core.sh '# BL-311-CONFIG-DIR' \
  '  printf '"'"'%s'"'"' "$HOME/.claude"   # BL-311-CONFIG-DIR' \
  a4 'plugin in'
mut "M2 helpers-core ignores CLAUDE_CONFIG_DIR for .claude.json — killed by A1" \
  scripts/lib/helpers-core.sh '# BL-311-CONFIG-JSON' \
  '  printf '"'"'%s/.claude.json'"'"' "$HOME"   # BL-311-CONFIG-JSON' \
  a1 '[context7 not seen]'
mut "M3 qdrant_mcp_reg_file back on fixed paths — killed by A1" \
  scripts/lib/helpers-full.sh '# BL-311-QDRANT-REG-FILE' \
  '  for f in "$HOME/.claude.json" "$HOME/.claude/settings.json"; do   # BL-311-QDRANT-REG-FILE' \
  a1 '[reg file is not'
mut "M4 the SessionStart hook back on fixed paths — killed by A5" \
  scripts/session-test-gate-check.sh '# BL-311-GATE-CONFIG' \
  '  _cc_set="$HOME/.claude/settings.json"; _cc_json="$HOME/.claude.json"   # BL-311-GATE-CONFIG' \
  a5 'A5 — requirements'
mut "M5 probe-tool back on fixed paths — killed by A6" \
  scripts/probe-tool.sh '# BL-311-PROBE-CONFIG' \
  '  printf '"'"'%s\n%s\n'"'"' "$HOME/.claude/settings.json" "$HOME/.claude.json"   # BL-311-PROBE-CONFIG' \
  a6 'an [OK] row for a server the session does not have'
mut "M6 check-versions says 'not installed' for an MCP row — killed by A6" \
  scripts/check-versions.sh '# BL-311-CV-NOT-REGISTERED' \
  '      print_warn "$NAME: not installed${CHECK_NOTE:+ — $CHECK_NOTE}"   # BL-311-CV-NOT-REGISTERED' \
  a6 'Qdrant not reported NOT registered'
mut "M7 the question asked with nothing to do — killed by S1" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-ASK-ONLY-IF-ACTIONABLE' \
  '  if [ 1 -gt 0 ]; then            # BL-311-MCP-ASK-ONLY-IF-ACTIONABLE' \
  s1 'asked, or ran, with nothing missing'
mut "M8 no answer refuses, like a mandatory question — killed by S6" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-EOF-SKIP' \
  '    if false; then                                   # BL-311-MCP-EOF-SKIP' \
  s6 'end of input not treated as skip'
mut "M9 the commands not shown before the question — killed by S2" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-SHOWN-FIRST' \
  '    :   # BL-311-MCP-SHOWN-FIRST' \
  s2 'not shown before the question: claude mcp add context7'
mut "M10 the commands run from the adoptee, not the work dir — killed by S2" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-RUN' \
  '  ( run_with_deadline "$secs" bash -c "$cmd" ) </dev/null >>"$ADOPT_WORK/mcp-setup.out" 2>&1 || rc=$?   # BL-311-MCP-RUN' \
  s2 'a command ran with the adoptee as its cwd'
mut "M11 the receipt assumes success — killed by S7" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-RECEIPT' \
  '    st="registered reachable http://localhost:6333"   # BL-311-MCP-RECEIPT' \
  s7 'result claims a setup'
mut "M12 the Addendum's argument order (name after -e) — killed by S2" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-QDRANT-ADD' \
  "ADOPT_MCP_QDRANT_ADD='claude mcp add -s user -e QDRANT_URL=http://localhost:6333 -e COLLECTION_NAME=claude-memory qdrant -- uvx --python 3.13 mcp-server-qdrant'   # BL-311-MCP-QDRANT-ADD" \
  s2 'the registrations are not in'
mut "M13 registered without waiting for the database — killed by S9" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-WAIT-BEFORE-REGISTER' \
  '            :   # BL-311-MCP-WAIT-BEFORE-REGISTER' \
  s9 'Qdrant was registered with no database behind it'
mut "M14 the every-edit-is-blocked sentence dropped — killed by S3" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-NOTE-BLOCKS' \
  '      :   # BL-311-MCP-NOTE-BLOCKS' \
  s3 'the note does not say every edit is blocked'
mut "M15 the check-is-off sentence dropped — killed by S4" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-NOTE-OFF' \
  '      :   # BL-311-MCP-NOTE-OFF' \
  s4 'the note does not say the check is off'
mut "M16 init.sh's container arm restored in the session layer — killed by E6" \
  scripts/lib/adopt/adopt-session.sh '# BL-311-SESSION-QDRANT-PREDICATE' \
  '    is_qdrant_mcp_entry_present && exit 0; is_qdrant_container_running && command -v uvx >/dev/null 2>&1 ) >/dev/null 2>&1   # BL-311-SESSION-QDRANT-PREDICATE' \
  e6 'a Qdrant declaration was written'
mut "M17 the restart sentence not printed — killed by E1b" \
  scripts/lib/adopt/adopt-state.sh '# BL-311-ACT2-RESTART-CALL' \
  '  :   # BL-311-ACT2-RESTART-CALL' \
  e1 "restart line at 'absent'"
mut "M18 the Record row dropped — killed by E1" \
  scripts/lib/adopt/adopt-record.sh '# BL-311-MCP-RECORD' \
  '    :   # BL-311-MCP-RECORD' \
  e1 "record row: ''"
mut "M19 the step not called — killed by E1" \
  scripts/lib/adopt/adopt-state.sh '# BL-311-MCP-CALL' \
  '  :   # BL-311-MCP-CALL' \
  e1 'not recorded'
mut "M20 the Docker probe keeps the operator's stdin — killed by E2" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DOCKER-STDIN' \
  '  run_with_deadline 5 docker info >/dev/null 2>&1   # BL-311-MCP-DOCKER-STDIN' \
  e2 "a command read the operator's answers"

_done
