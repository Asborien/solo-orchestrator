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
#       DELETES it: no command at all), an old volume name (read, reused);
#       S21b a hostile host path is shell-quoted (pasted, it executes nothing);
#       S22/S22b a volume / host folder the ALLOW-LIST confirmed: the WHOLE
#       note compared exactly, one && chain (no # or blank line between links,
#       no quote in a # line — checked with no shell at all), a # way back,
#       and the steps PASTED verbatim into bash and zsh (plain and -i; the zsh
#       half skipped when zsh is absent) against a stub docker: rm then run,
#       nothing after a failed rm, no error signature, no file in the cwd;
#       S22i a pinned image reproduced exactly, never latest; S22y every
#       unreadable or odd read (running state, an empty exec answer, volume
#       options, AutoRemove, Tmpfs, ramfs, a tmpfs device option, the image,
#       a re-pulled tag, --mount settings) refused — no command;
#       S22x every shape NOT confirmed (an API key or other QDRANT__ setting,
#       a volume subpath, a --mount elsewhere, storage split under
#       /qdrant/storage, and: nothing mounted, --rm with and without
#       a volume, a --tmpfs, a tmpfs in .Mounts, a tmpfs-backed volume,
#       unreadable volume options, two mounts, a running container whose own
#       /proc/mounts says tmpfs or cannot be read, a volume beside a tmpfs
#       key) says what was read and points to the written procedure, with NO
#       command line and no docker command in a sentence; S22o every uncleaned
#       spelling of a --tmpfs key (incl. three with `..`) and two keys; S22s a
#       volume at a SUB-path is not the data; S22v a trailing-slash
#       Destination (belt and braces: Docker cleans those);
#       S24a/b /qdrant/snapshots mounted FIRST — alone, then beside a volume at
#       /qdrant/storage (a second mount: refused); S25 inspect fails; S26
#       unparseable mounts; S27 an API key read from the container's env;
#       S28 the written procedure's command blocks pinned exactly (snapshots,
#       never a file copy)
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
                 tmpfs)  arr="$(printf '%s' "$arr" | jq -c --arg d "$md" '. + [{Type:"tmpfs",Source:"",Destination:$d,Mode:"",RW:true,Propagation:""}]')" ;;
               esac
             done < "$mf"
             printf '%s\n' "$arr"
           fi
           # qdrant-env: one VAR=value per line; default: no API key.
           ef="$st/qdrant-env"; [ -f "$ef" ] || { ef="$st/.default-env"; printf 'PATH=/usr/local/sbin:/usr/local/bin\nRUN_MODE=production\n' > "$ef"; }
           jq -cR -s 'split("\n") | map(select(length > 0))' < "$ef"
           # qdrant-autoremove: the container was started with --rm.
           # autoremove-garbage: an AutoRemove that is not true/false.
           if [ -f "$st/autoremove-garbage" ]; then echo '"maybe"'
           elif [ -f "$st/qdrant-autoremove" ]; then echo true; else echo false; fi
           # qdrant-tmpfs: started with --tmpfs /qdrant/storage — which real Docker
           # shows ONLY here, in .HostConfig.Tmpfs, never in .Mounts.
           # The file holds the keys, one per line, VERBATIM as Docker stores them
           # (real Docker: --tmpfs /tmp --tmpfs /qdrant/storage gives TWO keys).
           if [ -f "$st/tmpfs-garbage" ]; then echo '{bad'
           elif [ -f "$st/qdrant-tmpfs" ]; then
             if [ -s "$st/qdrant-tmpfs" ]; then jq -cR -s 'split("\n") | map(select(length > 0)) | map({(.): ""}) | add' < "$st/qdrant-tmpfs"
             else echo '{"/qdrant/storage":""}'; fi
           else echo null; fi
           # .State.Running: qdrant-up is the stub's running container.
           # running-garbage: a State.Running that is not true/false.
           if [ -f "$st/running-garbage" ]; then echo '"unknown"'
           elif [ -f "$st/qdrant-up" ]; then echo true; else echo false; fi
           # .Config.Image (qdrant-image, default the tag the Addendum used; image-garbage:
           # not a string), .Image (the ID it runs), .HostConfig.Mounts (qdrant-hcmounts,
           # default null: a -v mount leaves it empty).
           if [ -f "$st/image-garbage" ]; then echo null
           elif [ -f "$st/qdrant-image" ]; then jq -cn --arg i "$(cat "$st/qdrant-image")" '$i'
           else echo '"qdrant/qdrant:latest"'; fi
           echo '"sha256:1111"'
           if [ -f "$st/qdrant-hcmounts" ]; then cat "$st/qdrant-hcmounts"; else echo null; fi ;;
  # `docker image inspect -f '{{json .Id}}' REF`: the ID the tag names now —
  # the one the container runs, unless image-retagged (re-pulled since).
  image)  [ "${2:-}" = inspect ] || exit 0
          [ -f "$st/image-inspect-fails" ] && { echo "error: stub image inspect failure" >&2; exit 1; }
          if [ -f "$st/image-retagged" ]; then echo '"sha256:2222"'; else echo '"sha256:1111"'; fi ;;
  # `docker volume inspect -f '{{json .Options}}' NAME`: qdrant-volopts holds the
  # options (default null, a plain local volume); volume-inspect-fails fails it.
  volume) [ "${2:-}" = inspect ] || exit 0
          [ -f "$st/volume-inspect-fails" ] && { echo "error: stub volume inspect failure" >&2; exit 1; }
          if [ -f "$st/qdrant-volopts" ]; then cat "$st/qdrant-volopts"; else echo null; fi ;;
  # `docker exec qdrant awk ... /proc/mounts`: the fstype the RUNNING container's
  # own kernel shows at /qdrant/storage — qdrant-procfs, default ext4.
  exec)   [ -f "$st/exec-fails" ] && { echo "error: stub exec failure" >&2; exit 1; }
          if [ -f "$st/qdrant-procfs" ]; then cat "$st/qdrant-procfs"; else echo ext4; fi ;;
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
# The note's first five lines, the same for every case here (no host address, no key).
_note_pre() {
  cat <<EOF
   Your existing qdrant container's ports name no host address, which Docker
   publishes on every network interface unless your Docker daemon sets a default
   bind address: while it runs, other machines on your network may be able to reach
   it — and no API key is set in its environment (a key in a Qdrant config file would not show here).
   Starting it keeps that. To publish it on 127.0.0.1 (loopback) instead, recreate it.
EOF
}
_note_tail() {
  cat <<EOF
   (On Docker Engine older than 28.0.0 on Linux, hosts on the same network segment
   can reach even ports published on 127.0.0.1 — moby/moby#45610.)
   Adoption does not do this for you.
EOF
}
# _note_kept WHERE-LINE SRC — the whole note for a CONFIRMED volume or bind.
_note_kept() {
  _note_pre
  printf '%s\n' "$1" '     docker rm -f qdrant &&' \
    "     docker run -d --name qdrant -p 127.0.0.1:6333:6333 -p 127.0.0.1:6334:6334 -v $2:/qdrant/storage --restart unless-stopped qdrant/qdrant:latest" \
    '     # If docker run fails, the data is still where it was: fix what it reports,' \
    '     # then paste the docker run line again.'
  _note_tail
}

# ── Pasting the printed steps ───────────────────────────────────────────────
# Printed ONLY for a volume or bind the allow-list confirmed (round 11). The
# region an operator pastes: every line after "…which removing the container
# keeps:" up to the caveat. It is fed VERBATIM on stdin to each shell below,
# from an EMPTY cwd, with a stub `docker` first on PATH that logs each call.
# `-i` is the case that matters on macOS: zsh's default leaves
# INTERACTIVE_COMMENTS off, so a `#` line is a command — and a quote in one
# opens a string that swallows the next paste (round 11 measured `quote>`).
_paste_region() {
  awk '/which removing the container keeps:$/ { on = 1; next }
       /^   \(On Docker Engine older than 28\.0\.0/ { on = 0 }
       on { print }' "$1"
}
# _chain_shape OUT — the printed steps' SHAPE, with NO shell involved, so it
# holds on a host without zsh: the command lines are ONE contiguous run, each
# ending ` &&` but the last; no `#` or blank line sits between two links; and
# no `#` line carries a quote character. Prints the first breach.
_chain_shape() {
  _paste_region "$1" | awk -v sq="'" -v bq='`' '
    { c = ($0 ~ /^[[:space:]]*#/) ? "comment" : (($0 ~ /^[[:space:]]*$/) ? "blank" : "cmd") }
    c == "comment" && (index($0, sq) || index($0, "\"") || index($0, bq)) { printf " [a # note line carries a quote character: %s]", $0; bad = 1; exit }
    c == "cmd" && done { printf " [a command line after the chain ended — a link without &&: %s]", prev; bad = 1; exit }
    c != "cmd" && open { printf " [a %s line sits between two && links: %s]", c, $0; bad = 1; exit }
    c == "cmd" { n++; open = ($0 ~ /[[:space:]]&&$/); if (!open) done = 1; prev = $0 }
    END { if (bad) exit; if (!n) printf " [no command lines in the printed steps]"; else if (open) printf " [the last step ends in &&]" }'
}
_paste() {   # SHELL-WORDS REGION MODE(ok|rmfail) — leaves $C/paste/{log,cwd,stderr}
  local d="$C/paste"
  rm -rf "$d"; mkdir -p "$d/bin" "$d/cwd" "$d/home"
  cat > "$d/bin/docker" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$PASTE_LOG"
[ "$1" = rm ] && [ "$PASTE_MODE" = rmfail ] && exit 1
exit 0
STUB
  chmod +x "$d/bin/docker"; : > "$d/log"
  # shellcheck disable=SC2086   # $1 is the shell and its flags, split on purpose
  ( cd "$d/cwd" && env -i PATH="$d/bin:/usr/bin:/bin" HOME="$d/home" HISTFILE= TERM=dumb \
      PASTE_LOG="$d/log" PASTE_MODE="$3" $1 < "$2" > "$d/stdout" 2> "$d/stderr" )
}
_paste_calls() { awk '{ printf "%s%s", (NR > 1 ? " " : ""), $1 }' "$C/paste/log"; }
# An interactive shell writes prompts to stderr, so there only the ERROR
# signatures count; zsh's `command not found: #` for each `#` line is expected.
_paste_errors() {
  case "$1" in
    *-i) grep -E 'quote>|unmatched|parse error|syntax error|bad pattern|no matches found|event not found|command not found: [^#]|: command not found[[:space:]]*$' "$C/paste/stderr" | head -2 | tr '\n' ' ' | cut -c1-160 ;;
    *)   head -2 "$C/paste/stderr" | tr '\n' ' ' | cut -c1-160 ;;
  esac
}
# _paste_all OUT — two pastes per shell: a clean one (rm, then run, nothing on
# stderr but prompts) and one where `docker rm` fails (nothing after it). Never
# a file left in the cwd.
_paste_all() {
  local sh="" got="" err="" shells="$PASTE_SHELLS"
  _paste_region "$1" > "$C/region"
  [ -s "$C/region" ] || { printf ' [no paste region printed]'; return 0; }
  _chain_shape "$1"
  local IFS='|'
  for sh in $shells; do
    IFS=' '
    _paste "$sh" "$C/region" ok
    got="$(_paste_calls)"; [ "$got" = "rm run" ] || printf ' [a clean paste under %s ran "%s", not "rm run"]' "$sh" "$got"
    err="$(_paste_errors "$sh")"; [ -z "$err" ] || printf ' [the pasted steps printed an error under %s: %s]' "$sh" "$err"
    [ -z "$(ls -A "$C/paste/cwd")" ] || printf ' [left files in the cwd under %s: %s]' "$sh" "$(ls -A "$C/paste/cwd" | tr '\n' ' ')"
    _paste "$sh" "$C/region" rmfail
    got="$(_paste_calls)"; [ "$got" = "rm" ] || printf ' [ran past a failed docker rm under %s: %s]' "$sh" "$got"
    IFS='|'
  done
}

PASTE_SHELLS="bash --norc|bash --norc -i"
command -v zsh >/dev/null 2>&1 && PASTE_SHELLS="$PASTE_SHELLS|zsh -f|zsh -f -i"
_zsh_or_skip() { command -v zsh >/dev/null 2>&1 || skip "$1 zsh half" "zsh is not installed"; }
_shells_said() { printf '%s' "$PASTE_SHELLS" | sed 's/|/, /g'; }   # the shells that actually ran

s22() {   # a CONFIRMED volume: the whole note exactly, one && chain, the way back, pasted everywhere
  local bad="" miss=""
  _zsh_or_skip S22
  _open_case s22 "" "volume|qdrant_storage|/qdrant/storage"
  _step "skip it\n"
  _note_kept '   Its data is in the Docker volume qdrant_storage, which removing the container keeps:' qdrant_storage > "$C/expect"
  miss="$(_block_diff "$C/expect" "$C/out")"
  [ -z "$miss" ] || bad="$bad [$miss]"
  bad="$bad$(_paste_all "$C/out")"
  [ -z "$bad" ] && pass "S22 a volume the allow-list confirmed: the WHOLE note exactly — rm && run on loopback reusing the volume, then a # way back with no quote in it — one && chain, pasted verbatim into $(_shells_said): rm then run, nothing after a failed rm, no error, no file in the cwd" || fail_ "S22" "$bad"
}

s22b() {   # a CONFIRMED host folder: the same, reusing the folder
  local bad="" miss=""
  _zsh_or_skip S22b
  _open_case s22b "" "bind|/srv/qdrant-data|/qdrant/storage"
  _step "skip it\n"
  _note_kept '   Its data is in the host folder /srv/qdrant-data, which removing the container keeps:' /srv/qdrant-data > "$C/expect"
  miss="$(_block_diff "$C/expect" "$C/out")"
  [ -z "$miss" ] || bad="$bad [$miss]"
  bad="$bad$(_paste_all "$C/out")"
  [ -z "$bad" ] && pass "S22b a host folder the allow-list confirmed: the WHOLE note exactly, one && chain, pasted verbatim into $(_shells_said)" || fail_ "S22b" "$bad"
}

# _expect_no_steps LABEL WHY — on $C/out: the finding, the pointer, and NO
# command. The last two checks are SHAPE-INDEPENDENT: no indented line in the
# note that is not a `#` comment, and no docker command inside a sentence.
_expect_no_steps() {
  local label="$1" why="$2"
  _block "$C/out" > "$C/note"
  [ -s "$C/note" ] || { printf ' [%s: no note was printed]' "$label"; return 0; }
  grep -qF "What was read about where its data lives: $why" "$C/note" || printf ' [%s: the finding does not say "%s"]' "$label" "$why"
  grep -qF 'so NO commands are printed here' "$C/note" || printf ' [%s: it is not said that no command is printed]' "$label"
  grep -qF '"Recreating an exposed Qdrant container" in ' "$C/note" || printf ' [%s: the pointer to the written procedure is missing]' "$label"
  grep -qE '^     +[^ #]' "$C/note" && printf ' [%s: the note prints a command line: %s]' "$label" "$(grep -E '^     +[^ #]' "$C/note" | head -1 | cut -c1-100)"
  grep -qE 'docker (rm|run|stop|start|create|cp|exec|rename|volume|inspect|kill)( |$)' "$C/note" && printf ' [%s: the note names a docker command]' "$label"
  return 0
}

s22x() {   # every shape NOT shown to persist: the finding, the pointer, and NO command
  local bad=""
  _open_case s22x1 "" none; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'nothing mounted' 'nothing is mounted at /qdrant/storage, so its data is inside the container')"
  _open_case s22x2 "" none; : > "$ST/qdrant-autoremove"; _step "skip it\n"
  bad="$bad$(_expect_no_steps '--rm, nothing mounted' 'nothing is mounted at /qdrant/storage')"
  grep -qF 'It was also started with --rm, so stopping it DELETES the container.' "$C/out" || bad="$bad [--rm, nothing mounted: the --rm deletion is not said]"
  _open_case s22x3 "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/qdrant-autoremove"; _step "skip it\n"
  bad="$bad$(_expect_no_steps '--rm with a volume' 'it was started with --rm, so stopping it DELETES the container')"
  _open_case s22x4 "" none; : > "$ST/qdrant-tmpfs"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'a --tmpfs' '/qdrant/storage is a tmpfs, so its data is held in MEMORY')"
  _open_case s22x5 "" "tmpfs||/qdrant/storage"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'a tmpfs in .Mounts' '/qdrant/storage is a tmpfs, so its data is held in MEMORY')"
  _open_case s22x6 "" "volume|qtv|/qdrant/storage"; printf '{"device":"tmpfs","o":"","type":"tmpfs"}\n' > "$ST/qdrant-volopts"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'a tmpfs-backed volume' 'it is in the Docker volume qtv, which is backed by tmpfs')"
  _open_case s22x7 "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/volume-inspect-fails"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'volume options unread' 'the options of its Docker volume qdrant_storage could not be read')"
  _open_case s22x8 "" "volume|qa|/qdrant/storage" "bind|/srv/qb|/qdrant/storage/"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'two mounts at it' 'more than one mount claims /qdrant/storage')"
  _open_case s22x9 "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/qdrant-up"; printf 'tmpfs\n' > "$ST/qdrant-procfs"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'running, kernel says tmpfs' 'inside the running container, /qdrant/storage is a tmpfs')"
  _open_case s22x10 "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/qdrant-up"; : > "$ST/exec-fails"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'running, kernel unread' '/qdrant/storage could not be checked from inside the running container')"
  _open_case s22x11 "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/qdrant-tmpfs"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'a volume and a tmpfs key' 'a tmpfs is also mounted at /qdrant/storage')"
  # Round 12 — VANILLA ONLY: a recreate that would drop a setting or a mount is refused.
  _open_case s22x12 "" "volume|qdrant_storage|/qdrant/storage"; printf 'PATH=/usr/local/bin\nQDRANT__SERVICE__API_KEY=s3cr3t-value\n' > "$ST/qdrant-env"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'an API key' 'its environment sets QDRANT__ variables')"
  grep -qF 's3cr3t-value' "$C/out" && bad="$bad [the API key's VALUE was printed]"
  _open_case s22x13 "" "volume|qdrant_storage|/qdrant/storage"; printf 'PATH=/usr/local/bin\nQDRANT__LOG_LEVEL=DEBUG\n' > "$ST/qdrant-env"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'another QDRANT__ setting' 'its environment sets QDRANT__ variables')"
  _open_case s22x14 "" "volume|qdrant_storage|/qdrant/storage"; printf '[{"Type":"volume","Source":"qdrant_storage","Target":"/qdrant/storage","VolumeOptions":{"Subpath":"sub"}}]\n' > "$ST/qdrant-hcmounts"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'a volume subpath' 'its volume is mounted with a subpath')"
  _open_case s22x15 "" "volume|qdrant_storage|/qdrant/storage"; printf '[{"Type":"volume","Source":"qdrant_storage","Target":"/qdrant/storage"},{"Type":"bind","Source":"/srv/x","Target":"/data"}]\n' > "$ST/qdrant-hcmounts"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'a --mount elsewhere' 'its --mount settings name a path other than /qdrant/storage')"
  _open_case s22x16 "" none; printf '/qdrant/storage/collections\n' > "$ST/qdrant-tmpfs"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'a tmpfs under it' 'the storage is split across mounts: /qdrant/storage/collections is mounted under /qdrant/storage')"
  [ -z "$bad" ] && pass "S22x every shape not shown to persist — nothing mounted, --rm (with and without a volume), a --tmpfs, a tmpfs in .Mounts, a tmpfs-backed volume, unreadable volume options, two mounts at it, a running container whose kernel says tmpfs or cannot be asked, a volume beside a tmpfs key, an API key, another QDRANT__ setting, a volume subpath, a --mount elsewhere, a tmpfs under it — says what was read and points to the written procedure, with NO command line and no docker command in a sentence" || fail_ "S22x" "$bad"
}


