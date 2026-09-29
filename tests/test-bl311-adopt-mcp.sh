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
#       is not registered against; S10 the touched-disk markers follow the
#       fingerprint, not the attempt; S11 the SOIF_ADOPT_MCP=off test seam
#       skips the whole step in one line, asks nothing and runs nothing;
#       S12/S13 answers by NUMBER — "1" is skip (nothing runs), "2" is set up;
#       S14 no npx — Context7 is not offered, and what to install is said;
#       S15 a failed `docker run` — Qdrant is NOT registered, and it is said;
#       S16 registered but Claude Code cannot START it (its own `claude mcp
#       get` check) — said as a block, with Claude Code's remove command;
#       S17 the same for CONTEXT7; S18 the launch check cannot answer (a hang
#       past the bound, and no status) — said, never read as either answer;
#       S19-S19g an EXISTING qdrant container published on every interface —
#       read ONCE for every path (unregistered, registered-but-stopped,
#       already answering, both present, 0.0.0.0, ::, Docker down) and said
#       before the question and beside every later `docker start` hint, never
#       recreated; S20 a loopback-bound one — no such note; S21-S23 where its
#       data lives — a host folder (named, reused), nothing mounted (removal
#       DELETES it: backup, no `docker rm`), an old volume name (read, reused);
#       S21b a hostile host path is shell-quoted (pasted, it executes nothing);
#       S22 the nothing-mounted note: the WHOLE printed note, first line to
#       last, compared exactly (no extra, missing or reordered line); S22r the
#       same for a container started with --rm (copy before the stop); S22p/
#       S22q its steps PASTED verbatim into bash and zsh (plain and -i) against
#       a stub docker: nothing runs past a refused mkdir or a failed ls, no
#       prose runs, no file lands in the cwd, a clean paste runs every step in
#       order (the zsh half skipped when zsh is absent); S22t both names
#       carry the time to the second on the real clock, and two runs a second
#       apart on one day (the SOIF_ADOPT_MCP_STAMP seam) get a different folder
#       AND a different volume;
#       S24a/b two mounts with /qdrant/snapshots FIRST; S25 inspect fails; S26
#       unparseable mounts; S27 an API key read from the container's env
#   E*  WHOLE ADOPTIONS: E1 both present — no question, the Record row, and
#       the restart sentence BEFORE "NEXT"; E2 set it up now — no command read
#       the operator's answers, and the project collection is declared; E3
#       skip — the Record row and the closing pointer; E4 no `claude` command
#       (the CI shape) — an answer sequence written without this step still
#       completes; E5 registered but silent — the adopted project's own gate
#       DOES block a Write (the S3 sentence is true); E6 the dogfood shape — a
#       registration in ~/.claude.json only, a database running, uvx present,
#       skip — nothing declared for the project and its own gate ALLOWS a Write;
#       E7 the dogfood answers, `1` to every question — the MCP question takes
#       its `1` as SKIP (it is listed first), nothing runs, adoption completes
#   A7  verify-install.sh's Qdrant row reads the files the session reads
#   A8  the Stop-hook Qdrant reminder reads the same files
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
# THIS SUITE EXERCISES THE REAL STEP, so the test seam every other adoption
# suite exports (`SOIF_ADOPT_MCP=off`) is cleared here — a developer who has it
# in their shell would otherwise run every case against a step that never ran.
# Only S11 sets it, explicitly, to pin the seam itself.
unset SOIF_ADOPT_MCP
# BL311_KEEP=1 keeps the fixtures for a post-mortem and prints where they are.
if [ "${BL311_KEEP:-0}" = "1" ]; then echo "  (fixtures kept in $WORK)"; else trap 'rm -rf "$WORK"' EXIT; fi

# ── the stubs ───────────────────────────────────────────────────────────────
# Each logs its argv, its cwd, and whether its stdin carried anything.
_mkstubs() {   # DIR [with-claude: yes|no] [npx: yes|no]
  local d="$1" with_claude="${2:-yes}" with_npx="${3:-yes}"
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
  # `docker inspect -f '{{json .HostConfig.PortBindings}}{{"\n"}}{{json .Mounts}}'`,
  # in the shape Docker 29.2.1 prints it (measured on this host's own container).
  # qdrant-open holds the HostIp ("" = none named, 0.0.0.0, ::); qdrant-mount is
  # volume:<name> | bind:<path> | none — default volume:qdrant_storage, this
  # host's real shape.
  inspect) [ -f "$st/qdrant-exists" ] || { echo "error: no such object: qdrant" >&2; exit 1; }
           [ -f "$st/inspect-fails" ] && { echo "error: stub inspect failure" >&2; exit 1; }
           hip='127.0.0.1'; [ -f "$st/qdrant-open" ] && hip="$(cat "$st/qdrant-open")"
           jq -cn --arg h "$hip" '{"6333/tcp":[{"HostIp":$h,"HostPort":"6333"}],"6334/tcp":[{"HostIp":$h,"HostPort":"6334"}]}'
           # qdrant-mount: one `type|source|destination` per line (none = empty
           # file); default this host's real shape. mounts-garbage: unparseable.
           if [ -f "$st/mounts-garbage" ]; then echo 'not json'
           else
             mf="$st/qdrant-mount"; [ -f "$mf" ] || { mf="$st/.default-mount"; printf 'volume|qdrant_storage|/qdrant/storage\n' > "$mf"; }
             arr='[]'
             while IFS='|' read -r mt ms md; do
               case "$mt" in
                 volume) arr="$(printf '%s' "$arr" | jq -c --arg n "$ms" --arg d "$md" '. + [{Type:"volume",Name:$n,Source:("/var/lib/docker/volumes/"+$n+"/_data"),Destination:$d,Driver:"local",Mode:"z",RW:true,Propagation:""}]')" ;;
                 bind)   arr="$(printf '%s' "$arr" | jq -c --arg s "$ms" --arg d "$md" '. + [{Type:"bind",Source:$s,Destination:$d,Mode:"",RW:true,Propagation:"rprivate"}]')" ;;
               esac
             done < "$mf"
             printf '%s\n' "$arr"
           fi
           # qdrant-env: one VAR=value per line; default: no API key.
           ef="$st/qdrant-env"; [ -f "$ef" ] || { ef="$st/.default-env"; printf 'PATH=/usr/local/sbin:/usr/local/bin\nRUN_MODE=production\n' > "$ef"; }
           jq -cR -s 'split("\n") | map(select(length > 0))' < "$ef"
           # qdrant-autoremove: the container was started with --rm.
           if [ -f "$st/qdrant-autoremove" ]; then echo true; else echo false; fi ;;
  run)   if [ -f "$st/docker-run-fails" ]; then echo "docker: Error response from daemon: stub refusal" >&2; exit 125; fi
         : > "$st/qdrant-exists"; [ -f "$st/docker-run-noop" ] || : > "$st/qdrant-up"; echo 0123abcd ;;
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
[ -n "${STUB_TOUCH:-}" ] && : > "$STUB_TOUCH"
# `claude mcp get NAME` — Claude Code's own health check, in the shape 2.1.283
# prints it (measured): a Status line, an Issue line when it failed, and the
# exact command to remove the registration.
if [ "${1:-}" = mcp ] && [ "${2:-}" = get ]; then
  n="${3:-}"
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then f="$CLAUDE_CONFIG_DIR/.claude.json"; else f="$HOME/.claude.json"; fi
  jq -e --arg n "$n" '.mcpServers[$n]' "$f" >/dev/null 2>&1 || { echo "No MCP server found with name: $n" >&2; exit 1; }
  if grep -qx "$n" "$st/launch-hang" 2>/dev/null; then sleep 5; exit 0; fi
  printf '%s:\n  Scope: User config (available in all your projects)\n' "$n"
  if grep -qx "$n" "$st/launch-silent" 2>/dev/null; then exit 0; fi
  if grep -qx "$n" "$st/launch-fails" 2>/dev/null; then
    printf '  Status: \342\234\230 Failed to connect\n  Issue: stub: %s cannot be started\n' "$n"
  else
    printf '  Status: \342\234\224 Connected\n'
  fi
  printf '\nTo remove this server, run: claude mcp remove %s -s user\n' "$n"
  exit 0
