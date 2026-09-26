#!/usr/bin/env bash
# tests/test-bl312-tool-usage-concurrent.sh
#
# BL-312 — concurrent writers of .claude/tool-usage.json. Every write in
# scripts/track-tool-usage.sh went `jq … > "$TOOL_USAGE.tmp" && mv`, one temp
# NAME shared by every hook invocation. Two invocations at once (two sessions,
# or subagents, on one project) truncate each other's half-written temp and the
# mv lands it: the ledger ends at 0 bytes, jq on an empty input exits 0 with no
# output, so every later write re-lands it empty, and session-mcp-gate.sh fails
# CLOSED ("requirements not met") on every Write and Edit. Found in practice on
# 22 Sep 2026.
#
# Cases:
#   C0  control: sequential invocations on a seeded ledger record every call.
#       Passes at base; it proves the fixture and the counting, not the fix.
#   C1  a concurrent burst leaves the ledger non-empty, parseable, with every
#       call row, the seeded mcp_requirements kept and the find flags set.
#   C2  a reader polling DURING the burst never sees an empty or unparseable
#       ledger.
#   C3  a concurrent burst of `git commit` events counts every commit.
#   C4  no temp or lock debris is left beside the ledger.
#   C5  a burst with NO ledger seeds it once: every call recorded, and no
#       mcp_requirements object (BL-233's recovery-seed rule still holds).
#   C6  a lock left behind by a killed writer (SIGKILL skips every trap) does
#       not stop tracking, and the concurrent writes that follow it keep the
#       ledger whole. It is run twice: a lock the one break removes, and a
#       stuck one it cannot, where every writer goes ahead unlocked. Lost
#       updates are accepted there; truncation is not.
#   C7  a single write past a stale lock records its call and clears the lock.
#   C8  session-mcp-gate.sh writes the same ledger on every Write and Edit. A
#       concurrent burst of gate checks, alone and mixed with tracker events,
#       leaves a parseable ledger a reader never sees empty, and the next
#       Write is allowed.
#   C9  40 and 80 concurrent events lose no call row: a busy lock is waited
#       for, never broken, because staleness is the lock's AGE, not a count
#       of attempts.
#   C10 SIGTERM mid-write: the tracker (C10) and the gate (C10c) exit 143,
#       release the lock, land nothing and leave no temp. C10b pins INT as
#       measured: sent to the hook alone it is waited out, and the write
#       lands under the lock.
#   C11 SIGKILL mid-write leaves a lock and a temp. Once both are older than
#       the budget, the next event records its call and sweeps both. A fresh
#       temp, which may belong to a live writer, is not swept.
#   C12 a jq filter that prints nothing never lands an empty ledger.
#   C13 an existing 0-byte or unparseable ledger is reseeded by the next MCP
#       event, which records its call.
#   C14 a failed write (the gate on an unparseable ledger) leaves no temp.
#   C15 the sweep takes only its own `.lw.` temps: an aged .backup survives.
#   C16 mkdir failing with EACCES or ENOTDIR is not contention: the gate
#       answers and the tracker finishes within 3s.
#   C17 SessionStart writes the same ledger: concurrent resumes keep every
#       tracker row, and concurrent startups are never seen half-written.
#       C17c: a startup behind a tracker holding the lock lands last, so
#       inherited successes stay erased (BL-236).
#
# Mutants, run against a mirror of the three hooks and their lib. Each proves
# its location: one marker site, and a diff of exactly that line.
#   M1  unique temp -> shared "$TOOL_USAGE.tmp" name; killed by C6's stuck arm.
#   M2  lock never taken; killed by C1's call count and C3's commit count.
#   M4  stale lock never broken; killed by C7 (lock left, every write stalls).
#   MR  a held lock is broken whatever its age; killed by C9.
#   ME  the EXIT trap removed; killed by C10. TERM is left at its default,
#       which ends the hook with 143 and still runs the EXIT trap.
#   MF  the failure path's temp cleanup removed; killed by C14.
#   MG  the non-empty check removed; killed by C12.
#   MN  a non-EEXIST mkdir failure read as contention; killed by C16.
#   MX1 the gate's _lw_traps call removed; killed by C10c.
#   MS  the sweep glob widened back to any six characters; killed by C15.
#   MX2 the sweep's age check removed; killed as C11 would be.
#   MT  SessionStart's startup write back to `cat >`; killed by C17.
#   MX5 SessionStart's whole-ledger write takes no lock; killed by C17c.
# Not a mutant here: skipping the seed lock (# BL-312-SEED-LOCK) survived six
# C5 rounds. Every process in a burst passes the seed check before any of them
# appends, so a second seed cannot land over a first writer's row without
# pausing one process mid-seed. The lock stays because it closes that window
# by construction; the survivor is recorded on `## BL-312:`.
#
# The script under test runs as "$BASH" (the runner's interpreter), never by
# its shebang, so a 3.2 run is a 3.2 run.
# Hermetic: temp dirs only, no git, no network, no `timeout`.
# bash 3.2 compatible: no ${var,,}, no declare -A, no mapfile.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACKER="$REPO_ROOT/scripts/track-tool-usage.sh"
GATE="$REPO_ROOT/scripts/session-mcp-gate.sh"
LIB="$REPO_ROOT/scripts/lib/ledger-write.sh"
SESSION="$REPO_ROOT/scripts/session-test-gate-check.sh"
REAL_JQ="$(command -v jq)"

PASSED=0
FAILED=0
SKIPPED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }
skip_() { echo "  [SKIP] $1 — $2"; SKIPPED=$((SKIPPED + 1)); }

TOPTMP="$(mktemp -d)"
trap 'chmod -R u+w "$TOPTMP" 2>/dev/null; rm -rf "$TOPTMP"' EXIT INT TERM
newtmp() { mktemp -d "$TOPTMP/fixXXXXXX"; }

_num() { case "$1" in ''|null|*[!0-9]*) printf '0\n' ;; *) printf '%s\n' "$1" ;; esac }
_sites() { local n; n=$(grep -c "$2\$" "$1" 2>/dev/null); _num "$n"; }
_changed_lines() { local n; n=$(diff "$1" "$2" 2>/dev/null | grep -c '^[<>]'); _num "$n"; }
_mutate() {
  MUT_FIND="$2" MUT_REPL="$3" perl -pi -e 'BEGIN{$f=$ENV{MUT_FIND};$r=$ENV{MUT_REPL}} s/\Q$f\E/$r/g' "$1"
}