s22i() {   # a PINNED image is reproduced exactly — never switched to latest
  local bad="" miss=""
  _open_case s22i "" "volume|qdrant_storage|/qdrant/storage"; printf 'qdrant/qdrant:v1.12.4' > "$ST/qdrant-image"
  _step "skip it\n"
  _note_pre > "$C/expect"
  printf '%s\n' '   Its data is in the Docker volume qdrant_storage, which removing the container keeps:' '     docker rm -f qdrant &&' \
    '     docker run -d --name qdrant -p 127.0.0.1:6333:6333 -p 127.0.0.1:6334:6334 -v qdrant_storage:/qdrant/storage --restart unless-stopped qdrant/qdrant:v1.12.4' \
    '     # If docker run fails, the data is still where it was: fix what it reports,' \
    '     # then paste the docker run line again.' >> "$C/expect"
  _note_tail >> "$C/expect"
  miss="$(_block_diff "$C/expect" "$C/out")"
  [ -z "$miss" ] || bad="$bad [$miss]"
  [ -z "$bad" ] && pass "S22i a container on qdrant/qdrant:v1.12.4: the recreate runs qdrant/qdrant:v1.12.4, exactly — the whole note compared" || fail_ "S22i" "$bad"
}

s22y() {   # every UNREADABLE or odd read fails the allow-list: no command
  local bad=""
  _open_case s22y1 "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/running-garbage"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'running state unread' 'whether it is running could not be read')"
  _open_case s22y2 "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/qdrant-up"; : > "$ST/qdrant-procfs"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'exec answers nothing' '/qdrant/storage could not be checked from inside the running container')"
  _open_case s22y3 "" "volume|qdrant_storage|/qdrant/storage"; printf 'not json\n' > "$ST/qdrant-volopts"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'volume options not JSON' 'the options of its Docker volume qdrant_storage could not be read')"
  _open_case s22y4 "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/autoremove-garbage"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'AutoRemove unread' 'whether it was started with --rm could not be read')"
  _open_case s22y5 "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/tmpfs-garbage"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'Tmpfs unparseable' 'its tmpfs mounts could not be read')"
  _open_case s22y6 "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/qdrant-up"; printf 'ramfs\n' > "$ST/qdrant-procfs"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'kernel says ramfs' 'inside the running container, /qdrant/storage is a ramfs')"
  _open_case s22y7 "" "volume|qdrant_storage|/qdrant/storage"; printf '{"device":"tmpfs","o":"size=64m","type":""}\n' > "$ST/qdrant-volopts"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'volume device tmpfs' 'it is in the Docker volume qdrant_storage, which is backed by tmpfs')"
  _open_case s22y8 "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/image-garbage"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'image unread' 'its image could not be read')"
  _open_case s22y9 "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/image-retagged"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'tag re-pulled' 'its image qdrant/qdrant:latest could not be shown to still name the image it runs')"
  _open_case s22y10 "" "volume|qdrant_storage|/qdrant/storage"; : > "$ST/image-inspect-fails"; _step "skip it\n"
  bad="$bad$(_expect_no_steps 'image inspect fails' 'its image qdrant/qdrant:latest could not be shown to still name the image it runs')"
  _open_case s22y11 "" "volume|qdrant_storage|/qdrant/storage"; printf '{bad\n' > "$ST/qdrant-hcmounts"; _step "skip it\n"
  bad="$bad$(_expect_no_steps '--mount settings unread' 'its --mount settings could not be read')"
  [ -z "$bad" ] && pass "S22y every unreadable or odd read — running state, an exec that answers nothing, volume options that are not JSON, AutoRemove, Tmpfs, a ramfs kernel view, a tmpfs device option, the image, a re-pulled tag, a failing image inspect, the --mount settings — fails the allow-list: no command" || fail_ "S22y" "$bad"
}

