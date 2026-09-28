#!/usr/bin/env bash
# scripts/lib/adopt/adopt-mcp.sh — `## BL-311:` fix 1: the two MCP servers a
# Claude Code session in an adopted project is checked for, Qdrant (memory
# across sessions) and Context7 (current library documentation).
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT THE SESSION CHECKS, READ FROM THE SCRIPTS RATHER THAN ASSUMED
#
# scripts/session-mcp-gate.sh blocks every Write/Edit until qdrant-find and
# Context7's query-docs have SUCCEEDED this session — but only for a server the
# SessionStart hook (scripts/session-test-gate-check.sh) finds REGISTERED. It
# writes `qdrant_required` / `context7_required` from what is registered, and a
# server registered nowhere is not required. So there are three outcomes, and
# this step says which one the operator is in rather than one blanket warning:
#
#   registered and working        the session can satisfy the check
#   registered, nothing answers   EVERY file edit is blocked until it answers
#   not registered anywhere       not required: the session works without it
#
# THE DOGFOOD RUN OF 2026-09-27 met all of it at once. Adoption never looked for
# either server (init.sh provisions Qdrant and hints Context7); the helpers it
# used read `~/.claude.json` while the session's registrations lived under
# CLAUDE_CONFIG_DIR (helpers-core.sh, `soif_claude_config_dir`), so it saw a
# registration the session did not have; and the operator was never told that a
# session already open when adoption ran cannot save a file afterwards.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT THIS STEP DOES, AND WHERE (§8.2, after tool resolution and the secrets
# stop, before the CI audit — `# BL-311-MCP-CALL` says why it is not earlier)
#
# Before any write: read both registrations from the files THIS session reads,
# probe Qdrant, and — ONLY WHEN THIS MACHINE CAN DO IT — offer to set up what is
# missing. "Can do it" is concrete: the `claude` command, plus Docker running
# for the database, plus `uvx` / `npx` for the server a registration launches.
# Registering a server that cannot launch would be worse than not registering
# it: registered makes it REQUIRED, and a required tool that never starts
# blocks every file edit. Where it cannot act it says what to install instead.
#
# THE QUESTION IS NOT MANDATORY, AND THAT IS A DESIGN CONSTRAINT, NOT A NICETY.
# No answer — a blank line, or the end of the input — is "skip it". The other
# questions adoption asks refuse on no answer (`adopt_ask_choice`); this one
# may not, because the adoption does not depend on it, and because CI and
# every adoption suite pipe their answers: on a runner (no `claude` command) it
# is never asked, and where it IS asked a run that supplies no answer for it
# still completes.
#
# ─────────────────────────────────────────────────────────────────────────────
# CONSENT DISCIPLINE — adopt_resolve_tools' rules, applied unchanged:
#   • the exact commands are printed BEFORE the question, never after the answer;
#   • each runs with its cwd in $ADOPT_WORK and stdin from /dev/null, so it can
#     neither write into the operator's repository by a relative path nor eat
#     the operator's remaining answers (fd 0 is the same open file description
#     `adopt_stdin_init` reads them from). SO DOES EVERY PROBE, and that is
#     measured, not tidiness: the first cut's `run_with_deadline 5 docker info`
#     had no redirection, and inside this driver its child READ THE OPERATOR'S
#     PIPE — the suite's stub docker drained every remaining answer and the
#     adoption refused at the next question for want of one (E2; M20 pins it).
#     `run_with_deadline` backgrounds its child, and a standalone reproduction
#     of the same call gives that child /dev/null — so the mechanism inside the
#     driver is NOT isolated, and no probe here relies on it. The real
#     `docker info` does not read stdin; that is luck, not design;
#   • the adoptee's path list is fingerprinted across the run, and a
#     difference — or a fingerprint that could not be read — raises BOTH
#     touched-disk markers. ONE DELIBERATE DIFFERENCE from the resolver, which
#     raises the coarse marker BEFORE its eval because a matrix recipe is
#     arbitrary: these commands are fixed strings, run from $ADOPT_WORK, whose
#     targets are the operator's Claude Code configuration and Docker, never
#     this project. Raising the marker on the attempt would make any later
#     refusal say adoption "had already ATTEMPTED writes to this project" over
#     a tree the fingerprint proves unchanged — `# BL-225-REFUSE-HONEST`'s
#     over-claim. So the marker follows the evidence (S10 pins both arms);
#   • a RECEIPT: registration and reachability are re-read afterwards, and only
#     what the receipt shows is claimed. A zero exit is not evidence.
#
# THE COMMANDS ARE THE CLI SETUP ADDENDUM'S, AND THE QDRANT ONE WAS WRONG
# THERE TOO, MEASURED on Claude Code 2.1.283 against a scratch
# CLAUDE_CONFIG_DIR: `-e` is VARIADIC, so the Addendum's spelling — the name
# `qdrant` written AFTER `-e QDRANT_URL=… -e COLLECTION_NAME=claude-memory` —
# took the name as a third environment value and exited 1 with "Invalid
# environment variable format: qdrant". The server name goes BEFORE the `-e`
# options; that spelling exits 0 and writes the entry. Every tracked copy is
# now in that order, and tests/test-bl311-mcp-add-order.sh keeps it so.
#
# bash-3.2 safe; every local is assigned where it is declared.