fi
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
  [ "$with_npx" = yes ] && printf '#!/bin/bash\nexit 0\n' > "$d/npx"
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
_step() {   # _step ANSWERS [ENV=VAL...]
  local ans="$1"; shift
  ( cd "$P" && printf "$ans" | env PATH="$RUN_PATH" HOME="$H" CLAUDE_CONFIG_DIR="$CFG" STUB_STATE="$ST" \
      SOIF_ADOPT_QDRANT_WAIT=2 "$@" bash "$WORK/harness.sh" "$FW" "$C/w" "$P" ) > "$C/out" 2>&1
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
QRUN='docker run -d --name qdrant -p 127.0.0.1:6333:6333 -p 127.0.0.1:6334:6334 -v qdrant_storage:/qdrant/storage --restart unless-stopped qdrant/qdrant:latest'
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

a7() {   # verify-install.sh's Qdrant row reads the files the session reads
  local bad="" out=""
  _case a7 >/dev/null
  mkdir -p "$C/p7"; ( cd "$C/p7" && git init -q . ) >/dev/null 2>&1
  printf '{}\n' > "$CFG/settings.json"
  _register "$CFG/.claude.json" qdrant
  out="$( cd "$C/p7" && env PATH="$RUN_PATH" HOME="$H" CLAUDE_CONFIG_DIR="$CFG" STUB_STATE="$ST" bash "$FW/scripts/verify-install.sh" --check-only </dev/null 2>&1 )"
  printf '%s\n' "$out" | grep -q '\[OK\] Qdrant MCP configured' || bad="$bad [registered in \$CLAUDE_CONFIG_DIR/.claude.json, not seen]"
  rm -f "$CFG/.claude.json"; _register "$H/.claude.json" qdrant
  out="$( cd "$C/p7" && env PATH="$RUN_PATH" HOME="$H" CLAUDE_CONFIG_DIR="$CFG" STUB_STATE="$ST" bash "$FW/scripts/verify-install.sh" --check-only </dev/null 2>&1 )"
  printf '%s\n' "$out" | grep -q 'Qdrant MCP not configured' || bad="$bad [registered only in ~/.claude.json, reported configured]"
  [ -z "$bad" ] && pass "A7 verify-install.sh's Qdrant row reads \$CLAUDE_CONFIG_DIR, not ~/.claude.json — the same files as its Context7 row" || fail_ "A7" "$bad"
}

a8() {   # the Stop-hook reminder reads the same files
  local bad="" out=""
  _case a8 >/dev/null
  mkdir -p "$C/p8"
  _register "$CFG/.claude.json" qdrant
  out="$( cd "$C/p8" && env HOME="$H" CLAUDE_CONFIG_DIR="$CFG" bash "$FW/scripts/session-end-qdrant-reminder.sh" </dev/null 2>&1 )"
  printf '%s' "$out" | grep -q 'QDRANT REMINDER' || bad="$bad [registered in \$CLAUDE_CONFIG_DIR, no reminder]"
  rm -f "$CFG/.claude.json"; _register "$H/.claude.json" qdrant
  out="$( cd "$C/p8" && env HOME="$H" CLAUDE_CONFIG_DIR="$CFG" bash "$FW/scripts/session-end-qdrant-reminder.sh" </dev/null 2>&1 )"
  printf '%s' "$out" | grep -q 'QDRANT REMINDER' && bad="$bad [registered only in ~/.claude.json, reminded anyway]"
  [ -z "$bad" ] && pass "A8 the session-end Qdrant reminder reads \$CLAUDE_CONFIG_DIR, not ~/.claude.json" || fail_ "A8" "$bad"
}

# ── S — the step on its own ─────────────────────────────────────────────────
s1() {   # nothing missing: no question, nothing run
  _case s1 >/dev/null
  _register "$CFG/.claude.json" qdrant; _register "$CFG/.claude.json" context7
  : > "$ST/qdrant-up"; : > "$ST/docker-up"
  _step "set it up now\n"
  if [ "$STEP_RC" = 0 ] && ! grep -q 'Set them up now' "$C/out" && ! _calls_ran \
     && [ "$STEP_RESULT" = "Qdrant: registered and answering before adoption, Claude Code starts it; Context7: registered before adoption, Claude Code starts it" ]; then
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
  [ "$STEP_RESULT" = "Qdrant: set up by adoption, registered and answering, Claude Code starts it; Context7: set up by adoption, registered, Claude Code starts it" ] || bad="$bad [result '$STEP_RESULT']"
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
  [ "$STEP_RESULT" = "Qdrant: registered, NOT answering (skipped), Claude Code starts it; Context7: NOT registered (skipped)" ] || bad="$bad [result '$STEP_RESULT']"
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

s10() {   # the touched-disk markers follow the evidence, not the attempt
  local bad=""
  _case s10a >/dev/null
  : > "$ST/docker-up"
  _step "set it up now\n"
  { [ -e "$C/w/touched" ] || [ -e "$C/w/touched-unbounded" ]; } && bad="$bad [markers raised over a tree the commands did not change]"
  _case s10b >/dev/null
  : > "$ST/docker-up"
  _step "set it up now\n" STUB_TOUCH="$P/left-behind.txt"
  [ -e "$P/left-behind.txt" ] || bad="$bad [the fixture's stray write did not happen]"
  { [ -e "$C/w/touched" ] && [ -e "$C/w/touched-unbounded" ]; } || bad="$bad [markers not raised when a command changed the tree]"
  [ -z "$bad" ] && pass "S10 the touched-disk markers follow the fingerprint: not raised when the commands left the project unchanged, both raised when one wrote into it" || fail_ "S10" "$bad"
}

s11() {   # the test seam: nothing checked, nothing asked, nothing run — and said
  local bad="" n=""
  _case s11 >/dev/null
  : > "$ST/docker-up"
  _step "set it up now\n" SOIF_ADOPT_MCP=off
  [ "$STEP_RC" = 0 ] || bad="$bad [rc $STEP_RC]"
  grep -q 'Set them up now' "$C/out" && bad="$bad [asked with the seam off]"
  { [ -s "$ST/calls.log" ] || [ -s "$ST/curl.log" ]; } && bad="$bad [probed or ran something with the seam off: $(cat "$ST/calls.log" "$ST/curl.log" | head -2 | tr '\n' '|')]"
  n="$(grep -c 'MCP server check skipped (SOIF_ADOPT_MCP=off).' "$C/out")"
  [ "$n" = 1 ] || bad="$bad [the one-line notice appeared $n time(s)]"
  [ "$STEP_RESULT" = "not checked (SOIF_ADOPT_MCP=off)" ] || bad="$bad [result '$STEP_RESULT']"
  [ -z "$bad" ] && pass "S11 SOIF_ADOPT_MCP=off skips the whole step: one line says so, nothing is probed, asked or run, and the Record cell says not checked" || fail_ "S11" "$bad"
}

s12() {   # answer "1" by NUMBER — "skip it" is listed first, so nothing runs
  local bad=""
  _case s12 >/dev/null
  : > "$ST/docker-up"
  _step "1\n"
  grep -q '   1) skip it' "$C/out" || bad="$bad [the menu does not list 1) skip it]"
  _calls_ran && bad="$bad [answer 1 ran commands: $(grep -E 'mcp|docker .(run|start)' "$ST/calls.log" | head -2 | tr '\n' '|')]"
  [ "$STEP_RESULT" = "Qdrant: NOT registered (skipped); Context7: NOT registered (skipped)" ] || bad="$bad [result '$STEP_RESULT']"
  [ -z "$bad" ] && pass "S12 answering 1 by number means skip it (listed first): nothing runs" || fail_ "S12" "$bad"
}

s13() {   # answer "2" by NUMBER — set it up
  local bad=""
  _case s13 >/dev/null
  : > "$ST/docker-up"
  _step "2\n"
  grep -q '   2) set it up now' "$C/out" || bad="$bad [the menu does not list 2) set it up now]"
  grep -q '\[mcp\] \[add\] \[context7\]' "$ST/calls.log" || bad="$bad [answer 2 did not set up Context7]"
  grep -q '\[mcp\] \[add\] \[-s\] \[user\] \[qdrant\]' "$ST/calls.log" || bad="$bad [answer 2 did not register Qdrant]"
  [ -z "$bad" ] && pass "S13 answering 2 by number sets them up: the commands run" || fail_ "S13" "$bad"
}

s14() {   # no npx: Context7 is not offered, and what to install is said
  local bad=""
  _case s14 >/dev/null
  _register "$CFG/.claude.json" qdrant
  : > "$ST/docker-up"; : > "$ST/qdrant-up"
  _mkstubs "$C/stubs" yes no
  _mirror_without "$C/mirror" npx
  if PATH="$C/stubs:$C/mirror" command -v npx >/dev/null 2>&1; then
    fail_ "S14" "the isolated PATH still has npx — the fixture cannot measure its absence"; return
  fi
  RUN_PATH="$C/stubs:$C/mirror" _step "2\n"
  grep -q 'Set them up now' "$C/out" && bad="$bad [offered Context7 with no npx to launch it]"
  grep -q '\[mcp\] \[add\] \[context7\]' "$ST/calls.log" && bad="$bad [registered Context7 with no npx]"
  grep -q 'Adoption cannot set up Context7 here: npx is not on PATH, and the server runs through it (npx comes with Node.js' "$C/out" || bad="$bad [the reason and what to install are not said]"
  grep -qF -- "  $C7ADD" "$C/out" || bad="$bad [no command for later]"
  [ -z "$bad" ] && pass "S14 no npx: Context7 is not offered (registering it would require a server that cannot start), and the run says Node.js is what provides npx" || fail_ "S14" "$bad"
}

s15() {   # docker run fails: Qdrant must NOT be registered, and it is said
  local bad=""
  _case s15 >/dev/null
  : > "$ST/docker-up"; : > "$ST/docker-run-fails"
  _step "2\n"
  grep -qF -- "$(_cmd_line docker "${QRUN#* }")" "$ST/calls.log" || bad="$bad [docker run was not attempted]"
  grep -q '\[mcp\] \[add\] \[-s\] \[user\] \[qdrant\]' "$ST/calls.log" && bad="$bad [Qdrant was registered after its container failed to start]"
  grep -q 'So Qdrant will NOT be registered: its database did not start' "$C/out" || bad="$bad [the run does not say Qdrant was not registered]"
  grep -q '\[mcp\] \[add\] \[context7\]' "$ST/calls.log" || bad="$bad [Context7, independent of it, was not set up]"
  [ "$STEP_RESULT" = "Qdrant: NOT registered after adoption tried; Context7: set up by adoption, registered, Claude Code starts it" ] || bad="$bad [result '$STEP_RESULT']"
  [ -z "$bad" ] && pass "S15 a failed docker run: Qdrant is NOT registered (registered would mean required, and every edit blocked), the run says so, and Context7 is still set up" || fail_ "S15" "$bad"
}

s16() {   # registered, but Claude Code cannot start it — Claude Code's own check
  local bad=""
  _case s16 >/dev/null
  : > "$ST/docker-up"; printf 'qdrant\n' > "$ST/launch-fails"
  _step "2\n"
  grep -q '\[mcp\] \[get\] \[qdrant\]' "$ST/calls.log" || bad="$bad [Claude Code's own check was not asked]"
  grep -q 'BLOCKED UNTIL FIXED: Qdrant IS registered, but Claude Code could NOT start it (stub: qdrant cannot be started)' "$C/out" || bad="$bad [the block is not said with Claude Code's reason]"
  grep -qxF '       claude mcp remove qdrant -s user' "$C/out" || bad="$bad [Claude Code's own remove command is not printed]"
  grep -q 'Qdrant: Claude Code.s own check says it could NOT start it' "$C/out" || bad="$bad [the launch line is missing]"
  case "$STEP_RESULT" in *"Qdrant: set up by adoption, registered and answering, Claude Code could NOT start it;"*) : ;; *) bad="$bad [result '$STEP_RESULT']" ;; esac
  [ -z "$bad" ] && pass "S16 registered and answering but Claude Code cannot start it: said as a BLOCK, with Claude Code's own reason and its remove command, and recorded" || fail_ "S16" "$bad"
}

s17() {   # Context7 registered, but Claude Code cannot start it
  local bad=""
  _case s17 >/dev/null
  _register "$CFG/.claude.json" qdrant; _register "$CFG/.claude.json" context7
  : > "$ST/docker-up"; : > "$ST/qdrant-up"; printf 'context7\n' > "$ST/launch-fails"
  _step ""
  grep -q 'BLOCKED UNTIL FIXED: Context7 IS registered, but Claude Code could NOT start it (stub: context7 cannot be started)' "$C/out" || bad="$bad [the Context7 block is not said]"
  grep -q 'Every file edit in this project is blocked until it can.' "$C/out" || bad="$bad [the consequence is not said]"
  grep -qxF '       claude mcp remove context7 -s user' "$C/out" || bad="$bad [Claude Code's own remove command is not printed]"
  case "$STEP_RESULT" in *"Context7: registered before adoption, Claude Code could NOT start it"*) : ;; *) bad="$bad [result '$STEP_RESULT']" ;; esac
  [ -z "$bad" ] && pass "S17 Context7 registered but Claude Code cannot start it: said as a BLOCK, with its reason and Claude Code's own remove command, and recorded" || fail_ "S17" "$bad"
}