s22o() {   # a --tmpfs key is stored VERBATIM: every spelling of /qdrant/storage is a tmpfs
  local bad="" k=""
  # Each row is one container's Tmpfs keys, `|`-separated, as Docker keeps them
  # (round 11 measured `..` kept verbatim too). The last row is the real shape
  # of `--tmpfs /tmp --tmpfs /qdrant/storage`: two keys, the data one second.
  for k in /qdrant/storage/ /qdrant/storage// /qdrant//storage /qdrant/./storage /qdrant/x/../storage /../qdrant/storage /qdrant/storage/x/.. '/tmp|/qdrant/storage'; do
    _open_case "s22o$(printf '%s' "$k" | tr -c 'a-z' 'x')" "" none; printf '%s\n' "$k" | tr '|' '\n' > "$ST/qdrant-tmpfs"
    _step "skip it\n"
    grep -qF 'What was read about where its data lives: /qdrant/storage is a tmpfs' "$C/out" || bad="$bad [a tmpfs keyed '$k' is not read as a tmpfs]"
    bad="$bad$(_expect_no_steps "tmpfs $k" '/qdrant/storage is a tmpfs')"
  done
  [ -z "$bad" ] && pass "S22o a tmpfs keyed /qdrant/storage/, /qdrant/storage//, /qdrant//storage, /qdrant/./storage, /qdrant/x/../storage, /../qdrant/storage or /qdrant/storage/x/.. — Docker keeps --tmpfs verbatim — or listed second after /tmp, is read as a tmpfs: no command" || fail_ "S22o" "$bad"
}