ADOPT_MCP_RESULT=""        # the Adoption Record's cell
ADOPT_MCP_PLAN=()          # "<server>|<command>" rows this run would execute

ADOPT_MCP_QDRANT_ADD='claude mcp add -s user qdrant -e QDRANT_URL=http://localhost:6333 -e COLLECTION_NAME=claude-memory -- uvx --python 3.13 mcp-server-qdrant'   # BL-311-MCP-QDRANT-ADD
ADOPT_MCP_CONTEXT7_ADD='claude mcp add context7 --scope user -- npx -y @upstash/context7-mcp'
ADOPT_MCP_QDRANT_START='docker start qdrant'
ADOPT_MCP_QDRANT_RUN='docker run -d --name qdrant -p 6333:6333 -p 6334:6334 -v qdrant_storage:/qdrant/storage --restart unless-stopped qdrant/qdrant:latest'

# _adopt_mcp_state — "<context7> <qdrant-state> <qdrant-url>" for THIS
# session's configuration. helpers-full.sh is read in a SUBSHELL, as the session
# stage does, so its definitions never leak into the driver.
_adopt_mcp_state() {
  ( . "$ADOPT_CORE_LIB_DIR/helpers-full.sh" >/dev/null 2>&1 || exit 3
    _c7="unregistered"
    is_context7_mcp_registered && _c7="registered"
    is_qdrant_mcp_registered || :
    printf '%s %s %s\n' "$_c7" "${QDRANT_MCP_STATE:-unknown}" "$(qdrant_mcp_url)" ) </dev/null   # BL-311-MCP-PROBE-STDIN
}

# _adopt_mcp_local_qdrant — does a database answer at the default address the
# registration below names? rc 0 yes, 1 no, 2 cannot tell (no curl, no nc).
_adopt_mcp_local_qdrant() {
  ( . "$ADOPT_CORE_LIB_DIR/helpers-full.sh" >/dev/null 2>&1 || exit 2
    qdrant_probe_reachable "http://localhost:6333" ) </dev/null
}

_adopt_mcp_docker_up() {
  command -v docker >/dev/null 2>&1 || return 1
  run_with_deadline 5 docker info </dev/null >/dev/null 2>&1   # BL-311-MCP-DOCKER-STDIN
}

# _adopt_mcp_qdrant_container — is there a container named `qdrant` to START,
# rather than one to create? Either answer is safe to act on: `docker start`
# on a running one is a no-op, and a failed lookup falls through to `run`,
# whose own failure is caught by the receipt.
_adopt_mcp_qdrant_container() {
  local names=""
  names="$(run_with_deadline 10 docker ps -a --format '{{.Names}}' </dev/null 2>/dev/null)" || names=""
  printf '%s\n' "$names" | grep -qx 'qdrant'
}