s18() {   # the launch check cannot answer: a hang past the bound, and no status
  local bad=""
  _case s18 >/dev/null
  _register "$CFG/.claude.json" qdrant; _register "$CFG/.claude.json" context7
  : > "$ST/docker-up"; : > "$ST/qdrant-up"
  printf 'qdrant\n' > "$ST/launch-hang"; printf 'context7\n' > "$ST/launch-silent"
  _step "" SOIF_ADOPT_MCP_LAUNCH_SECS=1
  grep -q 'Whether Claude Code can start Qdrant could not be checked (claude mcp get qdrant did not answer within 1s)' "$C/out" || bad="$bad [the Qdrant unchecked note is not said]"
  grep -q 'file edit here is blocked until it can. Check it with: claude mcp get qdrant' "$C/out" || bad="$bad [the Qdrant consequence and check command are not said]"
  grep -q 'Whether Claude Code can start Context7 could not be checked (claude mcp get context7 gave no status' "$C/out" || bad="$bad [the Context7 unchecked note is not said]"
  grep -q 'Check it with: claude mcp get context7' "$C/out" || bad="$bad [the Context7 check command is not said]"
  grep -q 'BLOCKED UNTIL FIXED' "$C/out" && bad="$bad [a check that could not answer was read as a failure]"
  [ "$STEP_RESULT" = "Qdrant: registered and answering before adoption, whether Claude Code can start it not checked; Context7: registered before adoption, whether Claude Code can start it not checked" ] || bad="$bad [result '$STEP_RESULT']"
  [ -z "$bad" ] && pass "S18 a launch check that hangs past its bound or prints no status is said as 'could not be checked', with the command to check it — never read as starts or fails" || fail_ "S18" "$bad"
}

