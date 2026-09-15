#!/usr/bin/env bash
# tests/test-bl276-stdin-hang.sh — BL-276: a test suite's outcome must not
# depend on what its CALLER left on stdin, and it must terminate either way.
#
# THE DEFECT. `tests/test-intake-wizard-fixes.sh` invoked the SessionStart hook
# `scripts/session-test-gate-check.sh` inside a command substitution with no
# stdin redirect, so the hook inherited the CALLER's stdin. That hook reads its
# envelope with a bare `cat`, which cannot see EOF while any writer holds the
# pipe open — so the suite finished in 1 second against `/dev/null` and blocked
# FOREVER against an open pipe or socket. Three more suites carried the same
# shape against two other unbounded readers: the fake `glab` stubs in
# `test-bl032-gitlab-free-approvals-attestation.sh` and
# `test-gitlab-ci-status-stderr-approvals.sh` (`[ ! -t 0 ]` then a bare `cat`),
# and `scripts/check-pr-review.sh`'s pre-push ref loop, reached unredirected
# from `test-pr-review-gate.sh` (`[ ! -t 0 ]` then `while read`).
#
# All four are children of `tests/full-project-test-suite.sh`, which
# CONTRIBUTING.md names as the way to validate a checkout — so a contributor
# running it from a tool, agent harness, CI shim or editor that leaves stdin
# open hung with no diagnostic and no timeout.
#
# WHY THE FIX IS AT THE CALL SITES, NOT IN THE READERS. The read cannot simply
# be made lazy the way `## BL-202:` made `session-intake-check.sh`'s:
# `session-test-gate-check.sh` needs `source` on EVERY invocation to choose
# between a destructive re-init of `.claude/tool-usage.json` and a merge, so
# there is no silent path to hide the read behind. The only other option is a
# BOUNDED read, and for both readers that trades a deterministic hang in tests
# for a silent correctness loss in production: a slow envelope would read as
# `startup` and take the DESTRUCTIVE branch (A7 pins this), and a slow ref list
# would let `check-pr-review.sh` wave through commits it never checked. The
# redirect is also the tree's existing idiom — `test-session-test-gate-check-
# merge.sh`, `test-validate-counter-sanitizer.sh` and most of
# `test-pr-review-gate.sh` itself already pass `</dev/null`; the fixed sites
# were the outliers that forgot it.
#
# WHAT THIS SUITE ASSERTS.
#   A1  the probe FLAGS a reader that provably blocks (detector control)
#   A1b the probe CLEARS a runner that cannot block (detector control)
#   A2  test-intake-wizard-fixes.sh               — stdin parity
#   A3  test-bl032-gitlab-free-approvals-...sh    — stdin parity
#   A4  every fixed call site still carries the redirect and its marker
#   A5  MUTATION — strip A2's redirect, and A2's probe must catch it
#   A6  MUTATION — strip A3's redirects, and A3's probe must catch it
#   A7  the hook still honours a piped SessionStart envelope (merge, not wipe)
#   A8  test-gitlab-ci-status-stderr-approvals.sh — stdin parity
#   A9  test-pr-review-gate.sh                    — stdin parity
#
# A2/A3/A8/A9 assert PARITY, not green: `test-pr-review-gate.sh` has 18 case
# failures on `main` that are none of BL-276's business, and a case demanding
# rc=0 would be asserting someone else's bug. What BL-276 owns is that the
# stdin shape changes NOTHING — same exit status, same number of case verdicts.
#
# Every bound here is enforced by `timeout`/`gtimeout` when one is on PATH and
# by a poll loop over a done-file when neither is (macOS ships neither unless
# coreutils is installed). Both paths are bounded, so this suite cannot itself
# hang; where a bound cannot be established at all the affected case FAILS.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INTAKE_SUITE="$SCRIPT_DIR/test-intake-wizard-fixes.sh"
GITLAB_SUITE="$SCRIPT_DIR/test-bl032-gitlab-free-approvals-attestation.sh"
CISTATUS_SUITE="$SCRIPT_DIR/test-gitlab-ci-status-stderr-approvals.sh"
PRGATE_SUITE="$SCRIPT_DIR/test-pr-review-gate.sh"
HOOK="$REPO_ROOT/scripts/session-test-gate-check.sh"
MARKER="BL-276-STDIN-REDIRECT"