s22s() {   # a volume at a SUB-path, or at a path that merely STARTS with /qdrant/storage: not the data
  local bad=""
  _open_case s22s "" "volume|r10snaps|/qdrant/storage/snapshots"
  _step "skip it\n"
  grep -q 'Docker volume r10snaps' "$C/out" && bad="$bad [a volume at /qdrant/storage/snapshots was taken for the data]"
  bad="$bad$(_expect_no_steps 'a sub-path volume only' 'the storage is split across mounts: /qdrant/storage/snapshots is mounted under /qdrant/storage')"
  # A sibling that shares the prefix is neither the data nor under it — the
  # case a prefix match gets wrong once split storage is its own class.
  _open_case s22s2 "" "volume|qold|/qdrant/storage-old"
  _step "skip it\n"
  grep -q 'Docker volume qold' "$C/out" && bad="$bad [a volume at /qdrant/storage-old was taken for the data]"
  bad="$bad$(_expect_no_steps 'a prefix sibling only' 'nothing is mounted at /qdrant/storage')"
  [ -z "$bad" ] && pass "S22s a volume at /qdrant/storage/snapshots (split storage) or at /qdrant/storage-old (a sibling), nothing at /qdrant/storage: neither taken for the data, no command" || fail_ "S22s" "$bad"
}