# ── S19-S23: an EXISTING qdrant container — how it is published, where its data is ──
# _open_case TAG HOSTIP MOUNT — a stopped container with those bindings and that
# mount, Docker up, nothing registered; the step is answered "skip it".
_open_case() {   # TAG HOSTIP MOUNT-LINE... (type|source|destination; none = no line)
  _case "$1" >/dev/null
  : > "$ST/docker-up"; : > "$ST/qdrant-exists"
  [ "$2" = loopback ] || printf '%s' "$2" > "$ST/qdrant-open"
  shift 2
  : > "$ST/qdrant-mount"
  while [ $# -gt 0 ]; do [ "$1" = none ] || printf '%s\n' "$1" >> "$ST/qdrant-mount"; shift; done
}
_open_note_before_q() {   # the note is printed, and before the question if there is one
  local ln="" lq=""
  ln="$(_line_of "$C/out" 'Your existing qdrant container')"
  [ -n "$ln" ] || return 1
  lq="$(_line_of "$C/out" 'Set them up now?')"
  [ -z "$lq" ] || [ "$ln" -lt "$lq" ]
}

s19() {   # unregistered + stopped + no host address + the host's real volume
  local bad=""
  _open_case s19 "" "volume|qdrant_storage|/qdrant/storage"
  _step "skip it\n"
  grep -q 'docker \[inspect\]' "$ST/calls.log" || bad="$bad [the container was not inspected]"
  _open_note_before_q || bad="$bad [the open-bindings note is not said before the question]"
  grep -q 'publishes on every network interface unless your Docker daemon sets a default' "$C/out" || bad="$bad [an empty HostIp is not worded as the daemon default]"
  grep -q 'can reach even ports published on 127.0.0.1 — moby/moby#45610' "$C/out" || bad="$bad [the pre-28.0.0 caveat is missing]"
  grep -q 'no API key is set in its environment (a key in a Qdrant config file would not show here)' "$C/out" || bad="$bad [the absence of an API key is not worded as read from its environment only]"
  grep -q 'Its data is in the Docker volume qdrant_storage, which removing the container keeps:' "$C/out" || bad="$bad [the volume is not named as keeping the data]"
  grep -qxF '     docker rm -f qdrant &&' "$C/out" || bad="$bad [the remove step is not printed chained to the run line with &&]"
  grep -qxF "     $QRUN" "$C/out" || bad="$bad [the loopback run command with that volume is not printed]"
  grep -qxF "     $QSTART" "$C/out" || bad="$bad [docker start is no longer the offered action]"
  grep -q 'your existing qdrant container is published on every network interface' "$C/out" || bad="$bad [the later docker start hint does not carry the note]"
  grep -q 'this machine only' "$C/out" && bad="$bad [the loopback promise is still worded as 'this machine only']"
  grep -q 'docker \[rm\]' "$ST/calls.log" && bad="$bad [the container was recreated automatically]"
  _calls_ran && bad="$bad [something ran on skip]"
  [ -z "$bad" ] && pass "S19 an existing container naming no host address: said (as the daemon default, with the pre-28 caveat) before the question, its volume named as keeping the data, docker start still offered, the later hint carries it, nothing recreated" || fail_ "S19" "$bad"
}

s19b() {   # REGISTERED + stopped + open: the unreachable path
  local bad=""
  _open_case s19b "" "volume|qdrant_storage|/qdrant/storage"
  _register "$CFG/.claude.json" qdrant; _register "$CFG/.claude.json" context7
  _step "skip it\n"
  _open_note_before_q || bad="$bad [the note is not said on the unreachable path]"
  grep -qxF "     $QSTART" "$C/out" || bad="$bad [docker start is not offered]"
  grep -q 'your existing qdrant container is published on every network interface' "$C/out" || bad="$bad [the unreachable arm's docker start hint does not carry the note]"
  [ -z "$bad" ] && pass "S19b registered + stopped + open: the note before the question and beside the unreachable arm's docker start hint" || fail_ "S19b" "$bad"
}

s19c() {   # unregistered, the database already ANSWERING from an open container
  local bad=""
  _open_case s19c "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/qdrant-up"
  _step "skip it\n"
  _open_note_before_q || bad="$bad [the note is not said when the database already answers]"
  [ -z "$bad" ] && pass "S19c the database already answering from an open container: the note is said" || fail_ "S19c" "$bad"
}

s19d() {   # THIS HOST'S STATE: both registered, answering, from an open container — nothing asked
  local bad=""
  _open_case s19d "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/qdrant-up"
  _register "$CFG/.claude.json" qdrant; _register "$CFG/.claude.json" context7
  _step ""
  grep -q 'Set them up now' "$C/out" && bad="$bad [asked with nothing missing]"
  _open_note_before_q || bad="$bad [the note is not said when everything is registered and answering]"
  [ -z "$bad" ] && pass "S19d both registered and answering from an open container (this host's state): no question, and the note is still said" || fail_ "S19d" "$bad"
}

s19e() {   # an explicit 0.0.0.0
  _open_case s19e "0.0.0.0" "volume|qdrant_storage|/qdrant/storage"
  _step "skip it\n"
  if _open_note_before_q && grep -q '(its bindings name 0.0.0.0)' "$C/out"; then
    pass "S19e HostIp 0.0.0.0: reported as published on every network interface"
  else fail_ "S19e" "[HostIp 0.0.0.0 not reported as every interface]"; fi
}

s19f() {   # an explicit ::
  _open_case s19f "::" "volume|qdrant_storage|/qdrant/storage"
  _step "skip it\n"
  if _open_note_before_q && grep -q 'every IPv6 address of this' "$C/out" && ! grep -q 'every network interface' "$C/out"; then
    pass "S19f HostIp :: reported as every IPv6 address — not as every interface"
  else fail_ "S19f" "[HostIp :: not reported as every interface]"; fi
}

s19g() {   # Docker DOWN: the bindings cannot be read, and every docker start hint says so
  local bad=""
  _case s19g >/dev/null
  _register "$CFG/.claude.json" qdrant
  _step "skip it\n"
  grep -qxF "     $QSTART" "$C/out" || bad="$bad [no docker start hint to check]"
  grep -q 'how an existing qdrant container is published could not be read — Docker is not running here' "$C/out" || bad="$bad [the docker start hint does not say the bindings could not be read]"
  [ -z "$bad" ] && pass "S19g Docker not running: the docker start hint says the container's bindings could not be read, and how to check them" || fail_ "S19g" "$bad"
}

s20() {   # a loopback-bound existing container: no note
  local bad=""
  _open_case s20 loopback "volume|qdrant_storage|/qdrant/storage"
  _step "skip it\n"
  grep -q 'docker \[inspect\]' "$ST/calls.log" || bad="$bad [the container's bindings were not read]"
  grep -q 'Your existing qdrant container' "$C/out" && bad="$bad [a loopback-bound container was reported as open]"
  [ -z "$bad" ] && pass "S20 an existing loopback-bound container: its bindings are read and no open-interfaces note is printed" || fail_ "S20" "$bad"
}

s21() {   # data in a HOST FOLDER: that folder is named, and reused in the run line
  local bad=""
  _open_case s21 "" "bind|/srv/qdrant data|/qdrant/storage"
  _step "skip it\n"
  grep -q 'Its data is in the host folder /srv/qdrant data, which removing the container keeps:' "$C/out" || bad="$bad [the host folder is not named]"
  grep -qF -- '-v /srv/qdrant\ data:/qdrant/storage' "$C/out" || bad="$bad [the run line does not reuse that folder, shell-quoted]"
  grep -qxF '     docker rm -f qdrant &&' "$C/out" || bad="$bad [the remove step is not printed chained to the run line with &&]"
  [ -z "$bad" ] && pass "S21 data in a host folder: the folder is named as keeping it and reused, shell-quoted, in the run line" || fail_ "S21" "$bad"
}

# _block OUT — the WHOLE printed note, from its first line ("Your existing
# qdrant container …") to its last ("Adoption does not do this for you."), the
# first time it is printed. Compared WHOLE: an extra, missing or reordered line
# anywhere in it — above the steps, a `#` note, the caveat — is a failure.
_block() {
  awk '/^   Your existing qdrant container/ { on = 1 }
       on { print }
       on && /^   Adoption does not do this for you\.$/ { exit }' "$1"
}
# _block_diff EXPECTED-FILE OUT — empty when the printed note matches EXACTLY;
# otherwise names the FIRST differing line, both sides (<none> past an end), so
# a mutant's kill says which line it broke.
_block_diff() {
  _block "$2" > "$1.got"
  cmp -s "$1" "$1.got" && return 0
  awk 'NR == FNR { e[FNR] = $0; ne = FNR; next }
       { g[FNR] = $0; ng = FNR }
       END { n = (ne > ng) ? ne : ng
             for (i = 1; i <= n; i++) {
               x = (i <= ne) ? e[i] : "<none>"; y = (i <= ng) ? g[i] : "<none>"
               if (x != y) { printf "the printed block differs at line %d: expected \"%s\", printed \"%s\"", i, x, y; exit } } }' "$1" "$1.got"
}
STAMP="20260929-101500"
# The note's first eight lines, the same for S22 and S22r (no host address, no key).
_note_head() {
  cat <<EOF
   Your existing qdrant container's ports name no host address, which Docker
   publishes on every network interface unless your Docker daemon sets a default
   bind address: while it runs, other machines on your network may be able to reach
   it — and no API key is set in its environment (a key in a Qdrant config file would not show here).
   Starting it keeps that. To publish it on 127.0.0.1 (loopback) instead, recreate it.
   Its data at /qdrant/storage is NOT on a Docker volume or a host folder: removing
   the container DELETES it. To move it safely, paste these lines whole — they stop
   at the first step that fails:
EOF
}
_note_tail() {
  cat <<EOF
   (On Docker Engine older than 28.0.0 on Linux, hosts on the same network segment
   can reach even ports published on 127.0.0.1 — moby/moby#45610.)
   Adoption does not do this for you.
EOF
}

s22() {   # NOTHING mounted at /qdrant/storage: the WHOLE printed note, exactly
  local bad="" bk="" vol="" miss=""
  _open_case s22 "" none
  _step "skip it\n" SOIF_ADOPT_MCP_STAMP="$STAMP"
  grep -q 'NOT on a Docker volume or a host folder: removing' "$C/out" || bad="$bad [the data loss is not said]"
  grep -q 'docker rm -f qdrant' "$C/out" && bad="$bad [a remove command was printed for a container whose data it would destroy]"
  bk="$H/qdrant-storage-backup-$STAMP"; vol="qdrant_storage_$STAMP"
  { _note_head; cat <<EOF
     # If the mkdir step says the folder exists, nothing after it ran. Never delete
     # that folder blindly: it may hold an earlier copy. Look inside it, then paste
     # these again with $bk-2 as the folder and $vol-2 as the volume.
     # The ls step stops everything if the copy has no collections folder. Look at
     # what it lists: those are the collections the new container will hold.
     mkdir $bk &&
     docker stop qdrant &&
     docker cp qdrant:/qdrant/storage/. $bk &&
     ls $bk/collections &&
     docker rename qdrant qdrant-old &&
     docker create --name qdrant -p 127.0.0.1:6333:6333 -p 127.0.0.1:6334:6334 -v $vol:/qdrant/storage --restart unless-stopped qdrant/qdrant:latest &&
     docker cp $bk/. qdrant:/qdrant/storage/ &&
     docker start qdrant
     # Only once the new container answers with your data: docker rm qdrant-old
EOF
  _note_tail; } > "$C/expect"
  miss="$(_block_diff "$C/expect" "$C/out")"
  [ -z "$miss" ] || bad="$bad [$miss]"
  [ -z "$bad" ] && pass "S22 nothing mounted at /qdrant/storage: the WHOLE printed note exactly, first line to last — DELETES said, every note a # line above or below ONE && chain (mkdir, stop, copy the contents, ls the collections, rename, create with the stamped volume, copy in, start), then remove the old one; no extra line, no docker rm -f" || fail_ "S22" "$bad"
}

s22r() {   # started with --rm: the WHOLE printed note, exactly — copy BEFORE the stop
  local bad="" bk="" vol="" miss=""
  _open_case s22r "" none; : > "$ST/qdrant-autoremove"
  _step "skip it\n" SOIF_ADOPT_MCP_STAMP="$STAMP"
  bk="$H/qdrant-storage-backup-$STAMP"; vol="qdrant_storage_$STAMP"
  { _note_head; cat <<EOF
     # It was started with --rm, so STOPPING it DELETES it: the copy is taken while
     # it runs, not at one point in time, so stop anything writing to it first.
     # The docker stop step removes it: from then on the copy is the only one.
     # If the mkdir step says the folder exists, nothing after it ran. Never delete
     # that folder blindly: it may hold an earlier copy. Look inside it, then paste
     # these again with $bk-2 as the folder and $vol-2 as the volume.
     # The ls step stops everything if the copy has no collections folder. Look at
     # what it lists: those are the collections the new container will hold.
     mkdir $bk &&
     docker cp qdrant:/qdrant/storage/. $bk &&
     ls $bk/collections &&
     docker stop qdrant &&
     docker create --name qdrant -p 127.0.0.1:6333:6333 -p 127.0.0.1:6334:6334 -v $vol:/qdrant/storage --restart unless-stopped qdrant/qdrant:latest &&
     docker cp $bk/. qdrant:/qdrant/storage/ &&
     docker start qdrant
     # Keep $bk until the new container answers with your data.
EOF
  _note_tail; } > "$C/expect"
  miss="$(_block_diff "$C/expect" "$C/out")"
  [ -z "$miss" ] || bad="$bad [$miss]"
  [ -z "$bad" ] && pass "S22r a container started with --rm: the WHOLE printed note exactly — the copy before the stop that deletes it, no rename, keep the backup" || fail_ "S22r" "$bad"
}

# ── Pasting the printed steps (R-439-8/9) ───────────────────────────────────
# The region an operator pastes: every line after "at the first step that
# fails:" up to the caveat. It is fed VERBATIM on stdin to each shell below,
# from an EMPTY cwd, with a stub `docker` first on PATH that logs each call —
# `mkdir` and `ls` are the real ones. `-i` is the case that matters on macOS:
# zsh's default leaves INTERACTIVE_COMMENTS off, so a `#` line is a command.
_paste_region() {
  awk '/at the first step that fails:$/ { on = 1; next }
       /^   \(On Docker Engine older than 28\.0\.0/ { on = 0 }
       on { print }' "$1"
}
_paste() {   # SHELL-WORDS REGION MODE(ok|nocoll) — leaves $C/paste/{log,cwd,stderr}
  local d="$C/paste"
  rm -rf "$d"; mkdir -p "$d/bin" "$d/cwd" "$d/home"
  cat > "$d/bin/docker" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$PASTE_LOG"
if [ "$1" = cp ] && [ "$2" = "qdrant:/qdrant/storage/." ]; then
  if [ "$PASTE_MODE" = nocoll ]; then mkdir -p "$3/other"; else mkdir -p "$3/collections/alpha"; fi
fi
exit 0
STUB
  chmod +x "$d/bin/docker"; : > "$d/log"
  # shellcheck disable=SC2086   # $1 is the shell and its flags, split on purpose
  ( cd "$d/cwd" && env -i PATH="$d/bin:/usr/bin:/bin" HOME="$d/home" HISTFILE= TERM=dumb \
      PASTE_LOG="$d/log" PASTE_MODE="$3" $1 < "$2" > "$d/stdout" 2> "$d/stderr" )
}
_paste_calls() { awk '{ printf "%s%s", (NR > 1 ? " " : ""), $1 }' "$C/paste/log"; }
# _paste_all BK OK-CALLS NOCOLL-CALLS — three pastes per shell: the backup
# folder already there (nothing may run), a copy with no collections (nothing
# after ls may run), and a clean run (every step, in order, nothing on stderr
# where the shell honours `#`). Never a file left in the cwd.
_paste_all() {
  local bk="$1" okc="$2" ncc="$3" sh="" got="" shells="$PASTE_SHELLS"
  _paste_region "$C/out" > "$C/region"
  [ -s "$C/region" ] || { printf ' [no paste region printed]'; return 0; }
  local IFS='|'
  for sh in $shells; do
    IFS=' '
    rm -rf "$bk"; mkdir -p "$bk"; _paste "$sh" "$C/region" ok
    got="$(_paste_calls)"; [ -z "$got" ] || printf ' [ran after the refused mkdir under %s: %s]' "$sh" "$got"
    [ -z "$(ls -A "$bk")" ] || printf ' [the refused backup folder was written to under %s]' "$sh"
    [ -z "$(ls -A "$C/paste/cwd")" ] || printf ' [left files in the cwd under %s: %s]' "$sh" "$(ls -A "$C/paste/cwd" | tr '\n' ' ')"
    rm -rf "$bk"; _paste "$sh" "$C/region" nocoll
    got="$(_paste_calls)"; [ "$got" = "$ncc" ] || printf ' [ran past the failed ls under %s: %s]' "$sh" "$got"
    [ -z "$(ls -A "$C/paste/cwd")" ] || printf ' [left files in the cwd under %s: %s]' "$sh" "$(ls -A "$C/paste/cwd" | tr '\n' ' ')"
    rm -rf "$bk"; _paste "$sh" "$C/region" ok
    got="$(_paste_calls)"; [ "$got" = "$okc" ] || printf ' [a clean paste under %s ran "%s", not "%s"]' "$sh" "$got" "$okc"
    [ -z "$(ls -A "$C/paste/cwd")" ] || printf ' [left files in the cwd under %s: %s]' "$sh" "$(ls -A "$C/paste/cwd" | tr '\n' ' ')"
    case "$sh" in *-i) ;; *) [ -s "$C/paste/stderr" ] && printf ' [the pasted steps wrote to stderr under %s: %s]' "$sh" "$(head -2 "$C/paste/stderr" | tr '\n' ' ' | cut -c1-160)" ;; esac
    IFS='|'
  done
  rm -rf "$bk"
}

PASTE_SHELLS="bash --norc|bash --norc -i"
command -v zsh >/dev/null 2>&1 && PASTE_SHELLS="$PASTE_SHELLS|zsh -f|zsh -f -i"
_zsh_or_skip() { command -v zsh >/dev/null 2>&1 || skip "$1 zsh half" "zsh is not installed"; }

s22p() {   # the printed steps, pasted whole, stop at the first failure and run no prose
  local bad=""
  _zsh_or_skip S22p
  _open_case s22p "" none
  _step "skip it\n" SOIF_ADOPT_MCP_STAMP="$STAMP"
  bad="$(_paste_all "$H/qdrant-storage-backup-$STAMP" "stop cp rename create cp start" "stop cp")"
  [ -z "$bad" ] && pass "S22p the printed steps pasted verbatim into bash and zsh, plain and -i: a refused mkdir runs nothing after it, a copy with no collections runs nothing after ls, a clean paste runs every step in order, no prose runs and no file lands in the cwd" || fail_ "S22p" "$bad"
}

s22q() {   # the same for a container started with --rm
  local bad=""
  _zsh_or_skip S22q
  _open_case s22q "" none; : > "$ST/qdrant-autoremove"
  _step "skip it\n" SOIF_ADOPT_MCP_STAMP="$STAMP"
  bad="$(_paste_all "$H/qdrant-storage-backup-$STAMP" "cp stop create cp start" "cp")"
  [ -z "$bad" ] && pass "S22q the --rm steps pasted verbatim into bash and zsh, plain and -i: nothing runs past a refused mkdir or a failed ls — so the stop that deletes the container never runs without a copy — and a clean paste runs every step in order" || fail_ "S22q" "$bad"
}

# The stamp each name carries in the printed block, or nothing.
_bk_stamp()  { sed -n "s#^     mkdir $H/qdrant-storage-backup-\([^ ]*\) &&\$#\1#p" "$C/out" | head -1; }
_vol_stamp() { sed -n 's#^     docker create .* -v qdrant_storage_\([^:]*\):/qdrant/storage .*#\1#p' "$C/out" | head -1; }

s22t() {   # both names carry the time to the second; two runs a second apart differ
  local bad="" b1="" v1="" b2="" v2="" br="" vr=""
  # Two runs ONE SECOND apart on ONE day, through the seam — R-439-6's same-day
  # re-run, without sleeping. Then one run on the real clock, for its format.
  _open_case s22t1 "" none; _step "skip it\n" SOIF_ADOPT_MCP_STAMP="20260929-101500"
  b1="$(_bk_stamp)"; v1="$(_vol_stamp)"
  _open_case s22t2 "" none; _step "skip it\n" SOIF_ADOPT_MCP_STAMP="20260929-101501"
  b2="$(_bk_stamp)"; v2="$(_vol_stamp)"
  _open_case s22t3 "" none; _step "skip it\n"
  br="$(_bk_stamp)"; vr="$(_vol_stamp)"
  { [ -n "$b1" ] && [ "$b1" != "$b2" ]; } || bad="$bad [the backup folder is named the same ('$b1' / '$b2') for two runs a second apart on one day]"
  { [ -n "$v1" ] && [ "$v1" != "$v2" ]; } || bad="$bad [the new volume is named the same ('$v1' / '$v2') for two runs a second apart on one day — docker create would silently reuse the earlier one]"
  printf '%s\n' "$br" | grep -qE '^[0-9]{8}-[0-9]{6}$' || bad="$bad [the backup name from the real clock ('$br') does not carry the time to the second]"
  [ "$vr" = "$br" ] || bad="$bad [the new volume ('$vr') is not stamped like the backup ('$br')]"
  [ -z "$bad" ] && pass "S22t the backup folder and the new volume carry YYYYMMDD-HHMMSS from the real clock, and two runs a second apart on one day get two different folders AND two different volumes" || fail_ "S22t" "$bad"
}

s23() {   # the OLD Addendum's volume name is read, not assumed
  local bad=""
  _open_case s23 "" "volume|qdrant_data|/qdrant/storage"
  _step "skip it\n"
  grep -q 'Its data is in the Docker volume qdrant_data, which removing the container keeps:' "$C/out" || bad="$bad [the real volume is not named]"
  grep -qF -- '-v qdrant_data:/qdrant/storage' "$C/out" || bad="$bad [the run line does not reuse that volume]"
  grep -q 'removing the container keeps:' "$C/out" && grep -A2 'removing the container keeps:' "$C/out" | grep -q 'qdrant_storage' && bad="$bad [the recreate step names qdrant_storage, a volume that holds none of this data]"
  [ -z "$bad" ] && pass "S23 a container on the old Addendum's qdrant_data volume: that volume is named and reused — never a hard-coded qdrant_storage" || fail_ "S23" "$bad"
}

s21b() {   # a host path carrying $, a backtick and a quote: the printed line is inert
  local bad="" line="" hostile=""
  hostile='/srv/a b$HOME`touch PWNED`"q'
  _open_case s21b "" "bind|$hostile|/qdrant/storage"
  _step "skip it\n"
  line="$(grep -F -- '     docker run -d --name qdrant' "$C/out" | grep -F 'PWNED' | head -1 | sed 's/^     //')"
  if [ -z "$line" ]; then fail_ "S21b" "[no run line carries the hostile path]"; return; fi
  mkdir -p "$C/argv" "$C/paste"
  printf '#!/bin/bash\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "%s/argv.out"\n' "$C" > "$C/argv/docker"; chmod +x "$C/argv/docker"
  ( cd "$C/paste" && PATH="$C/argv:$PATH" bash -c "$line" ) >/dev/null 2>&1
  [ -e "$C/paste/PWNED" ] && bad="$bad [pasting the line EXECUTED the backtick]"
  grep -qxF -- "$hostile:/qdrant/storage" "$C/argv.out" 2>/dev/null || bad="$bad [the pasted -v argument is not the literal path: $(tr '\n' '|' < "$C/argv.out" 2>/dev/null | cut -c1-200)]"
  [ -z "$bad" ] && pass "S21b a bind path with \$, a backtick and a quote: the printed docker run line, pasted into a shell, passes the literal path and executes nothing" || fail_ "S21b" "$bad"
}

s24a() {   # snapshots mounted FIRST, nothing at /qdrant/storage — data is NOT kept
  local bad=""
  _open_case s24a "" "volume|snaps|/qdrant/snapshots"
  _step "skip it\n"
  grep -q 'NOT on a Docker volume or a host folder: removing' "$C/out" || bad="$bad [the deletion warning is not said]"
  grep -q 'docker rm -f qdrant' "$C/out" && bad="$bad [docker rm -f printed although /qdrant/storage is not mounted]"
  grep -q 'Docker volume snaps' "$C/out" && bad="$bad [the snapshots volume was taken for the data]"
  [ -z "$bad" ] && pass "S24a /qdrant/snapshots mounted, /qdrant/storage not: the deletion warning and backup sequence, no docker rm -f" || fail_ "S24a" "$bad"
}

s24b() {   # snapshots mounted FIRST, a volume at /qdrant/storage second — that one named
  local bad=""
  _open_case s24b "" "volume|snaps|/qdrant/snapshots" "volume|qstore|/qdrant/storage"
  _step "skip it\n"
  grep -q 'Its data is in the Docker volume qstore, which removing the container keeps:' "$C/out" || bad="$bad [the /qdrant/storage volume is not the one named]"
  grep -qF -- '-v qstore:/qdrant/storage' "$C/out" || bad="$bad [the run line does not reuse qstore]"
  [ -z "$bad" ] && pass "S24b two mounts, snapshots first: the volume AT /qdrant/storage is the one named and reused" || fail_ "S24b" "$bad"
}

s25() {   # docker inspect fails for an existing container: fail closed, said
  local bad=""
  _open_case s25 "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/inspect-fails"
  _step "skip it\n"
  grep -q 'how an existing qdrant container is published could not be read — docker inspect could not read it' "$C/out" || bad="$bad [the could-not-be-read hint is missing]"
  grep -q 'Your existing qdrant container' "$C/out" && bad="$bad [a binding was claimed that was never read]"
  [ -z "$bad" ] && pass "S25 docker inspect fails: the bindings are 'could not be read' beside docker start — never treated as loopback" || fail_ "S25" "$bad"
}

s26() {   # the mounts line cannot be parsed: no data claim, no remove command
  local bad=""
  _open_case s26 "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/mounts-garbage"
  _step "skip it\n"
  grep -q 'Where it keeps its data could not be read, so no remove command is printed.' "$C/out" || bad="$bad [the data-unreadable line is missing]"
  grep -q 'docker rm' "$C/out" && bad="$bad [a remove command was printed with the data location unread]"
  [ -z "$bad" ] && pass "S26 an unparseable mounts line: 'could not be read', and no docker rm" || fail_ "S26" "$bad"
}

s27() {   # an API key IS set: said, never printed, and its absence not claimed
  local bad=""
  _open_case s27 "" "volume|qdrant_storage|/qdrant/storage"
  printf 'PATH=/usr/local/bin\nQDRANT__SERVICE__API_KEY=s3cr3t-value\n' > "$ST/qdrant-env"
  _step "skip it\n"
  grep -q 'it has an API key set (QDRANT__SERVICE__API_KEY)' "$C/out" || bad="$bad [the API key is not recognised]"
  grep -q 'no API key is set' "$C/out" && bad="$bad [no key claimed for a container that has one]"
  grep -q 's3cr3t-value' "$C/out" && bad="$bad [the key's value was printed]"
  [ -z "$bad" ] && pass "S27 a container with QDRANT__SERVICE__API_KEY: the key is recognised from its env, its value never printed" || fail_ "S27" "$bad"
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
  printf '%s' "$rec" | grep -q 'Qdrant: registered and answering before adoption, Claude Code starts it; Context7: registered before adoption, Claude Code starts it' || bad="$bad [record row: '$rec']"
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
  printf '%s' "$rec" | grep -q 'Qdrant: set up by adoption, registered and answering, Claude Code starts it; Context7: set up by adoption, registered, Claude Code starts it' || bad="$bad [record row: '$rec']"
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
  grep -q 'Adoption cannot set up Context7 here: the claude command is not on PATH' "$C/out" || bad="$bad [Context7 reason missing]"
  grep -q 'Adoption cannot set up Qdrant here: the claude command is not on PATH' "$C/out" || bad="$bad [Qdrant reason missing]"
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

e7() {   # THE DOGFOOD ANSWERS: 1 to every question. The MCP question takes its 1 as SKIP.
  local bad="" rec=""
  _case e7 >/dev/null
  : > "$ST/docker-up"
  _adopt "$(_n1 14)"
  [ "$RUN_RC" -eq 0 ] || bad="$bad [rc $RUN_RC: $(grep -E 'BLOCKED|REFUSED' "$C/out" | head -1)]"
  grep -q '   1) skip it' "$C/out" || bad="$bad [the MCP question does not list 1) skip it]"
  _calls_ran && bad="$bad [a 1 meant for another question registered servers: $(grep -E 'mcp|docker .(run|start)' "$ST/calls.log" | head -2 | tr '\n' '|')]"
  rec="$(_record)"
  printf '%s' "$rec" | grep -q 'Qdrant: NOT registered (skipped); Context7: NOT registered (skipped)' || bad="$bad [record row: '$rec']"
  [ -z "$bad" ] && pass "E7 the dogfood's answers (1 to every question): the MCP question's 1 is skip, nothing is registered, the adoption completes" || fail_ "E7" "$bad"
}

e_cases() {
  if [ "$HAVE_GITLEAKS" -ne 1 ]; then
    skip "E1-E6" "gitleaks is not on PATH — a personal adoption stops at the secrets check without it"
    return 0
  fi
  e1; e2; e3; e4; e5; e6; e7
}

if [ -n "${BL311_ONLY:-}" ]; then
  for _f in $BL311_ONLY; do "$_f"; done
  _done
fi
a1; a4; a5; a6; a7; a8
s1; s2; s3; s4; s5; s6; s7; s8; s9; s10; s11; s12; s13; s14; s15; s16; s17; s18
s19; s19b; s19c; s19d; s19e; s19f; s19g; s20; s21; s21b; s22; s22r; s22p; s22q; s22t; s23; s24a; s24b; s25; s26; s27
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

# THREE `</dev/null`s HAVE NO KILLING CASE ON THEIR OWN, AND THAT IS MEASURED:
# the setup commands (`# BL-311-MCP-RUN`), the registration probes
# (`# BL-311-MCP-PROBE-STDIN`) and the launch check (`# BL-311-MCP-LAUNCH-STDIN`)
# all run inside a `( … )` subshell, and inside the driver a backgrounded child
# of a subshell gets /dev/null regardless — dropping the redirection alone is an
# equivalent mutant (round 2: the launch one survived E2, a whole adoption with
# twelve answers still on the pipe and two `claude mcp get` calls, which
# asserts no stub read them). Dropping the subshell AS WELL is not equivalent:
# M39 does that to the launch check and E2 kills it, as M20 does for the bare
# Docker probe. The redirections stay because the consent rule asks for them.
if [ "${BL311_SKIP_MUTANTS:-0}" = "1" ]; then skip "M1-M84" "BL311_SKIP_MUTANTS=1"; _done; fi
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

mut "M21 the markers not raised when the tree changed — killed by S10" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-TOUCHED-ON-CHANGE' \
  '      :   # BL-311-MCP-TOUCHED-ON-CHANGE' \
  s10 'markers not raised when a command changed the tree'
mut "M22 the markers raised on the attempt, as the resolver does — killed by S10" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-TOUCHED-IF' \
  '    if true; then   # BL-311-MCP-TOUCHED-IF' \
  s10 'markers raised over a tree the commands did not change'
mut "M23 the test seam ignored — killed by S11" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-SEAM' \
  '  if false; then           # BL-311-MCP-SEAM' \
  s11 'asked with the seam off'
mut "M24 the resolver's order swapped (1 would mean set it up) — killed by S12" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-RESOLVE-ORDER' \
  '      ans="$(adopt_resolve_choice "$raw" "$ADOPT_MCP_SETUP" "$ADOPT_MCP_SKIP")"   # BL-311-MCP-RESOLVE-ORDER' \
  s12 'answer 1 ran commands'
mut "M25 the offer's order swapped (set it up listed first) — killed by E7" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-OFFER-ORDER' \
  '    adopt_offer_choice "Set them up now? (No answer means skip it.)" "$ADOPT_MCP_SETUP" "$ADOPT_MCP_SKIP"   # BL-311-MCP-OFFER-ORDER' \
  e7 'the MCP question does not list 1) skip it'
mut "M26 a failed docker run does not stop the Qdrant chain — killed by S15" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-FAIL-STOPS-QDRANT' \
  '        :   # BL-311-MCP-FAIL-STOPS-QDRANT' \
  s15 'Qdrant was registered after its container failed to start'
mut "M27 the npx precondition removed — killed by S14" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-NPX-PRECONDITION' \
  '    elif false; then c7_why=""   # BL-311-MCP-NPX-PRECONDITION' \
  s14 'offered Context7 with no npx to launch it'
mut "M28 a failed launch not recognised — killed by S16" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-LAUNCH-FAILED' \
  '  if false; then       # BL-311-MCP-LAUNCH-FAILED' \
  s16 'the block is not said'
mut "M29 the launch block not said — killed by S16" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-NOTE-LAUNCH' \
  '  if false; then   # BL-311-MCP-NOTE-LAUNCH' \
  s16 'the block is not said'
mut "M30 verify-install's Qdrant row back on fixed paths — killed by A7" \
  scripts/verify-install.sh '# BL-311-VERIFY-QDRANT' \
  '  if ([ -f "$HOME/.claude/settings.json" ] && jq -e ".mcpServers.qdrant // empty" "$HOME/.claude/settings.json" >/dev/null 2>&1) || ([ -f "$HOME/.claude.json" ] && jq -e ".mcpServers.qdrant // empty" "$HOME/.claude.json" >/dev/null 2>&1); then   # BL-311-VERIFY-QDRANT' \
  a7 'registered in $CLAUDE_CONFIG_DIR/.claude.json, not seen'
mut "M31 the reminder back on fixed paths — killed by A8" \
  scripts/session-end-qdrant-reminder.sh '# BL-311-REMINDER-CONFIG' \
  '  _cc_set="$HOME/.claude/settings.json"; _cc_json="$HOME/.claude.json"   # BL-311-REMINDER-CONFIG' \
  a8 'registered in $CLAUDE_CONFIG_DIR, no reminder'
mut "M34 Context7's launch-failed block not said — killed by S17" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-NOTE-LAUNCH-C7' \
  '  if false; then                                          # BL-311-MCP-NOTE-LAUNCH-C7' \
  s17 'the Context7 block is not said'
mut "M35 Qdrant's could-not-be-checked note not said — killed by S18" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-NOTE-UNCHECKED' \
  '  if false; then   # BL-311-MCP-NOTE-UNCHECKED' \
  s18 'the Qdrant unchecked note is not said'
mut "M36 Context7's could-not-be-checked note not said — killed by S18" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-NOTE-UNCHECKED-C7' \
  '  if false; then   # BL-311-MCP-NOTE-UNCHECKED-C7' \
  s18 'the Context7 unchecked note is not said'
mut "M37 the early return ignores the launch check — killed by S16" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-EARLY-RETURN' \
  '  if [ "$c7" = "registered" ] && [ "$q" = "reachable" ]; then   # BL-311-MCP-EARLY-RETURN' \
  s16 'the block is not said'
mut "M38 the Failed-to-connect match broken — killed by S16" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-LAUNCH-FAILED' \
  "  if grep -q 'Status:.*Failed to konnect' \"\$out\" 2>/dev/null; then       # BL-311-MCP-LAUNCH-FAILED" \
  s16 'the block is not said'
mut "M39 the launch check run bare (no subshell, no </dev/null) — killed by E2" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-LAUNCH-STDIN' \
  '  run_with_deadline "$secs" claude mcp get "$name" >"$out" 2>&1 || rc=$?   # BL-311-MCP-LAUNCH-STDIN' \
  e2 "a command read the operator's answers"
mut "M40 an empty HostIp never detected — killed by S19" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-OPEN-DETECT-DEFAULT' \
  '  elif false; then   # BL-311-MCP-OPEN-DETECT-DEFAULT' \
  s19 'the open-bindings note is not said before the question'
mut "M41 open bindings always reported — killed by S20" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-OPEN-DETECT' \
  '  if true; then   # BL-311-MCP-OPEN-DETECT' \
  s20 'a loopback-bound container was reported as open'
mut "M42 the open-bindings note not said — killed by S19" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-OPEN-SAY' \
  '  :   # BL-311-MCP-OPEN-SAY' \
  s19 'the open-bindings note is not said before the question'
mut "M43 the unregistered arm's docker start hint without the note — killed by S19" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-OPEN-HINT-UNREGISTERED' \
  '      :   # BL-311-MCP-OPEN-HINT-UNREGISTERED' \
  s19 'the later docker start hint does not carry the note'
mut "M44 (X1) 0.0.0.0 not detected — killed by S19e" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-OPEN-DETECT' \
  '  if false; then   # BL-311-MCP-OPEN-DETECT' \
  s19e 'HostIp 0.0.0.0 not reported'
mut "M45 (X2) :: not detected — killed by S19f" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-OPEN-DETECT-V6' \
  '  elif false; then   # BL-311-MCP-OPEN-DETECT-V6' \
  s19f 'HostIp :: not reported'
mut "M46 (X3/X4) the one hoisted read dropped — killed by S19c (the already-answering path)" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-HOIST' \
  '      if _adopt_mcp_qdrant_container; then q_ctr=1; fi   # BL-311-MCP-HOIST' \
  s19c 'the note is not said when the database already answers'
mut "M47 (R-15) the hoisted read dropped — killed by S19d (this host's state)" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-HOIST' \
  '      if _adopt_mcp_qdrant_container; then q_ctr=1; fi   # BL-311-MCP-HOIST' \
  s19d 'the note is not said when everything is registered and answering'
mut "M48 (X5) the unreachable arm's docker start hint without the note — killed by S19b" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-OPEN-HINT-UNREACHABLE' \
  '        :   # BL-311-MCP-OPEN-HINT-UNREACHABLE' \
  s19b "the unreachable arm's docker start hint does not carry the note"
mut "M49 (R-15) bindings that could not be read are not said — killed by S19g" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-UNREAD-HINT' \
  '      :   # BL-311-MCP-UNREAD-HINT' \
  s19g 'the docker start hint does not say the bindings could not be read'
mut "M50 (R-14) a volume or bind mount not recognised as keeping the data — killed by S19" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-KEPT' \
  '    no-such-type)                                                           # BL-311-MCP-DATA-KEPT' \
  s19 'the volume is not named as keeping the data'
mut "M51 (R-14) nothing mounted, assumed to be qdrant_storage — killed by S22" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-NONE' \
  '    *) ADOPT_MCP_QDRANT_DATA="volume"; ADOPT_MCP_QDRANT_SRC="qdrant_storage" ;;   # BL-311-MCP-DATA-NONE' \
  s22 'a remove command was printed for a container whose data it would destroy'