if [ ! -f "$TRACKER" ] || ! command -v jq >/dev/null 2>&1; then
  echo "  [FAIL] setup — tracker or jq missing"
  echo ""
  echo "Results: 0 passed, 1 failed"
  exit 1
fi

echo "BL-312: concurrent writers of the tool-usage ledger (interpreter: $BASH, $BASH_VERSION)"

N=12
ROUNDS=3

FIND_PAYLOAD='{"tool_name":"mcp__qdrant__qdrant-find","hook_event_name":"PostToolUse","tool_response":[{"type":"text","text":"a stored memory"}]}'
COMMIT_PAYLOAD='{"tool_name":"Bash","hook_event_name":"PostToolUse","tool_input":{"command":"git commit -m x"}}'

_seed() {
  mkdir -p "$1/.claude"
  cat > "$1/.claude/tool-usage.json" << 'EOF'
{
  "session_id": "bl312",
  "calls": [],
  "commits_since_last_context7": 0,
  "qdrant_find_called": false,
  "qdrant_find_succeeded": false,
  "mcp_requirements": {"qdrant_required": true, "context7_required": true}
}
EOF
}

_run_one() {  # DIR TRACKER PAYLOAD
  ( cd "$1" && printf '%s' "$3" | "$BASH" "$2" --event PostToolUse >/dev/null 2>&1 )
}

# _burst DIR TRACKER PAYLOAD COUNT — COUNT invocations at once, then wait.
_burst() {
  local i=0 pids=""
  while [ "$i" -lt "$4" ]; do
    _run_one "$1" "$2" "$3" &
    pids="$pids $!"
    i=$((i + 1))
  done
  # shellcheck disable=SC2086
  wait $pids
}

# _reader_start DIR — polls the ledger until DIR/.stop exists; one line in
# DIR/.bad per sighting of an empty or unparseable ledger.
_reader_start() {
  (
    L="$1/.claude/tool-usage.json"
    while [ ! -f "$1/.stop" ]; do
      if [ -f "$L" ]; then
        if [ ! -s "$L" ] || ! jq -e 'type == "object"' "$L" >/dev/null 2>&1; then
          echo bad >> "$1/.bad"
        fi
      fi
    done
  ) &
  READER_PID=$!
}
_reader_stop() { touch "$1/.stop"; wait "$READER_PID" 2>/dev/null; }

_calls()   { _num "$(jq -r '.calls | length' "$1/.claude/tool-usage.json" 2>/dev/null)"; }
_parses()  { [ -s "$1/.claude/tool-usage.json" ] && jq -e 'type == "object"' "$1/.claude/tool-usage.json" >/dev/null 2>&1; }
_bad()     { if [ -f "$1/.bad" ]; then _num "$(wc -l < "$1/.bad" | tr -d ' ')"; else printf '0\n'; fi; }
_debris()  { ls -a "$1/.claude" | grep -v -x -e '.' -e '..' -e 'tool-usage.json' | tr '\n' ' '; }

# _gate_one DIR GATE — one Write check; prints the gate's stdout (empty = allow).
_gate_one() { ( cd "$1" && "$BASH" "$2" < /dev/null 2>/dev/null ); }

# _seed_satisfied DIR — a ledger on which the gate allows.
_seed_satisfied() {
  mkdir -p "$1/.claude"
  cat > "$1/.claude/tool-usage.json" << 'EOF'
{
  "session_id": "bl312",
  "calls": [],
  "commits_since_last_context7": 0,
  "qdrant_find_succeeded": true,
  "context7_query_docs_succeeded": true,
  "mcp_gate_satisfied": false,
  "mcp_requirements": {"qdrant_required": true, "context7_required": true}
}
EOF
}

# _backdate PATH… — make each path older than any lock budget.
_backdate() { touch -t 202001010000 "$@" 2>/dev/null; }

# _await FILE — wait up to 10s for FILE to exist.
_await() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ]
}

# _mk_jq_shim DIR — a jq that, on a filter containing $SHIM_ON only, reads the
# ledger at once, then stalls 2s before emitting, marking DIR/started before
# the stall and DIR/done after the output is written. Reading first is what a
# slow writer looks like: it has already taken the ledger it will replace.
_mk_jq_shim() {
  cat > "$1/jq" << 'EOF'
#!/bin/sh
case "$*" in
  *"$SHIM_ON"*)
    "$REAL_JQ" "$@" > "$SHIM_DIR/out.$$"; rc=$?
    : > "$SHIM_DIR/started"; sleep 2
    cat "$SHIM_DIR/out.$$"; : > "$SHIM_DIR/done"; exit "$rc" ;;
esac
exec "$REAL_JQ" "$@"
EOF
  chmod +x "$1/jq"
}