# _adopt_mcp_wait_qdrant — the database takes a moment to accept connections
# after `docker run`, so reachability is polled, bounded, before anything is
# REGISTERED against it. Registering a server whose database never came up
# would make it required and block every file edit.
_adopt_mcp_wait_qdrant() {
  local n="${SOIF_ADOPT_QDRANT_WAIT:-20}" i=0
  case "$n" in ''|*[!0-9]*) n=20 ;; esac
  while :; do
    _adopt_mcp_local_qdrant && return 0
    i=$((i + 1))
    [ "$i" -ge "$n" ] && return 1
    sleep 1
  done
}

# _adopt_mcp_run CMD — run ONE command exactly as it was shown. Bounded:
# `docker run` may pull the image, so it gets the long bound.
_adopt_mcp_run() {
  local cmd="$1" secs=60 rc=0
  case "$cmd" in "docker run "*) secs=600 ;; esac
  ( cd "$ADOPT_WORK" 2>/dev/null && run_with_deadline "$secs" bash -c "$cmd" ) </dev/null >>"$ADOPT_WORK/mcp-setup.out" 2>&1 || rc=$?   # BL-311-MCP-RUN
  return "$rc"
}

# _adopt_mcp_last_output — the last line a failed command printed, so the
# operator sees WHY rather than that. Control bytes stripped; it is shown once.
_adopt_mcp_last_output() {
  tail -n 1 "$ADOPT_WORK/mcp-setup.out" 2>/dev/null | LC_ALL=C tr -d '\000-\037\177' | cut -c1-200
}

_adopt_mcp_is_local_url() {
  case "${1%/}" in http://localhost:6333|http://127.0.0.1:6333) return 0 ;; esac
  return 1
}

_adopt_mcp_describe() {   # _adopt_mcp_describe C7 Q URL
  case "$1" in
    registered) adopt_note "Context7 (current library documentation): registered for Claude Code." ;;
    *)          adopt_note "Context7 (current library documentation): NOT registered for Claude Code." ;;
  esac
  case "$2" in
    reachable)   adopt_note "Qdrant (memory across sessions): registered, and answering at $3." ;;
    unreachable) adopt_note "Qdrant (memory across sessions): registered, but NOTHING answers at $3." ;;
    unknown)     adopt_note "Qdrant (memory across sessions): registered, but whether it answers at $3 could not be checked." ;;
    *)           adopt_note "Qdrant (memory across sessions): NOT registered for Claude Code." ;;
  esac
}