mut "M52 (R-14) the recreate step hard-codes qdrant_storage — killed by S23" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-VOLUME-RUN' \
  '      adopt_note "  $ADOPT_MCP_QDRANT_RUN" ;;   # BL-311-MCP-DATA-VOLUME-RUN' \
  s23 'the run line does not reuse that volume'
mut "M53 (R-16) an empty HostIp asserted as verified exposure — killed by S19" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DEFAULT-BIND-WORDING' \
  '      adopt_note "publishes on every network interface, so it IS reachable from your network"   # BL-311-MCP-DEFAULT-BIND-WORDING' \
  s19 'an empty HostIp is not worded as the daemon default'
mut "M54 (R-16) the pre-28.0.0 caveat dropped — killed by S19" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-MOBY-CAVEAT' \
  '  :   # BL-311-MCP-MOBY-CAVEAT' \
  s19 'the pre-28.0.0 caveat is missing'
mut "M55 (R-1/N1) any mount taken for /qdrant/storage — killed by S24a" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-SELECT' \
  "    sm=\"\$(printf '%s' \"\$m\" | jq -c '[.[] | select(true)] | first // empty' 2>/dev/null)\"   # BL-311-MCP-DATA-SELECT" \
  s24a 'docker rm -f printed although /qdrant/storage is not mounted'
