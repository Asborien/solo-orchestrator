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
#       ledger whole. Lost updates are accepted there; truncation is not.
#   C7  a single write past a stale lock records its call and clears the lock.
#
# Mutants (each proves it landed: marker sites==1 before, changed>=2 lines,
# bash -n clean), run against a copy of the tracker:
#   M1  unique temp -> shared "$TOOL_USAGE.tmp" name; killed by C6's arm.
#   M2  lock never taken; killed by C1's call count and C3's commit count.
#   M4  stale lock never broken; killed by C7 (lock left, every write stalls).
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

PASSED=0
FAILED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }

TOPTMP="$(mktemp -d)"
trap 'rm -rf "$TOPTMP"' EXIT INT TERM
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
_stale_round() {  # TRACKER — sets R_PARSES R_BAD R_CALLS
  local d; d=$(newtmp); _seed "$d"
  mkdir "$d/.claude/tool-usage.json.lockdir"
  _reader_start "$d"
  _burst "$d" "$1" "$FIND_PAYLOAD" "$N"
  _reader_stop "$d"
  if _parses "$d"; then R_PARSES=1; else R_PARSES=0; fi
  R_BAD=$(_bad "$d")
  R_CALLS=$(_calls "$d")
}
c6_fail=""
r=1
while [ "$r" -le "$ROUNDS" ]; do
  _stale_round "$TRACKER"
  if [ "$R_PARSES" != "1" ] || [ "$R_BAD" != "0" ] || [ "$R_CALLS" -lt 1 ]; then
    c6_fail="$c6_fail round $r: parses=$R_PARSES bad=$R_BAD calls=$R_CALLS;"
  fi
  r=$((r + 1))
done
if [ -z "$c6_fail" ]; then
  pass "C6: behind a stale lock, $ROUNDS rounds of $N concurrent events keep the ledger parseable throughout and still record calls"
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

# ── Mutants ─────────────────────────────────────────────────────────────────
# _mk_mutant NAME MARKER FIND REPL — sets MUT to a mutated copy, or fails NAME.
_mk_mutant() {
  MUT="$TOPTMP/mut-$1.sh"
  cp "$TRACKER" "$MUT"
  local sites; sites=$(_sites "$TRACKER" "$2")
  if [ "$sites" != "1" ]; then
    fail_ "$1" "marker '$2' has $sites end-of-line sites (want 1); the mutant cannot be placed"
    return 1
  fi
  _mutate "$MUT" "$3" "$4"
  local changed; changed=$(_changed_lines "$TRACKER" "$MUT")
  if [ "$changed" -lt 2 ]; then
    fail_ "$1" "mutation changed $changed lines (want >= 2); it did not land"
    return 1
  fi
  if ! "$BASH" -n "$MUT" 2>/dev/null; then
    fail_ "$1" "mutant does not parse"
    return 1
  fi
  return 0
}

# M1: the shared temp name back. Only the lock-miss path writes unlocked, so
# only C6 can see it; C1 correctly survives.
if _mk_mutant "M1" "# BL-312-UNIQUE-TMP" \
     'tmp=$(mktemp "$TOOL_USAGE.XXXXXX" 2>/dev/null)   # BL-312-UNIQUE-TMP' \
     'tmp="$TOOL_USAGE.tmp"   # BL-312-UNIQUE-TMP'; then
  m1_killed=""
  r=1
  while [ "$r" -le 6 ] && [ -z "$m1_killed" ]; do
    _stale_round "$MUT"
    if [ "$R_PARSES" != "1" ] || [ "$R_BAD" != "0" ]; then m1_killed="round $r: parses=$R_PARSES bad=$R_BAD"; fi
    r=$((r + 1))
  done
  if [ -n "$m1_killed" ]; then
    pass "M1: the shared temp name is killed by C6's arm ($m1_killed)"
  else
    fail_ "M1" "shared temp name survived 6 stale-lock rounds; C6 does not discriminate"
  fi
fi

# M2: the lock is never taken.
if _mk_mutant "M2" "# BL-312-LOCK" \
     'while ! mkdir "$TT_LOCK" 2>/dev/null; do   # BL-312-LOCK' \
     'while false; do   # BL-312-LOCK'; then
  m2_killed=""
  r=1
  while [ "$r" -le 6 ] && [ -z "$m2_killed" ]; do
    _concurrent_round "$MUT"
    [ "$R_CALLS" != "$N" ] && m2_killed="C1 calls=$R_CALLS/$N"
    if [ -z "$m2_killed" ]; then
      _commit_round "$MUT"
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
if _mk_mutant "M4" "# BL-312-BREAK-STALE" \
     'rmdir "$TT_LOCK" 2>/dev/null   # BL-312-BREAK-STALE' \
     ':   # BL-312-BREAK-STALE'; then
  _single_stale "$MUT"
  if [ "$R_LOCK" = "held" ]; then
    pass "M4: without the breaker a stale lock outlives the write (calls=$R_CALLS, lock=$R_LOCK), so every later write waits out the budget"
  else
    fail_ "M4" "lock=$R_LOCK with the breaker removed; C7 does not discriminate"
  fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