# adopt_mcp_resolve ROOT — the step. Returns 1 only when the operator gave an
# answer that is not one of the two offered (the driver's rule for every
# question); every other path, including skip and failure, returns 0.
adopt_mcp_resolve() {                                  # BL-311-MCP-STEP
  local root="$1"
  local st="" c7="" q="" qurl="" c7_why="" q_why="" q_db="" raw="" ans="" row="" srv="" cmd=""
  local c7_word="" q_word="" q_failed=0 fp_before="" fp_after="" c7_before="" q_before=""
  ADOPT_MCP_PLAN=()
  # `SOIF_ADOPT_MCP=off` IS A TEST SEAM, like SOIF_ADOPT_QDRANT and
  # SOIF_ADOPT_GUARDRAILS_DIR. Every adoption suite written before this step
  # pipes a fixed answer sequence; on a developer machine that HAS `claude`
  # and is missing a server, this step would ask its question in the middle of
  # that sequence and a piped "1" would run real `claude mcp add` / `docker`
  # commands. The seam skips the whole step and says so in one line. The
  # step's own suite, tests/test-bl311-adopt-mcp.sh, never sets it.
  if [ "${SOIF_ADOPT_MCP:-}" = "off" ]; then           # BL-311-MCP-SEAM
    adopt_note "MCP server check skipped (SOIF_ADOPT_MCP=off)."
    ADOPT_MCP_RESULT="not checked (SOIF_ADOPT_MCP=off)"
    return 0
  fi
  adopt_head "The memory and documentation servers Claude Code uses here"

  st="$(_adopt_mcp_state)" || st=""
  if [ -z "$st" ]; then
    adopt_note "Could not read this machine's Claude Code configuration (scripts/lib/helpers-full.sh"
    adopt_note "did not load), so nothing was checked and nothing was set up."
    ADOPT_MCP_RESULT="not checked: the framework's MCP helpers did not load"
    return 0
  fi
  read -r c7 q qurl <<EOF
$st
EOF
  c7_before="$c7"; q_before="$q"
  adopt_note "Read from the two files a Claude Code session started from here reads:"
  adopt_note "  $(soif_claude_json_path)"
  adopt_note "  $(soif_claude_settings_path)"
  _adopt_mcp_describe "$c7" "$q" "$qurl"

  # ── WHAT COULD BE DONE HERE, AND WHY NOT WHERE IT CANNOT ──────────────────
  if [ "$c7" != "registered" ]; then
    if ! command -v claude >/dev/null 2>&1; then c7_why="the claude command is not on PATH"
    elif ! command -v npx >/dev/null 2>&1; then c7_why="npx (Node.js) is not on PATH, and the server runs through it"
    else ADOPT_MCP_PLAN[${#ADOPT_MCP_PLAN[@]}]="context7|$ADOPT_MCP_CONTEXT7_ADD"
    fi
  fi
  case "$q" in
    unregistered)
      if ! command -v claude >/dev/null 2>&1; then q_why="the claude command is not on PATH"
      elif ! command -v uvx >/dev/null 2>&1; then q_why="uvx (from uv) is not on PATH, and the server runs through it"
      elif _adopt_mcp_local_qdrant; then q_db="already answering at http://localhost:6333"
      elif ! _adopt_mcp_docker_up; then q_why="Docker is not running (or not installed), and the database runs in it"
      elif _adopt_mcp_qdrant_container; then q_db="$ADOPT_MCP_QDRANT_START"
      else q_db="$ADOPT_MCP_QDRANT_RUN"
      fi
      if [ -z "$q_why" ]; then
        case "$q_db" in docker*) ADOPT_MCP_PLAN[${#ADOPT_MCP_PLAN[@]}]="qdrant|$q_db" ;; esac
        ADOPT_MCP_PLAN[${#ADOPT_MCP_PLAN[@]}]="qdrant|$ADOPT_MCP_QDRANT_ADD"
      fi ;;
    unreachable)
      if ! _adopt_mcp_is_local_url "$qurl"; then q_why="it is registered at $qurl, which is not a database this machine runs — start that server"
      elif ! _adopt_mcp_docker_up; then q_why="Docker is not running (or not installed), and the database runs in it"
      elif _adopt_mcp_qdrant_container; then ADOPT_MCP_PLAN[${#ADOPT_MCP_PLAN[@]}]="qdrant|$ADOPT_MCP_QDRANT_START"
      else ADOPT_MCP_PLAN[${#ADOPT_MCP_PLAN[@]}]="qdrant|$ADOPT_MCP_QDRANT_RUN"
      fi ;;
    unknown)
      q_why="neither curl nor nc is installed, so whether it answers cannot be checked" ;;
  esac

  [ -n "$c7_why" ] && adopt_note "Adoption cannot set up Context7 here: $c7_why."
  [ -n "$q_why" ] && adopt_note "Adoption cannot set up Qdrant here: $q_why."

  ans="skip it"
  if [ "${#ADOPT_MCP_PLAN[@]}" -gt 0 ]; then            # BL-311-MCP-ASK-ONLY-IF-ACTIONABLE
    adopt_blank
    # SHOWN BEFORE THE QUESTION, not after the answer — consent to run a string
    # the operator has not seen is not consent (adopt_resolve_tools' rule).
    adopt_note "This would run, exactly as written:"
    for row in "${ADOPT_MCP_PLAN[@]}"; do adopt_note "  ${row#*|}"; done   # BL-311-MCP-SHOWN-FIRST
    case "${ADOPT_MCP_PLAN[*]}" in
      *"claude mcp add"*)
        adopt_note "The claude commands change your Claude Code configuration for every project,"
        adopt_note "not only this one. Nothing is written into this project." ;;
      *) adopt_note "Nothing is written into this project." ;;
    esac
    adopt_offer_choice "Set them up now? (No answer means skip it.)" "set it up now" "skip it"
    adopt_read_optional
    raw="$ADOPT_ANSWER"
    printf '\n'
    if [ -z "$raw" ]; then                                   # BL-311-MCP-EOF-SKIP
      adopt_note "No answer — treated as skip it."
    else
      ans="$(adopt_resolve_choice "$raw" "set it up now" "skip it")"
      if [ -z "$ans" ]; then
        adopt_refuse "'$raw' is not one of the answers offered for: setting up the MCP servers"
        return 1
      fi
    fi
  fi

  if [ "$ans" = "set it up now" ]; then
    : > "$ADOPT_WORK/mcp-setup.out" 2>/dev/null
    fp_before="$(adopt_tree_fingerprint "${root:-}")" || fp_before=""
    for row in "${ADOPT_MCP_PLAN[@]}"; do
      srv="${row%%|*}"; cmd="${row#*|}"
      # A failed Qdrant step stops the Qdrant chain: registering a server whose
      # database did not come up would make it required and block every edit.
      [ "$srv" = "qdrant" ] && [ "$q_failed" -eq 1 ] && continue
      adopt_note "Running: $cmd"
      if ! _adopt_mcp_run "$cmd"; then
        adopt_note "  That did not succeed: $(_adopt_mcp_last_output)"
        [ "$srv" = "qdrant" ] && q_failed=1
        continue
      fi
      case "$cmd" in
        docker*)
          if ! _adopt_mcp_wait_qdrant; then
            if [ "$q_before" = "unregistered" ]; then
              adopt_note "  The database did not answer at http://localhost:6333 afterwards, so Qdrant"
              adopt_note "  was not registered — a registered server with no database blocks every edit."
            else
              adopt_note "  The database still did not answer at http://localhost:6333 afterwards."
            fi
            q_failed=1   # BL-311-MCP-WAIT-BEFORE-REGISTER
          fi ;;
      esac
    done
    fp_after="$(adopt_tree_fingerprint "${root:-}")" || fp_after=""
    if [ -z "$fp_before" ] || [ -z "$fp_after" ] || [ "$fp_before" != "$fp_after" ]; then   # BL-311-MCP-TOUCHED-IF
      adopt_touched_disk; adopt_touched_disk_unbounded   # BL-311-MCP-TOUCHED-ON-CHANGE
    fi
    # THE RECEIPT: what is registered and answering NOW, read the same way the
    # first look was. Only this is claimed.
    st="$(_adopt_mcp_state)" || st=""                       # BL-311-MCP-RECEIPT
    read -r c7 q qurl <<EOF
$st
EOF
    adopt_blank
    adopt_note "Afterwards:"
    _adopt_mcp_describe "$c7" "$q" "$qurl"
  elif [ "${#ADOPT_MCP_PLAN[@]}" -gt 0 ]; then
    adopt_note "Skipped. Nothing was run."
  fi

  # ── THE RECORD'S CELL — the state the receipt read, and how it got there ──
  case "$q" in
    reachable)   q_word="registered and answering" ;;
    unreachable) q_word="registered, NOT answering" ;;
    unknown)     q_word="registered, whether it answers not checked" ;;
    *)           q_word="NOT registered" ;;
  esac
  if [ "$q" = "reachable" ] && [ "$q_before" = "reachable" ]; then q_word="$q_word before adoption"
  elif [ "$q" = "reachable" ]; then q_word="set up by adoption, $q_word"
  elif [ -n "$q_why" ]; then q_word="$q_word (adoption could not act: $q_why)"
  elif [ "$ans" = "set it up now" ]; then q_word="$q_word after adoption tried"
  else q_word="$q_word (skipped)"
  fi
  if [ "$c7" = "registered" ] && [ "$c7_before" = "registered" ]; then c7_word="registered before adoption"
  elif [ "$c7" = "registered" ]; then c7_word="set up by adoption, registered"
  elif [ -n "$c7_why" ]; then c7_word="NOT registered (adoption could not act: $c7_why)"
  elif [ "$ans" = "set it up now" ]; then c7_word="NOT registered after adoption tried"
  else c7_word="NOT registered (skipped)"
  fi
  ADOPT_MCP_RESULT="Qdrant: $q_word; Context7: $c7_word"   # BL-311-MCP-RESULT
  [ "$c7" = "registered" ] && [ "$q" = "reachable" ] && return 0

  _adopt_mcp_consequence "$c7" "$q" "$qurl"
  return 0
}