mut "M56 (R-2/N2) a failed inspect defaults to loopback — killed by S25" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-INSPECT-FAILCLOSED' \
  '  ADOPT_MCP_QDRANT_BIND="loopback"; ADOPT_MCP_QDRANT_BIND_WHY=""   # BL-311-MCP-INSPECT-FAILCLOSED' \
  s25 'the could-not-be-read hint is missing'
mut "M57 (R-3/N3) unreadable data given docker rm -f — killed by S26" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-UNREAD' \
  '      adopt_note "  docker rm -f qdrant"   # BL-311-MCP-DATA-UNREAD' \
  s26 'the data-unreadable line is missing'
mut "M58 (R-4) the backup no longer stops the database first — killed by S22" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-STOP' \
  '        :   # BL-311-MCP-BACKUP-STOP' \
  s22 'at line 15: expected "     docker stop qdrant &&", printed "     docker cp qdrant:/qdrant/storage/. '
mut "M59 (R-4) the backup written into the current directory — killed by S22" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-PATH' \
  '      adopt_note "  docker cp qdrant:/qdrant/storage/. ./qdrant-storage-backup &&"   # BL-311-MCP-BACKUP-PATH' \
  s22 'printed "     docker cp qdrant:/qdrant/storage/. ./qdrant-storage-backup &&"'