# BELT AND BRACES, KEPT DELIBERATELY: Docker cleans `-v`/`--mount` destinations,
# so a Destination of /qdrant/storage/ is a shape it never produces (round 10).
# It stays because the same clean() serves the Tmpfs keys, which Docker does
# NOT clean, and this is the only case that feeds the .Mounts side through it.
s22v() {   # a volume whose .Mounts Destination carries a trailing slash is still read
  local bad=""
  _open_case s22v "" "volume|qdrant_keep|/qdrant/storage/"
  _step "skip it\n"
  grep -q 'Its data is in the Docker volume qdrant_keep, which removing the container keeps:' "$C/out" || bad="$bad [a volume at /qdrant/storage/ is not read as keeping the data]"
  grep -q 'What was read about where its data lives' "$C/out" && bad="$bad [a volume at /qdrant/storage/ is refused a recreate]"
  [ -z "$bad" ] && pass "S22v a volume whose Destination is /qdrant/storage/ is read as the volume keeping the data" || fail_ "S22v" "$bad"
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
  bad="$bad$(_expect_no_steps 'snapshots only' 'nothing is mounted at /qdrant/storage')"
  grep -q 'docker rm -f qdrant' "$C/out" && bad="$bad [docker rm -f printed although /qdrant/storage is not mounted]"
  grep -q 'Docker volume snaps' "$C/out" && bad="$bad [the snapshots volume was taken for the data]"
  [ -z "$bad" ] && pass "S24a /qdrant/snapshots mounted, /qdrant/storage not: nothing mounted said, no command, no docker rm -f" || fail_ "S24a" "$bad"
}

s24b() {   # snapshots mounted FIRST, a volume at /qdrant/storage second: a second mount the recreate would drop
  local bad=""
  _open_case s24b "" "volume|snaps|/qdrant/snapshots" "volume|qstore|/qdrant/storage"
  _step "skip it\n"
  bad="$bad$(_expect_no_steps 'snapshots beside it' 'it has other mounts besides /qdrant/storage, which a recreate would drop')"
  [ -z "$bad" ] && pass "S24b two mounts, snapshots first: the recreate would drop one, so no command — the reason said" || fail_ "S24b" "$bad"
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
  bad="$bad$(_expect_no_steps 'mounts unreadable' 'where it keeps its data could not be read')"
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


# s28 — THE WRITTEN PROCEDURE IS PINNED (round 12): the pointer sends every
# unconfirmed shape to "Recreating an exposed Qdrant container" in
# docs/adoption.md, so its commands are compared EXACTLY, block by block, the
# way the printed note is — a doc edit cannot silently bring back a route that
# lost data. It is the snapshot route (Qdrant's own API, through the running
# server); the file-copy route is refused outright.
_doc_blocks() {
  awk '/^## Recreating an exposed Qdrant container$/ { on = 1; next } on && /^## / { exit }
       on && /^```sh$/ { inb = 1; print "--- block"; next } inb && /^```$/ { inb = 0; next } inb { print }' "$1"
}
s28() {
  local bad="" d="$REPO_ROOT/docs/adoption.md" sec=""
  cat > "$WORK/s28.expect" <<'DOCEOF'
--- block
Q=http://127.0.0.1:6333; S="$(date +%Y%m%d-%H%M%S)"; B="$HOME/qdrant-snapshots-$S"
mkdir "$B" &&
curl -sf "$Q/collections" > "$B/collections.json" &&
jq -r '.result.collections[].name' "$B/collections.json" > "$B/collections.txt" &&
while IFS= read -r c; do
  n="$(curl -sf -X POST "$Q/collections/$c/snapshots" | jq -r '.result.name // empty')" &&
  [ -n "$n" ] &&
  curl -sf "$Q/collections/$c/snapshots/$n" --output "$B/$c.snapshot" &&
  [ -s "$B/$c.snapshot" ] || { echo "SNAPSHOT FAILED: $c"; break; }
done < "$B/collections.txt"
--- block
m=0; while IFS= read -r c; do [ -s "$B/$c.snapshot" ] || { echo "MISSING: $c"; m=1; }; done < "$B/collections.txt"; [ "$m" = 0 ] && echo "ALL SNAPSHOTS PRESENT"
--- block
I="$(docker inspect -f '{{.Config.Image}}' qdrant)" &&
docker rename qdrant qdrant-old &&
docker stop qdrant-old &&
docker run -d --name qdrant -p 127.0.0.1:6333:6333 -p 127.0.0.1:6334:6334 -v "qdrant_storage_$S:/qdrant/storage" --restart unless-stopped "$I"
--- block
until curl -sf "$Q/collections" >/dev/null; do sleep 1; done &&
while IFS= read -r c; do
  curl -sf -X POST "$Q/collections/$c/snapshots/upload?priority=snapshot" -F "snapshot=@$B/$c.snapshot" >/dev/null || { echo "RESTORE FAILED: $c"; break; }
done < "$B/collections.txt"
--- block
curl -sf "$Q/collections" | jq -r '.result.collections[].name' | sort > "$B/restored.txt" &&
sort "$B/collections.txt" | diff - "$B/restored.txt" && echo "ALL COLLECTIONS RESTORED"
DOCEOF
  _doc_blocks "$d" > "$WORK/s28.got"
  sec="$(awk '/^## Recreating an exposed Qdrant container$/ { on = 1; next } on && /^## / { exit } on' "$d")"
  [ -n "$sec" ] || { fail_ "S28" "[the section \"Recreating an exposed Qdrant container\" is missing]"; return; }
  cmp -s "$WORK/s28.expect" "$WORK/s28.got" || bad="$bad [the procedure's commands changed: $(diff "$WORK/s28.expect" "$WORK/s28.got" | head -4 | tr '\n' '|' | cut -c1-240)]"
  printf '%s\n' "$sec" | grep -qE 'docker cp qdrant:|tar -C /qdrant/storage' && bad="$bad [a file-copy command is back in the procedure]"
  printf '%s\n' "$sec" | grep -qF 'snapshots/upload?priority=snapshot' || bad="$bad [the snapshot restore is not the route]"
  [ -z "$bad" ] && pass "S28 the written procedure's five command blocks match exactly — snapshot every collection, check each is non-empty, recreate with the same image, restore, check — and no file-copy command is in it" || fail_ "S28" "$bad"
}

if [ -n "${BL311_ONLY:-}" ]; then
  for _f in $BL311_ONLY; do "$_f"; done
  _done
fi
a1; a4; a5; a6; a7; a8
s1; s2; s3; s4; s5; s6; s7; s8; s9; s10; s11; s12; s13; s14; s15; s16; s17; s18
s19; s19b; s19c; s19d; s19e; s19f; s19g; s20; s21; s21b; s22; s22b; s22i; s22x; s22y; s22o; s22s; s22v; s23; s24a; s24b; s25; s26; s27; s28
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
  local label="$1" rel="$2" marker="$3" repl="$4" fn="$5" want="$6" m="" r="" p0="" f0="" s0="" why=""
  case "$fn" in e*) if [ "$HAVE_GITLEAKS" -ne 1 ]; then skip "$label" "its killing case needs gitleaks"; return; fi ;; esac
  m="$WORK/mut-$(printf '%s' "$marker" | tr -c 'A-Za-z0-9' '-')"
  _mirror_fw "$m" || { fail_ "$label" "could not mirror the framework"; return; }
  r="$(_mutate "$m/$rel" "$marker" "$repl")" || { fail_ "$label" "the mutation did not apply ($r)"; return; }
  p0=$PASSED; f0=$FAILED; s0=$SKIPPED
  FW="$m"; "$fn" > "$m.out" 2>&1; FW="$REPO_ROOT"
  # THE KILL MUST BE THE INTENDED ASSERTION. The first draft of this section
  # "killed" every adoption mutant with "this project has already been
  # adopted", because the cases reused their fixtures.
  why="$(grep '\[FAIL\]' "$m.out" | sed 's/^ *\[FAIL\] //' | tr '\n' ' ')"
  PASSED=$p0; SKIPPED=$s0   # the case's own passes and skips are not the mutant's
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
if [ "${BL311_SKIP_MUTANTS:-0}" = "1" ]; then skip "M1-M134" "BL311_SKIP_MUTANTS=1"; _done; fi
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
mut "M51 (R-14) nothing mounted, assumed to be qdrant_storage — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-NONE' \
  '    *) ADOPT_MCP_QDRANT_DATA="volume"; ADOPT_MCP_QDRANT_SRC="qdrant_storage" ;;   # BL-311-MCP-DATA-NONE' \
  s22x 'nothing mounted: the finding does not say'