# _signal_round SCRIPT SIGNAL STALL_ON [satisfied] — one hook run stalled
# inside the write whose filter contains STALL_ON, then SIGNAL to that hook's
# pid alone. A background job of a non-interactive shell starts with INT
# ignored, so perl restores INT's default before exec; the pid is unchanged.
# Sets R_RC R_LOCK R_DEBRIS R_CALLS R_SAT R_DIR.
_signal_round() {
  local d sh pid
  d=$(newtmp)
  if [ "${4:-}" = "satisfied" ]; then _seed_satisfied "$d"; else _seed "$d"; fi
  sh="$d/.shim"; mkdir -p "$sh"; _mk_jq_shim "$sh"
  printf '%s' "$FIND_PAYLOAD" > "$d/.payload"
  ( cd "$d" && PATH="$sh:$PATH" SHIM_DIR="$sh" SHIM_ON="$3" REAL_JQ="$REAL_JQ" \
      exec perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' "$BASH" "$1" --event PostToolUse < "$d/.payload" > /dev/null 2>&1 ) &
  pid=$!
  _await "$sh/started"
  kill "-$2" "$pid" 2>/dev/null
  { wait "$pid"; R_RC=$?; } 2>/dev/null
  _await "$sh/done"
  if [ -d "$d/.claude/tool-usage.json.lockdir" ]; then R_LOCK=held; else R_LOCK=cleared; fi
  R_DEBRIS=$(_debris "$d")
  R_CALLS=$(_calls "$d")
  R_SAT=$(jq -r '.mcp_gate_satisfied' "$d/.claude/tool-usage.json" 2>/dev/null)
  R_DIR="$d"
}

# _timed SECS DIR STDIN CMD… — run CMD in DIR. R_HUNG=1 if it is still running
# after SECS, and it is then killed, so a hang fails the case instead of the
# suite. R_OUT is its stdout.
_timed() {
  local lim=$(( $1 * 10 )) dir="$2" in="$3" i=0 base sub
  base="$TOPTMP/timed-$RANDOM$RANDOM"
  shift 3
  ( cd "$dir" && { "$@" < "$in" > "$base.out" 2>/dev/null & echo "$!" > "$base.pid"; wait "$!"; }; : > "$base.done" ) 2>/dev/null &
  sub=$!
  while [ ! -e "$base.done" ] && [ "$i" -lt "$lim" ]; do sleep 0.1; i=$((i + 1)); done
  if [ -e "$base.done" ]; then
    R_HUNG=0
  else
    R_HUNG=1
    kill -KILL "$(cat "$base.pid" 2>/dev/null)" 2>/dev/null
  fi
  { wait "$sub"; } 2>/dev/null
  R_OUT=$(cat "$base.out" 2>/dev/null)
}

# _session_hook DIR SOURCE HOOK — one SessionStart run with a private HOME and
# no MCP servers configured.
_session_hook() {
  mkdir -p "$1/home"
  ( cd "$1" && printf '{"hook_event_name":"SessionStart","source":"%s"}' "$2" \
      | env HOME="$1/home" "$BASH" "$3" > /dev/null 2>&1 )
}

# ── C0: control ─────────────────────────────────────────────────────────────
D=$(newtmp); _seed "$D"
i=0; while [ "$i" -lt "$N" ]; do _run_one "$D" "$TRACKER" "$FIND_PAYLOAD"; i=$((i + 1)); done
c0=$(_calls "$D")
if _parses "$D" && [ "$c0" = "$N" ]; then
  pass "C0: control, $N sequential invocations record $c0 call rows on a parseable ledger"
else
  fail_ "C0" "sequential run recorded $c0 of $N; the fixture is broken, so no other case means anything"
fi

# ── C1, C2, C4: the concurrent burst ────────────────────────────────────────
# _concurrent_round TRACKER — sets R_CALLS R_PARSES R_REQ R_FLAG R_BAD R_DEBRIS.
_concurrent_round() {
  local d; d=$(newtmp); _seed "$d"
  _reader_start "$d"
  _burst "$d" "$1" "$FIND_PAYLOAD" "$N"
  _reader_stop "$d"
  R_CALLS=$(_calls "$d")
  if _parses "$d"; then R_PARSES=1; else R_PARSES=0; fi
  R_REQ=$(jq -r '.mcp_requirements.qdrant_required // "absent"' "$d/.claude/tool-usage.json" 2>/dev/null)
  R_FLAG=$(jq -r '.qdrant_find_succeeded' "$d/.claude/tool-usage.json" 2>/dev/null)
  R_BAD=$(_bad "$d")
  R_DEBRIS=$(_debris "$d")
}

c1_fail=""; c2_fail=""; c4_fail=""
r=1
while [ "$r" -le "$ROUNDS" ]; do
  _concurrent_round "$TRACKER"
  if [ "$R_PARSES" != "1" ] || [ "$R_CALLS" != "$N" ] || [ "$R_REQ" != "true" ] || [ "$R_FLAG" != "true" ]; then
    c1_fail="$c1_fail round $r: parses=$R_PARSES calls=$R_CALLS/$N qdrant_required=$R_REQ find_succeeded=$R_FLAG;"
  fi
  [ "$R_BAD" != "0" ] && c2_fail="$c2_fail round $r: $R_BAD bad sightings;"
  [ -n "$R_DEBRIS" ] && c4_fail="$c4_fail round $r: $R_DEBRIS;"
  r=$((r + 1))
done
if [ -z "$c1_fail" ]; then
  pass "C1: $ROUNDS rounds of $N concurrent qdrant-find events each leave a parseable ledger with all $N call rows, mcp_requirements kept, find flags set"
else
  fail_ "C1" "$c1_fail"
fi
if [ -z "$c2_fail" ]; then
  pass "C2: a reader polling through every burst never saw an empty or unparseable ledger"
else
  fail_ "C2" "$c2_fail"
fi
if [ -z "$c4_fail" ]; then
  pass "C4: no temp or lock debris beside the ledger after any burst"
else
  fail_ "C4" "$c4_fail"
fi

# ── C3: concurrent commit counter ───────────────────────────────────────────
_commit_round() {  # TRACKER — sets R_COMMITS R_PARSES
  local d; d=$(newtmp); _seed "$d"
  _burst "$d" "$1" "$COMMIT_PAYLOAD" "$N"
  R_COMMITS=$(_num "$(jq -r '.commits_since_last_context7' "$d/.claude/tool-usage.json" 2>/dev/null)")
  if _parses "$d"; then R_PARSES=1; else R_PARSES=0; fi
}
c3_fail=""
r=1
while [ "$r" -le "$ROUNDS" ]; do
  _commit_round "$TRACKER"
  if [ "$R_PARSES" != "1" ] || [ "$R_COMMITS" != "$N" ]; then
    c3_fail="$c3_fail round $r: parses=$R_PARSES commits=$R_COMMITS/$N;"
  fi
  r=$((r + 1))
done
if [ -z "$c3_fail" ]; then
  pass "C3: $ROUNDS rounds of $N concurrent git-commit events each count exactly $N"
else
  fail_ "C3" "$c3_fail"
fi

# ── C5: concurrent seeding from no ledger ───────────────────────────────────
_seed_round() {  # TRACKER — sets R_CALLS R_PARSES R_REQ
  local d; d=$(newtmp)
  _burst "$d" "$1" "$FIND_PAYLOAD" "$N"
  R_CALLS=$(_calls "$d")
  if _parses "$d"; then R_PARSES=1; else R_PARSES=0; fi
  R_REQ=$(jq -r 'has("mcp_requirements")' "$d/.claude/tool-usage.json" 2>/dev/null)
}
c5_fail=""
r=1
while [ "$r" -le "$ROUNDS" ]; do
  _seed_round "$TRACKER"
  if [ "$R_PARSES" != "1" ] || [ "$R_CALLS" != "$N" ] || [ "$R_REQ" != "false" ]; then
    c5_fail="$c5_fail round $r: parses=$R_PARSES calls=$R_CALLS/$N has_requirements=$R_REQ;"
  fi
  r=$((r + 1))
done
if [ -z "$c5_fail" ]; then
  pass "C5: $ROUNDS rounds of $N concurrent events with no ledger each seed it once, record all $N calls, and seed no mcp_requirements"
else
  fail_ "C5" "$c5_fail"
fi

# ── C6: a burst behind a stale lock ─────────────────────────────────────────
# With STUCK=stuck the lock holds a file, so rmdir cannot remove it: the one
# break fails and every writer goes ahead unlocked, all at once.
_stale_round() {  # TRACKER [STUCK] — sets R_PARSES R_BAD R_CALLS
  local d; d=$(newtmp); _seed "$d"
  mkdir "$d/.claude/tool-usage.json.lockdir"
  [ "${2:-}" = "stuck" ] && : > "$d/.claude/tool-usage.json.lockdir/pin"
  _backdate "$d/.claude/tool-usage.json.lockdir"
  _reader_start "$d"
  _burst "$d" "$1" "$FIND_PAYLOAD" "$N"
  _reader_stop "$d"
  if _parses "$d"; then R_PARSES=1; else R_PARSES=0; fi
  R_BAD=$(_bad "$d")
  R_CALLS=$(_calls "$d")
}
c6_fail=""
for c6_mode in breakable stuck; do
  r=1
  while [ "$r" -le "$ROUNDS" ]; do
    _stale_round "$TRACKER" "$c6_mode"
    if [ "$R_PARSES" != "1" ] || [ "$R_BAD" != "0" ] || [ "$R_CALLS" -lt 1 ]; then
      c6_fail="$c6_fail $c6_mode round $r: parses=$R_PARSES bad=$R_BAD calls=$R_CALLS;"
    fi
    r=$((r + 1))
  done
done
if [ -z "$c6_fail" ]; then
  pass "C6: behind a stale lock, breakable or stuck, $ROUNDS rounds of $N concurrent events each keep the ledger parseable throughout and still record calls"
else
  fail_ "C6" "$c6_fail"
fi

# ── C7: one write past a stale lock ─────────────────────────────────────────
_single_stale() {  # TRACKER — sets R_CALLS R_LOCK
  local d; d=$(newtmp); _seed "$d"
  mkdir "$d/.claude/tool-usage.json.lockdir"
  _run_one "$d" "$1" "$FIND_PAYLOAD"
  R_CALLS=$(_calls "$d")
  if [ -d "$d/.claude/tool-usage.json.lockdir" ]; then R_LOCK=held; else R_LOCK=cleared; fi
}
_single_stale "$TRACKER"
if [ "$R_CALLS" = "1" ] && [ "$R_LOCK" = "cleared" ]; then
  pass "C7: one event past a stale lock records its call and clears the lock"
else
  fail_ "C7" "calls=$R_CALLS (want 1), lock=$R_LOCK (want cleared)"
fi

# ── C8: the gate's own writes ───────────────────────────────────────────────
# _gate_round GATE TRACKER MIXED — 12 concurrent gate checks (plus 12 find
# events when MIXED=1) on a satisfied ledger, then one more check. Sets
# R_PARSES R_BAD R_NEXT R_CALLS.
_gate_round() {
  local d i=0 pids=""
  d=$(newtmp); _seed_satisfied "$d"
  _reader_start "$d"
  while [ "$i" -lt "$N" ]; do
    _gate_one "$d" "$1" > /dev/null &
    pids="$pids $!"
    if [ "$3" = "1" ]; then _run_one "$d" "$2" "$FIND_PAYLOAD" & pids="$pids $!"; fi
    i=$((i + 1))
  done
  # shellcheck disable=SC2086
  wait $pids
  _reader_stop "$d"
  if _parses "$d"; then R_PARSES=1; else R_PARSES=0; fi
  R_BAD=$(_bad "$d")
  R_CALLS=$(_calls "$d")
  if [ -z "$(_gate_one "$d" "$1")" ]; then R_NEXT=allow; else R_NEXT=deny; fi
}
c8_fail=""
for mixed in 0 1; do
  r=1
  while [ "$r" -le "$ROUNDS" ]; do
    _gate_round "$GATE" "$TRACKER" "$mixed"
    want_calls=0; [ "$mixed" = "1" ] && want_calls=$N
    if [ "$R_PARSES" != "1" ] || [ "$R_BAD" != "0" ] || [ "$R_NEXT" != "allow" ] || [ "$R_CALLS" != "$want_calls" ]; then
      c8_fail="$c8_fail mixed=$mixed round $r: parses=$R_PARSES bad=$R_BAD next_write=$R_NEXT calls=$R_CALLS/$want_calls;"
    fi
    r=$((r + 1))
  done
done
if [ -z "$c8_fail" ]; then
  pass "C8: $N concurrent gate checks, alone and mixed with $N find events, keep the ledger whole and the next Write allowed ($ROUNDS rounds each)"
else
  fail_ "C8" "$c8_fail"
fi

# ── C9: a busy lock is waited for, not stolen ───────────────────────────────
# _wide_round TRACKER COUNT — sets R_CALLS R_PARSES.
_wide_round() {
  local d; d=$(newtmp); _seed "$d"
  _burst "$d" "$1" "$FIND_PAYLOAD" "$2"
  R_CALLS=$(_calls "$d")
  if _parses "$d"; then R_PARSES=1; else R_PARSES=0; fi
}
c9_fail=""
for wide in 40 80; do
  _wide_round "$TRACKER" "$wide"
  if [ "$R_PARSES" != "1" ] || [ "$R_CALLS" != "$wide" ]; then
    c9_fail="$c9_fail N=$wide: parses=$R_PARSES calls=$R_CALLS/$wide;"
  fi
done
if [ -z "$c9_fail" ]; then
  pass "C9: 40 and 80 concurrent find events record every call row"
else
  fail_ "C9" "$c9_fail"
fi

# ── C10: signals mid-write ──────────────────────────────────────────────────
_signal_round "$TRACKER" TERM '.calls +='
if [ "$R_RC" = "143" ] && [ "$R_LOCK" = "cleared" ] && [ -z "$R_DEBRIS" ] && [ "$R_CALLS" = "0" ]; then
  pass "C10: SIGTERM inside the tracker's write exits 143, releases the lock, lands nothing, leaves no temp"
else
  fail_ "C10" "rc=$R_RC (want 143) lock=$R_LOCK debris=[$R_DEBRIS] calls=$R_CALLS (want 0)"
fi

# C10b pins what INT actually does: bash defers it until the foreground jq
# exits, jq never received it, so the hook carries on and the write lands
# whole under the lock. Measured, not designed; it passes at round two's head.
_signal_round "$TRACKER" INT '.calls +='
if [ "$R_RC" = "0" ] && [ "$R_LOCK" = "cleared" ] && [ -z "$R_DEBRIS" ] && [ "$R_CALLS" = "1" ]; then
  pass "C10b: SIGINT to the tracker alone is waited out: rc=0, the write lands, the lock is released, no temp"
else
  fail_ "C10b" "rc=$R_RC (want 0) lock=$R_LOCK debris=[$R_DEBRIS] calls=$R_CALLS (want 1)"
fi

# The stall is on the WRITE's filter; `.mcp_gate_satisfied` alone also
# matches the gate's earlier read, which holds no lock.
_signal_round "$GATE" TERM '.mcp_gate_satisfied = true' satisfied
if [ "$R_RC" = "143" ] && [ "$R_LOCK" = "cleared" ] && [ -z "$R_DEBRIS" ] && [ "$R_SAT" = "false" ]; then
  pass "C10c: SIGTERM inside the gate's write exits 143, releases the lock, lands nothing, leaves no temp"
else
  fail_ "C10c" "rc=$R_RC (want 143) lock=$R_LOCK debris=[$R_DEBRIS] mcp_gate_satisfied=$R_SAT (want false)"
fi

# ── C11: SIGKILL mid-write, then recovery ───────────────────────────────────
_signal_round "$TRACKER" KILL '.calls +='
c11_left="lock=$R_LOCK debris=[$R_DEBRIS]"
# shellcheck disable=SC2046
_backdate "$R_DIR/.claude/tool-usage.json.lockdir" $(ls -d "$R_DIR"/.claude/tool-usage.json.* 2>/dev/null)
: > "$R_DIR/.claude/tool-usage.json.lw.LIVE01"
_run_one "$R_DIR" "$TRACKER" "$FIND_PAYLOAD"
c11_calls=$(_calls "$R_DIR"); c11_debris=$(_debris "$R_DIR")
if [ "$c11_calls" = "1" ] && [ "$c11_debris" = "tool-usage.json.lw.LIVE01 " ]; then
  pass "C11: after SIGKILL ($c11_left) the next event records its call and sweeps the aged lock and temp, and keeps a fresh one"
else
  fail_ "C11" "after SIGKILL ($c11_left): calls=$c11_calls (want 1) debris=[$c11_debris] (want only the fresh tool-usage.json.lw.LIVE01)"
fi

# ── C12: a filter that prints nothing lands nothing ─────────────────────────
# The probe write after it is the control: it proves the lib loaded and writes,
# so "unchanged" cannot pass because nothing ran at all.
_empty_filter() {  # LIB — sets R_SAME R_PROBE R_DEBRIS
  local d before
  d=$(newtmp); _seed "$d"
  before=$(cat "$d/.claude/tool-usage.json")
  ( cd "$d" && LW_LIB="$1" "$BASH" -c 'TOOL_USAGE=.claude/tool-usage.json; . "$LW_LIB"; _lw_update empty' ) > /dev/null 2>&1
  if [ "$(cat "$d/.claude/tool-usage.json")" = "$before" ]; then R_SAME=1; else R_SAME=0; fi
  R_DEBRIS=$(_debris "$d")
  ( cd "$d" && LW_LIB="$1" "$BASH" -c 'TOOL_USAGE=.claude/tool-usage.json; . "$LW_LIB"; _lw_update ".probe = 1"' ) > /dev/null 2>&1
  R_PROBE=$(jq -r '.probe' "$d/.claude/tool-usage.json" 2>/dev/null)
}
_empty_filter "$LIB"
if [ "$R_SAME" = "1" ] && [ -z "$R_DEBRIS" ] && [ "$R_PROBE" = "1" ]; then
  pass "C12: a jq filter with no output leaves the ledger as it was, and no temp; a real filter then lands"
else
  fail_ "C12" "ledger unchanged=$R_SAME (want 1) debris=[$R_DEBRIS] probe=$R_PROBE (want 1, proves the lib wrote)"
fi

# ── C13: an empty or unparseable ledger is reseeded ─────────────────────────
c13_fail=""
for bad_ledger in empty garbage; do
  d=$(newtmp); mkdir -p "$d/.claude"
  if [ "$bad_ledger" = "empty" ]; then : > "$d/.claude/tool-usage.json"; else printf '{"calls": [' > "$d/.claude/tool-usage.json"; fi
  _run_one "$d" "$TRACKER" "$FIND_PAYLOAD"
  c13_calls=$(_calls "$d")
  c13_req=$(jq -r 'has("mcp_requirements")' "$d/.claude/tool-usage.json" 2>/dev/null)
  c13_ok=$(jq -r '.qdrant_find_succeeded' "$d/.claude/tool-usage.json" 2>/dev/null)
  if ! _parses "$d" || [ "$c13_calls" != "1" ] || [ "$c13_req" != "false" ] || [ "$c13_ok" != "true" ]; then
    c13_fail="$c13_fail $bad_ledger: calls=$c13_calls has_requirements=$c13_req find_succeeded=$c13_ok;"
  fi
done
if [ -z "$c13_fail" ]; then
  pass "C13: a 0-byte and an unparseable ledger are each reseeded by the next event, which records its call and seeds no mcp_requirements"
else
  fail_ "C13" "$c13_fail"
fi

# ── C14: a failed write leaves no temp ──────────────────────────────────────
_failed_write() {  # GATE — sets R_DEBRIS R_OUT
  local d; d=$(newtmp); mkdir -p "$d/.claude"
  printf '{"calls": [' > "$d/.claude/tool-usage.json"
  R_OUT=$(_gate_one "$d" "$1")
  R_DEBRIS=$(_debris "$d")
}
_failed_write "$GATE"
if [ -n "$R_OUT" ] && [ -z "$R_DEBRIS" ]; then
  pass "C14: the gate on an unparseable ledger denies, and its failed write leaves no temp"
else
  fail_ "C14" "gate output bytes=${#R_OUT} (want a deny) debris=[$R_DEBRIS] (want none)"
fi

# ── C15: the sweep takes only its own temps ─────────────────────────────────
_sweep_neighbours() {  # TRACKER — sets R_LEFT
  local d; d=$(newtmp); _seed "$d"
  : > "$d/.claude/tool-usage.json.backup"
  : > "$d/.claude/tool-usage.json.bak"
  : > "$d/.claude/tool-usage.json.lw.AGED01"
  _backdate "$d/.claude/tool-usage.json.backup" "$d/.claude/tool-usage.json.bak" "$d/.claude/tool-usage.json.lw.AGED01"
  _run_one "$d" "$1" "$FIND_PAYLOAD"
  R_LEFT=$(_debris "$d")
}
_sweep_neighbours "$TRACKER"
if [ "$R_LEFT" = "tool-usage.json.backup tool-usage.json.bak " ]; then
  pass "C15: an aged tool-usage.json.backup and .bak survive the sweep, and an aged .lw. temp does not"
else
  fail_ "C15" "left=[$R_LEFT] (want the .backup and .bak only)"
fi

# ── C16: mkdir fails for a reason other than EEXIST ─────────────────────────
# POSIX mkdir() fails with EEXIST only when the lock is held. EACCES (a 0555
# .claude) and ENOTDIR (.claude is a file) are not contention: the hook must
# give up the lock at once and finish, the gate with its deny text. A read-only
# mount (EROFS) and a full disk (ENOSPC) cannot be made in a test; they take
# the same path as EACCES, since the lockdir never appears.
c16_fail=""; c16_skip=""
c16_shape() {  # LABEL WANT(deny|allow|exit) SCRIPT SEED(unsatisfied|satisfied|file) — adds to c16_fail
  local d; d=$(newtmp)
  case "$4" in
    unsatisfied) _seed "$d" ;;
    satisfied) _seed_satisfied "$d" ;;
    file) : > "$d/.claude" ;;
  esac
  if [ "$4" != "file" ]; then
    chmod 555 "$d/.claude"
    if ( : > "$d/.claude/.probe" ) 2>/dev/null; then
      rm -f "$d/.claude/.probe"; chmod 755 "$d/.claude"
      c16_skip="$c16_skip $1"
      return
    fi
  fi
  printf '%s' "$FIND_PAYLOAD" > "$d/.payload"
  _timed 3 "$d" "$d/.payload" "$BASH" "$3" --event PostToolUse
  [ -d "$d/.claude" ] && chmod 755 "$d/.claude"
  if [ "$R_HUNG" = "1" ]; then
    c16_fail="$c16_fail $1: still running after 3s;"
  elif [ "$2" = "deny" ] && ! printf '%s' "$R_OUT" | grep '"permissionDecision": "deny"' >/dev/null; then
    c16_fail="$c16_fail $1: no deny (stdout bytes=${#R_OUT});"
  elif [ "$2" = "allow" ] && [ -n "$R_OUT" ]; then
    c16_fail="$c16_fail $1: stdout bytes=${#R_OUT} (want none, an allow);"
  fi
}
c16_shape "gate/EACCES/unsatisfied" deny  "$GATE"    unsatisfied
c16_shape "gate/EACCES/satisfied"   allow "$GATE"    satisfied
c16_shape "tracker/EACCES"          exit  "$TRACKER" unsatisfied
c16_shape "tracker/ENOTDIR"         exit  "$TRACKER" file
if [ -n "$c16_skip" ]; then
  skip_ "C16" "a 0555 directory is still writable here (running as root?), so EACCES cannot be made:$c16_skip"