# Observed honest runtimes: intake ~2s, bl032 ~1s, ci-status ~3s, pr-gate ~15s.
# 120s is 8x the slowest, and is only ever paid in full by a run that is
# genuinely stuck, so it costs a healthy tree nothing. The mutation cases block
# by construction, so their bound IS the cost of the case: 15s, still >7x the
# suites they mutate. That keeps the whole suite around 80s, which matters —
# the `rest` shard of the unit lane has been CANCELLED at its 12-minute cap
# before (see the BL-190 pin notes in .github/workflows/tests.yml).
BOUND_LIVE=120
BOUND_MUT=15

PASSED=0
FAILED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }

TOPTMP=$(mktemp -d)
MUTANTS=""
cleanup() {
  local m
  for m in $MUTANTS; do rm -f "$m"; done
  rm -rf "$TOPTMP"
}
trap cleanup EXIT

# ── the bound ────────────────────────────────────────────────────────
# macOS has no timeout(1); coreutils installs it as gtimeout, and its gnubin
# shim may also expose it as timeout. Take whichever is present. When NEITHER
# is, fall back to a poll loop over a done-file — that needs no external tool,
# so absence degrades the mechanism, never the verdict.
TIMEOUT_BIN=""
for _c in timeout gtimeout; do
  if command -v "$_c" >/dev/null 2>&1; then TIMEOUT_BIN="$_c"; break; fi
done
echo "bound mechanism: ${TIMEOUT_BIN:-poll-loop (no timeout/gtimeout on PATH)}"

# probe <tag> <bound-seconds> <script-path> <stdin-mode>
#
# stdin-mode `open`    — a FIFO that a writer holds OPEN while sending nothing,
#                        the exact shape that starves a bare `cat` of EOF.
# stdin-mode `devnull` — the reference shape CI and a terminal-less runner give.
#
# Waits at most <bound-seconds>. Sets PR_HUNG (1 = did not finish in time),
# PR_RC, PR_OUT (path to combined output). Returns 2 if the probe could not be
# built at all, which every caller must treat as a FAILURE, never a skip.
PR_HUNG=0; PR_RC=""; PR_OUT=""
probe() {
  local tag="$1"
  local bound="$2"
  local script="$3"
  local mode="$4"
  local fifo="$TOPTMP/$tag.fifo"
  local done_f="$TOPTMP/$tag.done"
  local stdin_path="/dev/null"
  local wpid=""
  local rpid=""
  local waited=0
  PR_OUT="$TOPTMP/$tag.out"; PR_HUNG=0; PR_RC=""
  rm -f "$fifo" "$done_f" "$PR_OUT"
  if [ "$mode" = "open" ]; then
    mkfifo "$fifo" 2>/dev/null || return 2
    # The writer outlives the bound, so a real block can never be masked by the
    # pipe closing early and handing the reader an EOF it was not meant to see.
    ( exec 9>"$fifo"; sleep $((bound + 10)) ) >/dev/null 2>&1 &
    wpid=$!
    stdin_path="$fifo"
  fi
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$bound" bash "$script" <"$stdin_path" >"$PR_OUT" 2>&1
    PR_RC=$?
    [ "$PR_RC" -eq 124 ] && PR_HUNG=1
  else
    ( bash "$script" <"$stdin_path" >"$PR_OUT" 2>&1; printf '%s\n' "$?" >"$done_f" ) >/dev/null 2>&1 &
    rpid=$!
    # 10 polls/second, so `bound` seconds is bound*10 iterations.
    while [ ! -f "$done_f" ] && [ "$waited" -lt $((bound * 10)) ]; do
      sleep 0.1
      waited=$((waited + 1))
    done
    if [ -f "$done_f" ]; then
      PR_RC=$(head -1 "$done_f" 2>/dev/null)
    else
      PR_HUNG=1
      PR_RC=""
    fi
    kill "$rpid" 2>/dev/null || true
    wait "$rpid" 2>/dev/null || true
  fi
  if [ -n "$wpid" ]; then
    kill "$wpid" 2>/dev/null || true
    wait "$wpid" 2>/dev/null || true
  fi
  rm -f "$fifo"
  return 0
}