mut "M52 (R-14) the recreate step hard-codes qdrant_storage — killed by S23" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-VOLUME-RUN' \
  '      adopt_note "  $ADOPT_MCP_QDRANT_RUN"   # BL-311-MCP-DATA-VOLUME-RUN' \
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
  '    *) why="where it keeps its data could not be read"; adopt_note "  docker rm -f qdrant" ;;   # BL-311-MCP-DATA-UNREAD' \
  s26 'a remove command was printed with the data location unread'
# M58-M59, M62-M66, M69-M82, M85-M86, M88, M90-M93 and M99-M102 pinned the
# recovery chains for nothing-mounted, --rm and tmpfs containers, and M73/M75/
# M76 their timestamped names. Round 11 removed those chains (the allow-list:
# see _adopt_mcp_confirm), so their markers and mutants are gone with them.
mut "M60 (R-5) the path double-quoted instead of shell-quoted — killed by S21b" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-QUOTE' \
  "_adopt_mcp_q() { printf '\"%s\"' \"\$1\"; }   # BL-311-MCP-QUOTE" \
  s21b 'the pasted -v argument is not the literal path'
mut "M61 (R-6) an API key never detected — killed by S27" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-KEY-DETECT' \
  '    if false; then   # BL-311-MCP-KEY-DETECT' \
  s27 'the API key is not recognised'
mut "M67 (R-439-2) --rm never detected — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-AUTOREMOVE-DETECT' \
  '  :   # BL-311-MCP-AUTOREMOVE-DETECT' \
  s22x '--rm with a volume: the finding does not say'
mut "M68 (R-439-4) the environment-only key reading worded as fact — killed by S19" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-KEY-WORDING' \
  '    unset) key="it has NO API key, so anything that reaches it can read your session memory" ;;   # BL-311-MCP-KEY-WORDING' \
  s19 'the absence of an API key is not worded as read from its environment only'
mut "M83 (R-439-9) the volume branch's remove not chained to its run — killed by S19" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-VOLUME-RM' \
  '      adopt_note "  docker rm -f qdrant"   # BL-311-MCP-DATA-VOLUME-RM' \
  s19 'the remove step is not printed chained to the run line with &&'
mut "M84 (R-439-9) the host-folder branch's remove not chained to its run — killed by S21" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-BIND-RM' \
  '      adopt_note "  docker rm -f qdrant"   # BL-311-MCP-DATA-BIND-RM' \
  s21 'the remove step is not printed chained to the run line with &&'
mut "M87 (R-439-11) a tmpfs in .HostConfig.Tmpfs never read — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-TMPFS-DETECT' \
  '      :   # BL-311-MCP-TMPFS-DETECT' \
  s22x 'a --tmpfs: the finding does not say'
mut "M89 (R-439-11) a tmpfs listed in .Mounts classed as nothing mounted — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-TMPFS-MOUNT' \
  '      tmpfs) ADOPT_MCP_QDRANT_DATA="none" ;;   # BL-311-MCP-TMPFS-MOUNT' \
  s22x 'a tmpfs in .Mounts: the finding does not say'
mut "M94 (R-439-14) a tmpfs key matched exactly, so /qdrant/storage/ is nothing mounted — killed by S22o" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-TMPFS-KEY' \
  "    if [ \"\$ADOPT_MCP_QDRANT_DATA\" = \"none\" ] && printf '%s' \"\$f\" | jq -e 'type == \"object\" and has(\"/qdrant/storage\")' >/dev/null 2>&1; then   # BL-311-MCP-TMPFS-KEY" \
  s22o "a tmpfs keyed '/qdrant/storage/' is not read as a tmpfs"