fi
if [ -n "$c16_fail" ]; then
  fail_ "C16" "$c16_fail"
elif [ -z "$c16_skip" ]; then
  pass "C16: with .claude unwritable (EACCES) or not a directory (ENOTDIR), the gate denies or allows and the tracker finishes, each within 3s"
fi

# ── C17: SessionStart writes the same ledger ────────────────────────────────
# _session_round HOOK TRACKER SOURCE COUNT — COUNT SessionStart runs at once,
# plus COUNT find events when SOURCE is resume. Sets R_PARSES R_BAD R_CALLS.
_session_round() {
  local d i=0 pids=""
  d=$(newtmp); _seed "$d"
  _reader_start "$d"
  while [ "$i" -lt "$4" ]; do
    _session_hook "$d" "$3" "$1" &
    pids="$pids $!"
    if [ "$3" = "resume" ]; then _run_one "$d" "$2" "$FIND_PAYLOAD" & pids="$pids $!"; fi
    i=$((i + 1))
  done
  # shellcheck disable=SC2086
  wait $pids
  _reader_stop "$d"
  if _parses "$d"; then R_PARSES=1; else R_PARSES=0; fi
  R_BAD=$(_bad "$d")
  R_CALLS=$(_calls "$d")
}
c17_fail=""
r=1
while [ "$r" -le "$ROUNDS" ]; do
  _session_round "$SESSION" "$TRACKER" resume "$N"
  if [ "$R_PARSES" != "1" ] || [ "$R_BAD" != "0" ] || [ "$R_CALLS" != "$N" ]; then
    c17_fail="$c17_fail resume round $r: parses=$R_PARSES bad=$R_BAD calls=$R_CALLS/$N;"
  fi
  _session_round "$SESSION" "$TRACKER" startup "$N"
  if [ "$R_PARSES" != "1" ] || [ "$R_BAD" != "0" ]; then
    c17_fail="$c17_fail startup round $r: parses=$R_PARSES bad=$R_BAD;"
  fi
  r=$((r + 1))