# How many case verdicts a run emitted. Every suite here prints "  [PASS] ..."
# or "  [FAIL] ...", so this measures how far a run actually got.
verdicts() {
  local n
  n=$(grep -cE '^[[:space:]]*\[(PASS|FAIL)\]' "$1" 2>/dev/null) || n=0
  case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# parity_case <case-id> <suite> <mechanism-note>
# Sets PC_OK=yes|no and PC_N (verdicts seen on the open-stdin run), which the
# mutation cases read as their baseline.
PC_OK="no"; PC_N=0
parity_case() {
  local id="$1"
  local suite="$2"
  local note="$3"
  local ref_rc ref_n open_rc open_n setup
  PC_OK="no"; PC_N=0

  probe "$id-ref" "$BOUND_LIVE" "$suite" devnull
  setup=$?
  if [ "$setup" -ne 0 ]; then
    fail_ "$id" "could not build the reference probe — failing closed rather than skipping"
    return
  fi
  if [ "$PR_HUNG" -ne 0 ]; then
    fail_ "$id" "the /dev/null REFERENCE run did not finish within ${BOUND_LIVE}s — this case compares the two stdin shapes and cannot do that without a reference; investigate the suite's runtime before reading anything into BL-276"
    return
  fi
  ref_rc="$PR_RC"
  ref_n=$(verdicts "$PR_OUT")

  probe "$id-open" "$BOUND_LIVE" "$suite" open
  setup=$?
  open_n=$(verdicts "$PR_OUT")
  PC_N="$open_n"
  if [ "$setup" -ne 0 ]; then
    fail_ "$id" "mkfifo unavailable — the held-open-stdin probe cannot be built on this host; failing closed"
    return
  fi
  open_rc="$PR_RC"
  if [ "$PR_HUNG" -ne 0 ]; then
    fail_ "$id" "with a writer holding stdin open the suite did NOT finish within ${BOUND_LIVE}s, emitting $open_n of the reference run's $ref_n case verdicts — $note"
    return
  fi
  if [ "$ref_n" -lt 1 ]; then
    fail_ "$id" "the reference run emitted no case verdicts at all, so parity with it proves nothing — the suite did not actually run"
    return
  fi
  if [ "$open_rc" != "$ref_rc" ] || [ "$open_n" != "$ref_n" ]; then
    fail_ "$id" "stdin shape changed the OUTCOME: /dev/null gave rc=$ref_rc with $ref_n verdicts, a held-open pipe gave rc=$open_rc with $open_n — the suite reads the caller's stdin somewhere and its result depends on what was there"
    return
  fi
  PC_OK="yes"
  pass "$id (rc=$open_rc and $open_n verdicts on a held-open pipe, identical to /dev/null — the caller's stdin changes nothing)"
}

# ════════════════════════════════════════════════════════════════════
# A1 / A1b — the detector itself, both directions.
# Without A1 every parity pass below would be unfalsifiable: a probe that can
# never report a block reports every suite healthy. Without A1b a probe that
# reports EVERYTHING blocked would still let the mutation cases through. Both
# controls run against the same FIFO shape as the real cases.
# ════════════════════════════════════════════════════════════════════
echo ""
echo "A1-probe-flags-a-real-block: a blocking reader on a held-open pipe must be flagged"
A1_CTRL="$TOPTMP/a1-blocking-reader.sh"
printf '#!/usr/bin/env bash\nexec cat >/dev/null\n' > "$A1_CTRL"
probe a1 5 "$A1_CTRL" open
a1_setup=$?
if [ "$a1_setup" -ne 0 ]; then
  fail_ "A1-probe-flags-a-real-block" "mkfifo unavailable — the bounded probe cannot be built on this host, so no case in this suite can be trusted; failing closed rather than skipping"
elif [ "$PR_HUNG" -ne 1 ]; then
  fail_ "A1-probe-flags-a-real-block" "DETECTOR CONTROL FAILED — a plain blocking \`cat\` on the held-open pipe was NOT flagged (hung=$PR_HUNG rc=$PR_RC); this probe cannot detect a block, so every green case below would be meaningless"
else
  pass "A1-probe-flags-a-real-block (a bare \`cat\` reading a pipe no one closes is reported hung — the detector has teeth)"
fi

echo ""
echo "A1b-probe-clears-a-non-blocker: a runner that cannot block must come back clean"
A1B_CTRL="$TOPTMP/a1b-immediate.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$A1B_CTRL"
probe a1b 5 "$A1B_CTRL" open
a1b_setup=$?
if [ "$a1b_setup" -ne 0 ]; then
  fail_ "A1b-probe-clears-a-non-blocker" "mkfifo unavailable — cannot build the probe; failing closed"
elif [ "$PR_HUNG" -ne 0 ] || [ "$PR_RC" != "0" ]; then
  fail_ "A1b-probe-clears-a-non-blocker" "DETECTOR CONTROL FAILED — a runner that never touches stdin was reported hung=$PR_HUNG rc=$PR_RC; a probe that flags everything proves nothing"
else
  pass "A1b-probe-clears-a-non-blocker (a runner that never reads stdin returns rc=0 under the same held-open pipe — the detector is two-sided)"
fi

# ════════════════════════════════════════════════════════════════════
# A2 / A3 / A8 / A9 — the defect itself, one case per affected suite.
# ════════════════════════════════════════════════════════════════════
echo ""
echo "A2-intake-wizard-stdin-parity: tests/test-intake-wizard-fixes.sh"
parity_case "A2-intake-wizard-stdin-parity" "$INTAKE_SUITE" \
  "it invokes the SessionStart hook inside \$( ) with no redirect, so the hook's bare \`cat\` never sees EOF"
A2_OK="$PC_OK"; A2_BASELINE="$PC_N"

echo ""
echo "A3-bl032-gitlab-stdin-parity: tests/test-bl032-gitlab-free-approvals-attestation.sh"
parity_case "A3-bl032-gitlab-stdin-parity" "$GITLAB_SUITE" \
  "its fake \`glab\` drains a non-TTY stdin with a bare \`cat\`, and the driver call inherits the caller's"
A3_OK="$PC_OK"; A3_BASELINE="$PC_N"

echo ""
echo "A8-ci-status-stdin-parity: tests/test-gitlab-ci-status-stderr-approvals.sh"
parity_case "A8-ci-status-stdin-parity" "$CISTATUS_SUITE" \
  "same fake-\`glab\` drain as A3, reached from five unredirected driver calls"

echo ""
echo "A9-pr-review-gate-stdin-parity: tests/test-pr-review-gate.sh"
parity_case "A9-pr-review-gate-stdin-parity" "$PRGATE_SUITE" \
  "scripts/check-pr-review.sh reads the pre-push ref list with an unbounded \`while read\` whenever stdin is not a TTY"

# ════════════════════════════════════════════════════════════════════
# A4 — structure. The parity cases would also go green if someone deleted the
# offending assertions outright, so pin WHERE the fix lives. The marker must
# sit ON the invocation line: a file-wide count would be satisfied by this
# file's own header citing it.
# ════════════════════════════════════════════════════════════════════
echo ""
echo "A4-call-sites-carry-the-redirect: every marked invocation redirects stdin"
A4_BAD=""
A4_TOTAL=0
for _f in "$INTAKE_SUITE" "$GITLAB_SUITE" "$CISTATUS_SUITE" "$PRGATE_SUITE"; do
  _hits=$(grep -c "$MARKER" "$_f" 2>/dev/null) || _hits=0
  case "${_hits:-}" in ''|*[!0-9]*) _hits=0 ;; esac
  if [ "$_hits" -lt 1 ]; then
    A4_BAD="${A4_BAD}${A4_BAD:+; }$(basename "$_f"): no $MARKER site at all"
    continue
  fi
  A4_TOTAL=$((A4_TOTAL + _hits))
  # Every marked line must also carry the redirect. grep -v leaves the
  # offenders; a zero count is the healthy state.
  _unredirected=$(grep "$MARKER" "$_f" 2>/dev/null | grep -cv '</dev/null') || _unredirected=0
  case "${_unredirected:-}" in ''|*[!0-9]*) _unredirected=0 ;; esac
  if [ "$_unredirected" -ne 0 ]; then
    A4_BAD="${A4_BAD}${A4_BAD:+; }$(basename "$_f"): $_unredirected of $_hits marked line(s) lost their </dev/null"
  fi