mut "M95 (R-439-14) a mount Destination matched exactly — killed by S22v (belt and braces)" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-SELECT' \
  "    sm=\"\$(printf '%s' \"\$m\" | jq -c '[.[] | select(.Destination == \"/qdrant/storage\")] | first // empty' 2>/dev/null)\"   # BL-311-MCP-DATA-SELECT" \
  s22v 'a volume at /qdrant/storage/ is not read as keeping the data'
mut "M96 (R-439-16) any Tmpfs key → all of them, so /tmp beside it hides the data — killed by S22o" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-TMPFS-KEY' \
  "    if [ \"\$ADOPT_MCP_QDRANT_DATA\" = \"none\" ] && printf '%s' \"\$f\" | jq -e \"\$_ADOPT_MCP_JQ_CLEAN\"' type == \"object\" and (keys | all(clean == \"/qdrant/storage\"))' >/dev/null 2>&1; then   # BL-311-MCP-TMPFS-KEY" \
  s22o "a tmpfs keyed '/tmp|/qdrant/storage' is not read as a tmpfs"
mut "M97 (R-439-18) Tmpfs keys matched by pattern, not cleaned — killed by S22o" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-TMPFS-KEY' \
  "    if [ \"\$ADOPT_MCP_QDRANT_DATA\" = \"none\" ] && printf '%s' \"\$f\" | jq -e 'type == \"object\" and (keys | any(test(\"^/qdrant/storage/*\$\")))' >/dev/null 2>&1; then   # BL-311-MCP-TMPFS-KEY" \
  s22o "a tmpfs keyed '/qdrant//storage' is not read as a tmpfs"
mut "M98 (R-439-17) a Destination matched by prefix, so a sibling volume is the data — killed by S22s" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-SELECT' \
  "    sm=\"\$(printf '%s' \"\$m\" | jq -c '[.[] | select((.Destination // \"\") | test(\"^/qdrant/storage\"))] | first // empty' 2>/dev/null)\"   # BL-311-MCP-DATA-SELECT" \
  s22s 'a volume at /qdrant/storage-old was taken for the data'
# ── round 11: `..` in a Tmpfs key (MX1-MX3, the reviewer's survivors) ───────
mut "M103 (R-439-21/MX1) \`..\` dropped instead of resolved — killed by S22o" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-PATH-CLEAN' \
  "_ADOPT_MCP_JQ_CLEAN='def clean: \"/\" + (reduce (split(\"/\")[] | select(. != \"\" and . != \".\")) as \$s ([]; if \$s == \"..\" then . else . + [\$s] end) | join(\"/\"));'   # BL-311-MCP-PATH-CLEAN" \
  s22o "a tmpfs keyed '/qdrant/x/../storage' is not read as a tmpfs"
mut "M104 (R-439-21/MX2) \`..\` kept as a segment — killed by S22o" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-PATH-CLEAN' \
  "_ADOPT_MCP_JQ_CLEAN='def clean: \"/\" + (reduce (split(\"/\")[] | select(. != \"\" and . != \".\")) as \$s ([]; . + [\$s]) | join(\"/\"));'   # BL-311-MCP-PATH-CLEAN" \
  s22o "a tmpfs keyed '/qdrant/x/../storage' is not read as a tmpfs"
mut "M105 (R-439-21/MX3) \`..\` pops the wrong end — killed by S22o" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-PATH-CLEAN' \
  "_ADOPT_MCP_JQ_CLEAN='def clean: \"/\" + (reduce (split(\"/\")[] | select(. != \"\" and . != \".\")) as \$s ([]; if \$s == \"..\" then .[1:] else . + [\$s] end) | join(\"/\"));'   # BL-311-MCP-PATH-CLEAN" \
  s22o "a tmpfs keyed '/qdrant/x/../storage' is not read as a tmpfs"
# ── round 11: the allow-list, one mutant per check ─────────────────────────
mut "M106 (R-439-22) a tmpfs-backed volume taken for a plain one — the measured data loss — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-VOLUME-TMPFS' \
  '    if false; then   # BL-311-MCP-CONFIRM-VOLUME-TMPFS' \
  s22x 'a tmpfs-backed volume: the note prints a command line'
mut "M107 (allow-list) --rm not checked — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-AUTORM' \
  '  case "false" in   # BL-311-MCP-CONFIRM-AUTORM' \
  s22x '--rm with a volume: the note prints a command line'
mut "M108 (allow-list) a tmpfs key beside the volume not checked — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-TMPFS-KEY' \
  '  if false; then   # BL-311-MCP-CONFIRM-TMPFS-KEY' \
  s22x 'a volume and a tmpfs key: the note prints a command line'
mut "M109 (allow-list) the running container's own view never asked — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-KERNEL' \
  '      if false; then   # BL-311-MCP-CONFIRM-KERNEL' \
  s22x 'running, kernel says tmpfs: the note prints a command line'
mut "M110 (allow-list) the kernel saying tmpfs not believed — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-KERNEL-TMPFS' \
  '        never-a-fstype) _adopt_mcp_unconfirmed "x"; return 0 ;;   # BL-311-MCP-CONFIRM-KERNEL-TMPFS' \
  s22x 'running, kernel says tmpfs: the note prints a command line'
mut "M111 (allow-list) two mounts at /qdrant/storage guessed between — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-MULTI' \
  '    :   # BL-311-MCP-DATA-MULTI' \
  s22x 'two mounts at it: the finding does not say'
mut "M112 (allow-list) an unconfirmed shape given a command anyway — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-NO-STEPS' \
  '  adopt_note "  docker stop qdrant"; adopt_note "That is not shown to outlive the container, so NO commands are printed here: one"   # BL-311-MCP-NO-STEPS' \
  s22x 'nothing mounted: the note prints a command line'
mut "M113 (allow-list) the no-command statement and pointer dropped — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-NO-STEPS' \
  '  :   # BL-311-MCP-NO-STEPS' \
  s22x 'nothing mounted: it is not said that no command is printed'
mut "M114 (allow-list) a docker command inside a sentence — killed by S26" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-UNREAD' \
  '    *)           why="where it keeps its data could not be read, so check it with docker inspect qdrant" ;;   # BL-311-MCP-DATA-UNREAD' \
  s26 'mounts unreadable: the note names a docker command'
# ── round 11: the way back under a confirmed recreate (R-439-23) ────────────
mut "M115 (R-439-23) the way back dropped — killed by S22" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-RECOVER-KEPT' \
  '  :   # BL-311-MCP-RECOVER-KEPT' \
  s22 'at line 9: expected "     # If docker run fails'
mut "M116 (R-439-23) a quote in a # note — killed by S22's shape check, no shell needed" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-RECOVER-KEPT' \
  "  adopt_note \"  # If docker run fails, the container's data is still where it was: fix it,\"   # BL-311-MCP-RECOVER-KEPT" \
  s22 'a # note line carries a quote character'
mut "M117 (R-439-9) a # note between the two links — killed by S22's shape check" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-VOLUME-RM' \
  '      adopt_note "  docker rm -f qdrant &&"; adopt_note "  # then the run line"   # BL-311-MCP-DATA-VOLUME-RM' \
  s22 'a comment line sits between two && links'
# The same quote, killed by what an interactive zsh DOES with it (`quote>`) —
# only where zsh is installed.
if command -v zsh >/dev/null 2>&1; then
mut "M118 (R-439-23) a quote in a # note — killed by S22's zsh -f -i paste" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-RECOVER-KEPT' \
  "  adopt_note \"  # If docker run fails, the container's data is still where it was: fix it,\"   # BL-311-MCP-RECOVER-KEPT" \
  s22 'the pasted steps printed an error under zsh -f -i'
else skip "M118" "zsh is not installed — only an interactive zsh can kill it"; fi

# ── round 12: VANILLA ONLY (R-1), --mount settings (R-2), split storage (R-3),
#    and every unread arm (R-4) ────────────────────────────────────────────
mut "M119 (R-1) a QDRANT__ environment accepted — the API key dropped on recreate — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-ENV' \
  '  if false; then   # BL-311-MCP-CONFIRM-ENV' \
  s22x 'an API key: the note prints a command line'
mut "M120 (R-1) a second mount accepted — dropped on recreate — killed by S24b" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-ONE-MOUNT' \
  '  if false; then   # BL-311-MCP-CONFIRM-ONE-MOUNT' \
  s24b 'snapshots beside it: the note prints a command line'
mut "M121 (R-1) the recreate switched to qdrant/qdrant:latest — killed by S22i" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-RUN-IMAGE' \
  "  printf 'docker run -d --name qdrant -p 127.0.0.1:6333:6333 -p 127.0.0.1:6334:6334 -v %s --restart unless-stopped qdrant/qdrant:latest' \"\$(_adopt_mcp_q \"\$1:/qdrant/storage\")\"   # BL-311-MCP-RUN-IMAGE" \
  s22i 'qdrant/qdrant:v1.12.4", printed "'
mut "M122 (R-2) a volume subpath accepted — the recreate served an empty store — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-SUBPATH' \
  '  if false; then   # BL-311-MCP-CONFIRM-SUBPATH' \
  s22x 'a volume subpath: the note prints a command line'
mut "M123 (R-2) unreadable --mount settings accepted — killed by S22y" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-HCMOUNTS' \
  '  if false; then   # BL-311-MCP-CONFIRM-HCMOUNTS' \
  s22y '--mount settings unread: the note prints a command line'
mut "M124 (R-2) a --mount elsewhere accepted — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-HCMOUNTS-ELSEWHERE' \
  '  if false; then   # BL-311-MCP-CONFIRM-HCMOUNTS-ELSEWHERE' \
  s22x 'a --mount elsewhere: the note prints a command line'
mut "M125 (R-3) storage split under /qdrant/storage called nothing mounted — killed by S22x" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-DATA-SPLIT' \
  '  :   # BL-311-MCP-DATA-SPLIT' \
  s22x 'a tmpfs under it: the finding does not say'
mut "M126 (R-4/X1) an unread running state accepted — killed by S22y" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-RUNNING-UNREAD' \
  '    *) ;;   # BL-311-MCP-CONFIRM-RUNNING-UNREAD' \
  s22y 'running state unread: the note prints a command line'
mut "M127 (R-4/X2) an exec that answers nothing accepted — killed by S22y" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-KERNEL-EMPTY' \
  '        "") ;;   # BL-311-MCP-CONFIRM-KERNEL-EMPTY' \
  s22y 'exec answers nothing: the note prints a command line'
mut "M128 (R-4/X5) volume options that are not JSON accepted — killed by S22y" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-VOLUME-READ' \
  '    if false; then   # BL-311-MCP-CONFIRM-VOLUME-READ' \
  s22y 'volume options not JSON: the note prints a command line'
mut "M129 (R-4) an unread AutoRemove accepted — killed by S22y" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-AUTORM-UNREAD' \
  '    *) ;;   # BL-311-MCP-CONFIRM-AUTORM-UNREAD' \
  s22y 'AutoRemove unread: the note prints a command line'
mut "M130 (R-4) unparseable tmpfs mounts accepted — killed by S22y" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-TMPFS-READ' \
  '  if false; then   # BL-311-MCP-CONFIRM-TMPFS-READ' \
  s22y 'Tmpfs unparseable: the note prints a command line'
mut "M131 (R-4) a ramfs kernel view not believed — killed by S22y" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-KERNEL-TMPFS' \
  '        tmpfs) _adopt_mcp_unconfirmed "inside the running container, /qdrant/storage is a $k, so its data is held in MEMORY"; return 0 ;;   # BL-311-MCP-CONFIRM-KERNEL-TMPFS' \
  s22y 'kernel says ramfs: the note prints a command line'
mut "M132 (R-4) the volume device option not read — killed by S22y" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-VOLUME-TMPFS' \
  "    if printf '%s' \"\$o\" | jq -e '(. // {}) | [(.type // \"\")] | map(ascii_downcase) | any(. == \"tmpfs\" or . == \"ramfs\")' >/dev/null 2>&1; then   # BL-311-MCP-CONFIRM-VOLUME-TMPFS" \
  s22y 'volume device tmpfs: the note prints a command line'
mut "M133 (R-1) a re-pulled tag accepted — a version jump on recreate — killed by S22y" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-IMAGE-SAME' \
  '  if false; then   # BL-311-MCP-CONFIRM-IMAGE-SAME' \
  s22y 'tag re-pulled: the note prints a command line'
mut "M134 (R-1) an unread image accepted — killed by S22y" \
  scripts/lib/adopt/adopt-mcp.sh '# BL-311-MCP-CONFIRM-IMAGE' \
  '  if false; then   # BL-311-MCP-CONFIRM-IMAGE' \
  s22y 'image unread: the note prints a command line'

_done