done
if [ -z "$c17_fail" ]; then
  pass "C17: $N concurrent SessionStart resumes mixed with $N find events keep every call row, and $N concurrent startups are never seen half-written ($ROUNDS rounds each)"
else
  fail_ "C17" "$c17_fail"
fi

# C17c: a startup must win over a tracker already part-way through a write.
# The ledger carries inherited successes (BL-236's clone case). A tracker
# reads it and stalls holding the lock; a startup then runs. Locked, the
# startup waits and lands last, so the inheritance is erased. If the startup
# write took no lock, the tracker's mv would land last and bring it back.
# The tracker's event is a `git commit`: its one write carries the whole
# ledger forward and earns no MCP success of its own.
_startup_race() {  # HOOK TRACKER — sets R_Q R_C R_COMMITS
  local d sh tpid
  d=$(newtmp); _seed_satisfied "$d"
  sh="$d/.shim"; mkdir -p "$sh"; _mk_jq_shim "$sh"
  printf '%s' "$COMMIT_PAYLOAD" > "$d/.payload"
  ( cd "$d" && PATH="$sh:$PATH" SHIM_DIR="$sh" SHIM_ON='.commits_since_last_context7 = ' REAL_JQ="$REAL_JQ" \
      "$BASH" "$2" --event PostToolUse < "$d/.payload" > /dev/null 2>&1 ) &
  tpid=$!
  _await "$sh/started"
  _session_hook "$d" startup "$1"
  { wait "$tpid"; } 2>/dev/null
  R_Q=$(jq -r '.qdrant_find_succeeded // false' "$d/.claude/tool-usage.json" 2>/dev/null)
  R_C=$(jq -r '.context7_query_docs_succeeded // false' "$d/.claude/tool-usage.json" 2>/dev/null)
  R_COMMITS=$(jq -r '.commits_since_last_context7' "$d/.claude/tool-usage.json" 2>/dev/null)
}
_startup_race "$SESSION" "$TRACKER"
if [ "$R_Q" = "false" ] && [ "$R_C" = "false" ]; then
  pass "C17c: a startup behind a tracker holding the lock lands last, so inherited successes stay erased (commits=$R_COMMITS)"