done
if [ -n "$A4_BAD" ]; then
  fail_ "A4-call-sites-carry-the-redirect" "$A4_BAD — the marker exists so a future edit to these lines cannot silently drop the redirect and reopen BL-276"
elif [ "$A4_TOTAL" -ne 12 ]; then
  fail_ "A4-call-sites-carry-the-redirect" "found $A4_TOTAL marked call sites across the four suites; BL-276 fixed TWELVE (intake-wizard 1, bl032 2, ci-status 5, pr-review-gate 4) — a different count means a site was added without a measurement behind it, or removed without one"
else
  pass "A4-call-sites-carry-the-redirect ($A4_TOTAL marked invocations across four suites, every one of them redirecting stdin)"
fi

# ════════════════════════════════════════════════════════════════════
# A5 / A6 — MUTATION. Strip the redirect back off and require the parity probe
# to catch it. Without these, the parity cases could be passing because nothing
# in those suites reads stdin any more, rather than because the redirect works.
#
# A mutant must live in tests/ — every suite derives REPO_ROOT from its own
# dirname, so a copy anywhere else resolves the wrong tree and fails for an
# unrelated reason. The leading dot keeps it out of every `tests/*.sh` glob,
# and the EXIT trap removes it. The path is registered for cleanup BEFORE
# anything writes to it, and `mutate` is called as a plain command rather than
# in a substitution, so the registration cannot land in a subshell and strand
# the file.
# ════════════════════════════════════════════════════════════════════
mutant_path() { printf '%s' "$SCRIPT_DIR/.bl276-mutant-$1.$$.sh"; }
mutate() {  # <source-suite> <dst>
  sed "/$MARKER/ s|</dev/null ||" "$1" > "$2" 2>/dev/null || { rm -f "$2"; return 1; }
  return 0
}