mut "M60 (R-5) the path double-quoted instead of shell-quoted — killed by S21b" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-QUOTE' \
  "_adopt_mcp_q() { printf '\"%s\"' \"\$1\"; }   # BL-311-MCP-QUOTE" \
  s21b 'the pasted -v argument is not the literal path'
mut "M61 (R-6) an API key never detected — killed by S27" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-KEY-DETECT' \
  '    if false; then   # BL-311-MCP-KEY-DETECT' \
  s27 'the API key is not recognised'
mut "M62 (R-439-1/R7) docker create without the volume — killed by S22" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-CREATE' \
  '      adopt_note "  docker create --name qdrant -p 127.0.0.1:6333:6333 -p 127.0.0.1:6334:6334 --restart unless-stopped qdrant/qdrant:latest &&"   # BL-311-MCP-BACKUP-CREATE' \
  s22 'printed "     docker create --name qdrant -p 127.0.0.1:6333:6333 -p 127.0.0.1:6334:6334 --restart unless-stopped qdrant/qdrant:latest &&"'
mut "M63 (R-439-1/R6) the backup folder copied in, not its contents — killed by S22" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-COPYIN' \
  '      adopt_note "  docker cp $(_adopt_mcp_q "$bk") qdrant:/qdrant/storage/ &&"   # BL-311-MCP-BACKUP-COPYIN' \
  s22 "qdrant-storage-backup-$STAMP qdrant:/qdrant/storage/ &&\""