else
  fail_ "C17c" "qdrant_find_succeeded=$R_Q context7_query_docs_succeeded=$R_C (both want false): the tracker's write landed over the startup reset"
fi

# ── Mutants ─────────────────────────────────────────────────────────────────
# _mk_mutant NAME RELFILE MARKER FIND REPL — sets MUT_DIR to a mirror of the
# three hooks and their lib with RELFILE (under scripts/) mutated, or fails
# NAME. Location is proved, not assumed: the marker has one end-of-line site,
# and the diff is exactly one line replaced, at that marker's line number.
_mk_mutant() {
  local src="$REPO_ROOT/scripts/$2" f sites ln hunk changed
  MUT_DIR="$TOPTMP/mut-$1/scripts"
  mkdir -p "$MUT_DIR/lib"
  cp "$TRACKER" "$GATE" "$SESSION" "$MUT_DIR/"
  cp "$LIB" "$MUT_DIR/lib/"
  f="$MUT_DIR/$2"
  sites=$(_sites "$src" "$3")
  if [ "$sites" != "1" ]; then
    fail_ "$1" "marker '$3' has $sites end-of-line sites in $2 (want 1); the mutant cannot be placed"
    return 1
  fi
  ln=$(grep -n -- "$3\$" "$src" | cut -d: -f1)
  _mutate "$f" "$4" "$5"
  hunk=$(diff "$src" "$f" 2>/dev/null | head -1)
  changed=$(_changed_lines "$src" "$f")
  if [ "$changed" != "2" ] || [ "$hunk" != "${ln}c${ln}" ]; then
    fail_ "$1" "mutation changed $changed lines at hunk '$hunk' (want 2 lines at ${ln}c${ln}, the marker's line); it did not land where claimed"
    return 1
  fi
  if ! "$BASH" -n "$f" 2>/dev/null; then
    fail_ "$1" "mutant does not parse"
    return 1
  fi
  return 0
}