mutation_case() {  # <case-id> <suite> <baseline-ok> <baseline-verdicts> <tag> <caught-by>
  local id="$1"
  local suite="$2"
  local base_ok="$3"
  local base_n="$4"
  local tag="$5"
  local caught_by="$6"
  local dst left setup n
  if [ "$base_ok" != "yes" ]; then
    fail_ "$id" "$caught_by is already RED, so there is no working redirect to remove — a mutation proof is undefined until it passes; fix $caught_by first"
    return
  fi
  dst=$(mutant_path "$tag")
  MUTANTS="$MUTANTS $dst"
  if ! mutate "$suite" "$dst" || [ ! -s "$dst" ]; then
    fail_ "$id" "could not write the mutant — the mutation proof did not run, so $caught_by's power is unestablished"
    return
  fi
  left=$(grep "$MARKER" "$dst" 2>/dev/null | grep -c '</dev/null') || left=0
  case "${left:-}" in ''|*[!0-9]*) left=0 ;; esac
  if [ "$left" -ne 0 ]; then
    fail_ "$id" "the mutation left $left redirect(s) standing on marked lines — it did not actually remove the fix, so catching it would prove nothing"
    return
  fi
  probe "$tag" "$BOUND_MUT" "$dst" open
  setup=$?
  n=$(verdicts "$PR_OUT")
  if [ "$setup" -ne 0 ]; then
    fail_ "$id" "mkfifo unavailable — cannot build the probe; failing closed"
  elif [ "$PR_HUNG" -ne 1 ]; then
    fail_ "$id" "MUTANT SURVIVED — with the redirect stripped the suite still finished within ${BOUND_MUT}s (rc=$PR_RC, $n verdicts); $caught_by therefore cannot fail, and the redirect it guards is not what keeps the suite alive"
  elif [ "$n" -ge "$base_n" ]; then
    fail_ "$id" "the mutant was flagged hung but had already emitted $n verdicts against the fixed run's $base_n — it did not stall EARLIER, so the flag is a slow host, not the stdin block"
  else
    pass "$id (stripping </dev/null stalls the suite at $n of $base_n verdicts and the probe reports it hung — $caught_by is the case that catches this)"
  fi
}