mut "M64 (R-439-3) no mkdir, so a re-run nests — killed by S22" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-MKDIR' \
  '      :   # BL-311-MCP-BACKUP-MKDIR' \
  s22 'at line 14: expected "     mkdir '
mut "M65 (R-439-3) copy-out takes the folder, not its contents — killed by S22" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-PATH' \
  '      adopt_note "  docker cp qdrant:/qdrant/storage $(_adopt_mcp_q "$bk") &&"   # BL-311-MCP-BACKUP-PATH' \
  s22 'printed "     docker cp qdrant:/qdrant/storage /'
mut "M66 (R-439-3) the check lists the backup's top level, not collections — killed by S22" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-LS' \
  '      adopt_note "  ls $(_adopt_mcp_q "$bk") &&"   # BL-311-MCP-BACKUP-LS' \
  s22 "qdrant-storage-backup-$STAMP/collections &&\", printed \"     ls "
mut "M67 (R-439-2) --rm never detected — killed by S22r" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-AUTOREMOVE-DETECT' \
  '  :   # BL-311-MCP-AUTOREMOVE-DETECT' \
  s22r 'at line 9: expected "     # It was started with --rm, so STOPPING it DELETES it: the copy is taken while", printed "     # If the mkdir step'
mut "M68 (R-439-4) the environment-only key reading worded as fact — killed by S19" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-KEY-WORDING' \
  '    unset) key="it has NO API key, so anything that reaches it can read your session memory" ;;   # BL-311-MCP-KEY-WORDING' \
  s19 'the absence of an API key is not worded as read from its environment only'
mut "M69 (MY-K) docker stop before the copy for a --rm container — killed by S22r" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-RM-NOTE' \
  '        adopt_note "  docker stop qdrant &&"; adopt_note "  # It was started with --rm, so STOPPING it DELETES it: the copy is taken while"   # BL-311-MCP-RM-NOTE' \
  s22r 'at line 9: expected "     # It was started with --rm, so STOPPING it DELETES it: the copy is taken while", printed "     docker stop qdrant &&"'
mut "M70 (MY-J) docker rm qdrant-old straight after the rename — killed by S22" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-RENAME' \
  '        adopt_note "  docker rename qdrant qdrant-old &&"; adopt_note "  docker rm qdrant-old &&"   # BL-311-MCP-BACKUP-RENAME' \
  s22 'qdrant/qdrant:latest &&", printed "     docker rm qdrant-old &&"'
mut "M71 (MY-D) the look-at-the-listing note dropped — killed by S22" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-GOON' \
  '      :   # BL-311-MCP-BACKUP-GOON' \
  s22 'at line 12: expected "     # The ls step stops everything if the copy has no collections folder. Look at", printed "     # what it lists'
mut "M72 (MY-B) the Keep line swapped for docker rm qdrant-old — killed by S22r" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-KEEP' \
  '        adopt_note "  docker rm qdrant-old"   # BL-311-MCP-BACKUP-KEEP' \
  s22r 'until the new container answers with your data.", printed "     docker rm qdrant-old"'
mut "M73 (R-439-6) a date-only stamp — killed by S22t" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-STAMP' \
  '      [ -n "$stamp" ] || stamp="$(date +%Y%m%d 2>/dev/null)"   # BL-311-MCP-BACKUP-STAMP' \
  s22t 'does not carry the time to the second'
mut "M74 (R-439-6) what to do when mkdir refuses dropped — killed by S22" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-MKDIR-REFUSED' \
  '      :   # BL-311-MCP-BACKUP-MKDIR-REFUSED' \
  s22 'at line 9: expected "     # If the mkdir step says the folder exists'
mut "M75 (R-439-6) a date-only backup folder name — killed by S22t" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-BK-NAME' \
  '      bk="$HOME/qdrant-storage-backup-${stamp%%-*}"   # BL-311-MCP-BACKUP-BK-NAME' \
  s22t 'the backup folder is named the same'
mut "M76 (R-439-6) a date-only volume name, the measured data mix-up — killed by S22t" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-VOL-NAME' \
  '      vol="qdrant_storage_${stamp%%-*}"   # BL-311-MCP-BACKUP-VOL-NAME' \
  s22t 'the new volume is named the same'
mut "M77 (R-439-7/MY-X1) the data loss above the steps worded away — killed by S22" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-NONE-SAY' \
  '      adopt_note "the container keeps it. To move it safely, paste these lines whole — they stop"   # BL-311-MCP-DATA-NONE-SAY' \
  s22 'at line 7: expected "   the container DELETES it.'
mut "M78 (R-439-7/MY-X2) a docker rm above the steps — killed by S22" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-NONE-HEAD' \
  '      adopt_note "  docker rm qdrant"; adopt_note "Its data at /qdrant/storage is NOT on a Docker volume or a host folder: removing"   # BL-311-MCP-DATA-NONE-HEAD' \
  s22 'at line 6: expected "   Its data at /qdrant/storage is NOT on a Docker volume or a host folder: removing", printed "     docker rm qdrant"'
mut "M79 (R-439-8) a note line without its # — killed by S22p" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-GOON' \
  '      adopt_note "  The ls step stops everything if the copy has no collections folder. Look at"   # BL-311-MCP-BACKUP-GOON' \
  s22p 'the pasted steps wrote to stderr under bash --norc'
mut "M80 (R-439-9) the mkdir link broken, so a refused mkdir runs on — killed by S22p" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-MKDIR' \
  '      adopt_note "  mkdir $(_adopt_mcp_q "$bk")"   # BL-311-MCP-BACKUP-MKDIR' \
  s22p 'ran after the refused mkdir under bash --norc'
mut "M81 (R-439-9) the ls link broken, so a copy with no collections runs on — killed by S22p" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-LS' \
  '      adopt_note "  ls $(_adopt_mcp_q "$bk/collections")"   # BL-311-MCP-BACKUP-LS' \
  s22p 'ran past the failed ls under bash --norc'
# A `#` line BETWEEN two links is harmless to bash and to zsh -f, and ENDS the
# chain in an interactive zsh (INTERACTIVE_COMMENTS off: `#` is a command) —
# so only the `zsh -f -i` paste can kill it, and it is skipped without zsh.
if command -v zsh >/dev/null 2>&1; then
mut "M82 (R-439-9) a # note between two links — killed by S22p under zsh -f -i" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-BACKUP-LS' \
  '      adopt_note "  ls $(_adopt_mcp_q "$bk/collections") &&"; adopt_note "  # look at what it lists"   # BL-311-MCP-BACKUP-LS' \
  s22p 'ran past the failed ls under zsh -f -i'
else skip "M82" "zsh is not installed — only an interactive zsh can kill it"; fi
mut "M83 (R-439-9) the volume branch's remove not chained to its run — killed by S19" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-VOLUME-RM' \
  '      adopt_note "  docker rm -f qdrant"   # BL-311-MCP-DATA-VOLUME-RM' \
  s19 'the remove step is not printed chained to the run line with &&'
mut "M84 (R-439-9) the host-folder branch's remove not chained to its run — killed by S21" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-BIND-RM' \
  '      adopt_note "  docker rm -f qdrant"   # BL-311-MCP-DATA-BIND-RM' \
  s21 'the remove step is not printed chained to the run line with &&'

_done