# M1: the shared temp name back. Only unlocked writes can collide on it, so
# only C6's stuck arm, where every writer goes ahead unlocked, sees it.
if _mk_mutant "M1" lib/ledger-write.sh "# BL-312-UNIQUE-TMP" \
     'tmp=$(mktemp "$TOOL_USAGE.lw.XXXXXX" 2>/dev/null) || tmp=""   # BL-312-UNIQUE-TMP' \
     'tmp="$TOOL_USAGE.tmp"   # BL-312-UNIQUE-TMP'; then
  m1_killed=""
  r=1
  while [ "$r" -le 6 ] && [ -z "$m1_killed" ]; do
    _stale_round "$MUT_DIR/track-tool-usage.sh" stuck
    if [ "$R_PARSES" != "1" ] || [ "$R_BAD" != "0" ]; then m1_killed="round $r: parses=$R_PARSES bad=$R_BAD"; fi
    r=$((r + 1))
  done
  if [ -n "$m1_killed" ]; then
    pass "M1: the shared temp name is killed by C6's stuck arm ($m1_killed)"
  else
    fail_ "M1" "shared temp name survived 6 stuck-lock rounds; C6 does not discriminate"
  fi
fi

# M2: the lock is never taken.
if _mk_mutant "M2" lib/ledger-write.sh "# BL-312-LOCK" \
     'while ! mkdir "$TOOL_USAGE.lockdir" 2>/dev/null; do   # BL-312-LOCK' \
     'while false; do   # BL-312-LOCK'; then
  m2_killed=""
  r=1
  while [ "$r" -le 6 ] && [ -z "$m2_killed" ]; do
    _concurrent_round "$MUT_DIR/track-tool-usage.sh"
    [ "$R_CALLS" != "$N" ] && m2_killed="C1 calls=$R_CALLS/$N"
    if [ -z "$m2_killed" ]; then
      _commit_round "$MUT_DIR/track-tool-usage.sh"
      [ "$R_COMMITS" != "$N" ] && m2_killed="C3 commits=$R_COMMITS/$N"
    fi
    r=$((r + 1))
  done
  if [ -n "$m2_killed" ]; then
    pass "M2: without the lock updates are lost ($m2_killed)"
  else
    fail_ "M2" "unlocked writers lost nothing in 6 rounds; C1 and C3 do not discriminate"
  fi
fi

# M4: a stale lock is never broken.
if _mk_mutant "M4" lib/ledger-write.sh "# BL-312-BREAK-STALE" \
     'rmdir "$TOOL_USAGE.lockdir" 2>/dev/null || :   # BL-312-BREAK-STALE' \
     ':   # BL-312-BREAK-STALE'; then
  _single_stale "$MUT_DIR/track-tool-usage.sh"
  if [ "$R_LOCK" = "held" ]; then
    pass "M4: without the breaker a stale lock outlives the write (calls=$R_CALLS, lock=$R_LOCK), so every later write waits out the budget"
  else
    fail_ "M4" "lock=$R_LOCK with the breaker removed; C7 does not discriminate"
  fi
fi

# MR: a held lock is broken whatever its age — the attempt-count breaker's
# failure, taken to its limit.
if _mk_mutant "MR" lib/ledger-write.sh "# BL-312-STALE-AGE" \
     'if [ $((now - mt)) -gt "$LW_BUDGET" ]; then   # BL-312-STALE-AGE' \
     'if true; then   # BL-312-STALE-AGE'; then
  _wide_round "$MUT_DIR/track-tool-usage.sh" 40
  if [ "$R_CALLS" != "40" ]; then
    pass "MR: breaking a live lock loses call rows (C9 calls=$R_CALLS/40)"
  else
    fail_ "MR" "breaking live locks lost nothing at N=40; C9 does not discriminate"
  fi
fi

# ME: the trap removed.
if _mk_mutant "ME" lib/ledger-write.sh "# BL-312-TRAP" \
     "trap '_lw_cleanup' EXIT   # BL-312-TRAP" \
     ':   # BL-312-TRAP'; then
  _signal_round "$MUT_DIR/track-tool-usage.sh" TERM '.calls +='
  if [ "$R_LOCK" = "held" ] || [ -n "$R_DEBRIS" ] || [ "$R_RC" != "143" ]; then
    pass "ME: without the trap a signalled write leaves debris (rc=$R_RC lock=$R_LOCK debris=[$R_DEBRIS])"
  else
    fail_ "ME" "the trap removed left nothing behind; C10 does not discriminate"
  fi