# _adopt_mcp_consequence C7 Q URL — the LOUD NOTE. It states what the session
# check will actually do in each state, because "blocked until both are
# available" is false for a server registered nowhere (session-mcp-gate.sh
# does not require it) and too weak for one registered but silent (it blocks
# EVERY edit). Cases E5 and E6 run the adopted project's own hooks to hold each
# sentence to what the gate really does.
_adopt_mcp_consequence() {                               # BL-311-MCP-LOUD-NOTE
  local c7="$1" q="$2" qurl="$3"
  adopt_blank
  adopt_note "NOT SET UP — what that means for Claude Code in this project:"
  case "$q" in
    unreachable|unknown)
      adopt_note "  Qdrant IS registered, so the framework REQUIRES it: in every Claude Code session"
      adopt_note "  here, EVERY file edit is BLOCKED until qdrant-find succeeds — which needs the"   # BL-311-MCP-NOTE-BLOCKS
      adopt_note "  database at $qurl answering." ;;
    unregistered)
      adopt_note "  Qdrant is not registered: sessions here have no memory of earlier sessions. The"
      adopt_note "  framework's check for it is off while it is not registered, and ON from the first"   # BL-311-MCP-NOTE-OFF
      adopt_note "  session after you register it — so have the database running when you do." ;;
  esac
  if [ "$c7" != "registered" ]; then
    adopt_note "  Context7 is not registered: sessions here cannot read current library documentation."
    adopt_note "  Its check is off until you register it, and ON from the next session after that."
  fi
  adopt_note "To set them up later, run these, then start a new Claude Code session:"
  case "$q" in
    unregistered)
      adopt_note "  $ADOPT_MCP_QDRANT_RUN"
      adopt_note "    (or, if a container named qdrant already exists: $ADOPT_MCP_QDRANT_START)"
      adopt_note "  $ADOPT_MCP_QDRANT_ADD" ;;
    unreachable|unknown)
      if _adopt_mcp_is_local_url "$qurl"; then
        adopt_note "  $ADOPT_MCP_QDRANT_START"
        adopt_note "    (or, if there is no container named qdrant: $ADOPT_MCP_QDRANT_RUN)"
      else
        adopt_note "  (Qdrant: start the server at $qurl — it is not one this machine runs)"
      fi ;;
  esac
  if [ "$c7" != "registered" ]; then adopt_note "  $ADOPT_MCP_CONTEXT7_ADD"; fi
  return 0
}

# adopt_mcp_restart_note — printed at the act boundary, BEFORE "NEXT".
#
# A SESSION ALREADY OPEN WHEN ADOPTION RAN CANNOT SAVE A FILE HERE AFTERWARDS,
# measured in the dogfood run (finding 12): the new hooks fire in it, but its
# SessionStart ran before they existed, so `.claude/tool-usage.json` was never
# written and session-mcp-gate.sh denies every Write/Edit as "cannot tell".
# Only a session started after adoption writes that ledger and loads the MCP
# servers registered above.
adopt_mcp_restart_note() {                             # BL-311-ACT2-RESTART
  adopt_note "FIRST: if a Claude Code session is open in this project, close it and start a new"
  adopt_note "one. The checks, and the memory and documentation tools, that adoption set up"
  adopt_note "only take effect in a session started AFTER adoption — a session that was already"
  adopt_note "open cannot save a file here."
  case "${ADOPT_MCP_RESULT:-}" in
    *"NOT "*|*"not checked:"*)
      adopt_note "Qdrant or Context7 is NOT set up — see 'The memory and documentation servers'"
      adopt_note "above for what that means here and the commands that add them." ;;
  esac
  adopt_blank
}