echo ""
echo "A5-mutation-intake: removing the redirect must be caught by A2"
mutation_case "A5-mutation-intake" "$INTAKE_SUITE" "$A2_OK" "$A2_BASELINE" a5 \
  "A2-intake-wizard-stdin-parity"

echo ""
echo "A6-mutation-gitlab: removing the redirects must be caught by A3"
mutation_case "A6-mutation-gitlab" "$GITLAB_SUITE" "$A3_OK" "$A3_BASELINE" a6 \
  "A3-bl032-gitlab-stdin-parity"

# ════════════════════════════════════════════════════════════════════
# A7 — the thing the fix must NOT break. BL-276 deliberately left
# session-test-gate-check.sh alone, because its envelope read decides between
# a destructive re-init and a merge on every invocation and cannot be bounded
# without risking the wrong branch. This case keeps that contract live: a
# piped `compact` envelope must still reach the merge branch and preserve
# in-flight counters. If someone ever "fixes" BL-276 inside the hook with a
# timed read, this is what goes red under load.
# ════════════════════════════════════════════════════════════════════
echo ""
echo "A7-hook-still-honours-a-piped-envelope: the merge branch survives the call-site fix"
if ! command -v jq >/dev/null 2>&1; then
  fail_ "A7-hook-still-honours-a-piped-envelope" "jq is absent, so the envelope contract cannot be read back — this case must not report a pass it did not earn"
else
  A7_PROJ="$TOPTMP/a7proj"
  mkdir -p "$A7_PROJ/.claude"
  cat > "$A7_PROJ/.claude/tool-usage.json" <<'JSON'
{
  "session_id": "2026-09-13T00:00:00Z",
  "calls": [
    {"tool": "context7", "ts": "2026-09-13T00:01:00Z"},
    {"tool": "qdrant_find", "ts": "2026-09-13T00:02:00Z"}
  ],
  "commits_since_last_context7": 4,
  "qdrant_find_called": true,
  "qdrant_store_called": true,
  "context7_called": true,
  "mcp_gate_satisfied": true,
  "mcp_requirements": {
    "qdrant_required": true,
    "context7_required": true,
    "additional_required": []
  }
}
JSON
  ( cd "$A7_PROJ" && printf '{"hook_event_name":"SessionStart","source":"compact"}' \
      | bash "$HOOK" >/dev/null 2>&1 ) || true
  A7_CALLS=$(jq '.calls | length' "$A7_PROJ/.claude/tool-usage.json" 2>/dev/null) || A7_CALLS=""
  A7_COUNTER=$(jq '.commits_since_last_context7' "$A7_PROJ/.claude/tool-usage.json" 2>/dev/null) || A7_COUNTER=""
  if [ "$A7_CALLS" = "2" ] && [ "$A7_COUNTER" = "4" ]; then
    pass "A7-hook-still-honours-a-piped-envelope (a \`compact\` envelope on a pipe still takes the merge branch: 2 calls and counter 4 preserved — the hook's unbounded read is intact, which is why BL-276 was fixed at the call sites)"
  else
    fail_ "A7-hook-still-honours-a-piped-envelope" "after a piped \`compact\` envelope the ledger reads calls=$A7_CALLS counter=$A7_COUNTER, expected 2 and 4 — the hook took the DESTRUCTIVE startup branch, which is exactly what a bounded or short-circuited envelope read causes and what BL-276 refused to risk"
  fi
fi

echo ""
echo "==============================="
echo "Passed: $PASSED   Failed: $FAILED"
echo "==============================="
[ "$FAILED" -eq 0 ]