fi

# MF: the failure path's temp cleanup removed.
if _mk_mutant "MF" lib/ledger-write.sh "# BL-312-FAIL-CLEAN" \
     'rm -f "$tmp"   # BL-312-FAIL-CLEAN' \
     ':   # BL-312-FAIL-CLEAN'; then
  _failed_write "$MUT_DIR/session-mcp-gate.sh"
  if [ -n "$R_DEBRIS" ]; then
    pass "MF: without the cleanup a failed write leaves its temp (debris=[$R_DEBRIS])"
  else
    fail_ "MF" "no temp left with the cleanup removed; C14 does not discriminate"
  fi
fi

# MG: the non-empty check removed.
if _mk_mutant "MG" lib/ledger-write.sh "# BL-312-NONEMPTY" \
     '[ -s "$tmp" ] && mv "$tmp" "$TOOL_USAGE" 2>/dev/null; then   # BL-312-NONEMPTY' \
     'mv "$tmp" "$TOOL_USAGE" 2>/dev/null; then   # BL-312-NONEMPTY'; then
  _empty_filter "$MUT_DIR/lib/ledger-write.sh"
  if [ "$R_SAME" = "0" ]; then
    pass "MG: without the non-empty check a filter with no output empties the ledger"
  else
    fail_ "MG" "the ledger survived with the check removed; C12 does not discriminate"
  fi
fi

# MN: every mkdir failure read as contention again.
if _mk_mutant "MN" lib/ledger-write.sh "# BL-312-NOT-EEXIST" \
     '[ -e "$TOOL_USAGE.lockdir" ] || return 1   # BL-312-NOT-EEXIST' \
     ':   # BL-312-NOT-EEXIST'; then
  c16_fail=""; c16_skip=""
  c16_shape "gate/EACCES/unsatisfied" deny "$MUT_DIR/session-mcp-gate.sh" unsatisfied
  if [ -n "$c16_skip" ]; then
    skip_ "MN" "EACCES cannot be made here"
  elif [ -n "$c16_fail" ]; then
    pass "MN: reading EACCES as contention stalls the gate again ($c16_fail)"
  else
    fail_ "MN" "the gate still answered with the check removed; C16 does not discriminate"
  fi
fi

# MX1: the gate installs no trap.
if _mk_mutant "MX1" session-mcp-gate.sh "# BL-312-GATE-TRAP" \
     '&& _lw_traps && LW_READY=1' \
     '&& LW_READY=1'; then
  _signal_round "$MUT_DIR/session-mcp-gate.sh" TERM '.mcp_gate_satisfied = true' satisfied
  if [ "$R_LOCK" = "held" ] || [ -n "$R_DEBRIS" ]; then
    pass "MX1: without its trap a signalled gate leaves debris (rc=$R_RC lock=$R_LOCK debris=[$R_DEBRIS])"
  else
    fail_ "MX1" "the gate's trap removed left nothing behind; C10c does not discriminate"
  fi
fi

# MS: the sweep takes any six-character suffix again.
if _mk_mutant "MS" lib/ledger-write.sh "# BL-312-SWEEP-GLOB" \
     '"$TOOL_USAGE".lw.??????; do' \
     '"$TOOL_USAGE".??????; do'; then
  _sweep_neighbours "$MUT_DIR/track-tool-usage.sh"
  if [ "$R_LEFT" != "tool-usage.json.backup tool-usage.json.bak " ]; then
    pass "MS: the wide glob deletes a neighbour or keeps an aged temp (left=[$R_LEFT])"
  else
    fail_ "MS" "the wide glob left the same files; C15 does not discriminate"
  fi
fi

# MX2: the sweep ignores age.
if _mk_mutant "MX2" lib/ledger-write.sh "# BL-312-SWEEP-AGE" \
     '[ $((now - mt)) -gt "$LW_BUDGET" ] && rm -f "$f" || :' \
     'rm -f "$f" || :'; then
  d=$(newtmp); _seed "$d"; : > "$d/.claude/tool-usage.json.lw.LIVE01"
  _run_one "$d" "$MUT_DIR/track-tool-usage.sh" "$FIND_PAYLOAD"
  if [ ! -e "$d/.claude/tool-usage.json.lw.LIVE01" ]; then
    pass "MX2: a sweep that ignores age deletes a fresh temp a live writer may own"
  else
    fail_ "MX2" "the fresh temp survived with the age check removed; C11 does not discriminate"
  fi
fi

# MT: SessionStart's startup write back to an unlocked truncating redirect.
if _mk_mutant "MT" session-test-gate-check.sh "# BL-312-SESSION-PUT" \
     '_lw_put << TUEOF   # BL-312-SESSION-PUT' \
     'cat > "$TOOL_USAGE" << TUEOF   # BL-312-SESSION-PUT'; then
  mt_killed=""
  r=1
  while [ "$r" -le 6 ] && [ -z "$mt_killed" ]; do
    _session_round "$MUT_DIR/session-test-gate-check.sh" "$TRACKER" startup "$N"
    if [ "$R_PARSES" != "1" ] || [ "$R_BAD" != "0" ]; then mt_killed="round $r: parses=$R_PARSES bad=$R_BAD"; fi
    r=$((r + 1))
  done
  if [ -n "$mt_killed" ]; then
    pass "MT: an unlocked startup write is seen half-written ($mt_killed)"
  else
    fail_ "MT" "unlocked startup writes were never seen half-written in 6 rounds; C17 does not discriminate"
  fi
fi

# MX5: SessionStart's whole-ledger write takes no lock.
if _mk_mutant "MX5" lib/ledger-write.sh "# BL-312-PUT-LOCK" \
     '_lw_lock || :   # BL-312-PUT-LOCK' \
     ':   # BL-312-PUT-LOCK'; then
  _startup_race "$MUT_DIR/session-test-gate-check.sh" "$MUT_DIR/track-tool-usage.sh"
  if [ "$R_Q" = "true" ] || [ "$R_C" = "true" ]; then
    pass "MX5: an unlocked startup write is overwritten by the stalled tracker, and the inherited successes return (qdrant=$R_Q context7=$R_C)"
  else
    fail_ "MX5" "the startup reset held without the lock; C17c does not discriminate"
  fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed, $SKIPPED skipped"
[ "$FAILED" -eq 0 ]
