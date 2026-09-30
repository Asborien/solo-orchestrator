#!/usr/bin/env bash
# tests/test-record-claude-commit.sh — BL-030 Claude-commit recorder tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/scripts/hooks/record-claude-commit.sh"

PASSED=0
FAILED=0
pass() { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }

# The PostToolUse hook contract for Claude Code: stdin is a JSON object
# with at least { "tool_input": {...}, "tool_response": {...} }. We expect
# the hook to inspect tool_input.command and only act on git-commit calls
# that succeeded.

setup() {
  TMP=$(mktemp -d)
  mkdir -p "$TMP/.claude"
  ( cd "$TMP"
    git init -q
    git config user.email "test@test.local"
    git config user.name "test"
    echo "first" > f.txt && git add f.txt && git commit -qm "first" 2>/dev/null
  )
  SHA=$(cd "$TMP" && git rev-parse HEAD)
}
teardown() { rm -rf "$TMP"; }

# T1: hook records a successful git commit.
echo "T1: PostToolUse hook records SHA of a successful git commit"
setup
if [ ! -f "$HOOK" ]; then
  fail_ "T1" "hook script missing (RED expected before impl)"
else
  cd "$TMP"
  cat <<EOF | bash "$HOOK" >/dev/null 2>&1
{"tool_input":{"command":"git commit -m 'feat: x'"},"tool_response":{"exit_code":0}}
EOF
  if [ -f "$TMP/.claude/claude-commits.jsonl" ] && \
     jq -e --arg sha "$SHA" '.sha == $sha' < "$TMP/.claude/claude-commits.jsonl" >/dev/null 2>&1; then
    pass "T1"
  else
    fail_ "T1" "claude-commits.jsonl missing or SHA mismatch"
  fi
fi
teardown

# T2: hook does NOT record a non-git-commit tool call.
echo "T2: PostToolUse hook ignores non-commit Bash calls"
setup
if [ ! -f "$HOOK" ]; then
  fail_ "T2" "hook script missing"
else
  cd "$TMP"
  cat <<EOF | bash "$HOOK" >/dev/null 2>&1
{"tool_input":{"command":"ls -la"},"tool_response":{"exit_code":0}}
EOF
  if [ ! -f "$TMP/.claude/claude-commits.jsonl" ]; then
    pass "T2"
  else
    fail_ "T2" "ledger should not exist for ls call"
  fi
fi
teardown

# T3: hook does NOT record a failed git commit.
echo "T3: PostToolUse hook ignores failed git commits"
setup
if [ ! -f "$HOOK" ]; then
  fail_ "T3" "hook script missing"
else
  cd "$TMP"
  cat <<EOF | bash "$HOOK" >/dev/null 2>&1
{"tool_input":{"command":"git commit -m 'feat: x'"},"tool_response":{"exit_code":1}}
EOF
  if [ ! -f "$TMP/.claude/claude-commits.jsonl" ]; then
    pass "T3"
  else
    fail_ "T3" "ledger should not exist for failed commit"
  fi
fi
teardown

# T4: hook is append-only — second commit appends a row.
echo "T4: PostToolUse hook appends to existing ledger"
setup
if [ ! -f "$HOOK" ]; then
  fail_ "T4" "hook script missing"
else
  cd "$TMP"
  cat <<EOF | bash "$HOOK" >/dev/null 2>&1
{"tool_input":{"command":"git commit -m 'first'"},"tool_response":{"exit_code":0}}
EOF
  echo "second" > g.txt && git add g.txt && git commit -qm "second" 2>/dev/null
  cat <<EOF | bash "$HOOK" >/dev/null 2>&1
{"tool_input":{"command":"git commit -m 'second'"},"tool_response":{"exit_code":0}}
EOF
  count=$(wc -l < "$TMP/.claude/claude-commits.jsonl" | tr -d ' ')
  if [ "$count" = "2" ]; then pass "T4"; else fail_ "T4" "expected 2 rows, got $count"; fi
fi
teardown

# T5: hook is silent on missing .claude/ (project not initialized).
echo "T5: PostToolUse hook is a no-op when .claude/ does not exist"
TMP=$(mktemp -d)
( cd "$TMP" && git init -q && git config user.email "t@t.l" && git config user.name "t"
  echo x > x && git add x && git commit -qm x )
if [ ! -f "$HOOK" ]; then
  fail_ "T5" "hook script missing"
else
  cd "$TMP"
  cat <<EOF | bash "$HOOK" >/dev/null 2>&1
{"tool_input":{"command":"git commit -m 'x'"},"tool_response":{"exit_code":0}}
EOF
  if [ ! -f "$TMP/.claude/claude-commits.jsonl" ]; then
    pass "T5"
  else
    fail_ "T5" "ledger created in uninitialized project"
  fi
fi
rm -rf "$TMP"

# T6-T9: BL-020 sibling — audit finding `specs-plans-bl029-bl030-5`.
# Pre-fix the classifier used a naive substring match (`*"git commit"*`),
# which false-positives on innocuous commands whose argv contains the
# literal `git commit` (echo strings, grep search patterns, etc.). Each
# false-positive polluted the ledger with HEAD-at-the-time as a spurious
# Claude-issued entry. Mirrors the BL-020 fix that landed in PR #53 for
# `scripts/pre-commit-gate.sh`.

# T6: quote-preceded false-positive must NOT record. The literal `git commit`
# appears immediately after a `"` in a grep search pattern (the regex
# `[^"']` rejects quote-preceded matches; start-of-line is the only other
# anchor and doesn't apply here).
echo "T6: PostToolUse hook ignores 'git commit' inside a quoted grep pattern (piped)"
setup
cd "$TMP"
cat <<'EOF' | bash "$HOOK" >/dev/null 2>&1
{"tool_input":{"command":"cat scripts/pre-commit-gate.sh | grep \"git commit\""},"tool_response":{"exit_code":0}}
EOF
if [ ! -f "$TMP/.claude/claude-commits.jsonl" ]; then
  pass "T6"
else
  fail_ "T6" "ledger created for 'grep \"git commit\"' (quote-preceded false-positive)"
fi
teardown

# T7: grep search-string false-positive must NOT record.
echo "T7: PostToolUse hook ignores 'git commit' inside a grep/rg search pattern"
setup
cd "$TMP"
cat <<'EOF' | bash "$HOOK" >/dev/null 2>&1
{"tool_input":{"command":"rg \"git commit\" docs/"},"tool_response":{"exit_code":0}}
EOF
if [ ! -f "$TMP/.claude/claude-commits.jsonl" ]; then
  pass "T7"
else
  fail_ "T7" "ledger created for 'rg \"git commit\" docs/' (search-string false-positive)"
fi
teardown

# T8: cross-cmd-chain happy path — preceded by `&&`, not at line start.
echo "T8: PostToolUse hook DOES record a chained 'cd foo && git commit ...'"
setup
cd "$TMP"
cat <<EOF | bash "$HOOK" >/dev/null 2>&1
{"tool_input":{"command":"cd $TMP && git commit --allow-empty -m 'chained'"},"tool_response":{"exit_code":0}}
EOF
if [ -f "$TMP/.claude/claude-commits.jsonl" ] && \
   jq -e --arg sha "$SHA" '.sha == $sha' < "$TMP/.claude/claude-commits.jsonl" >/dev/null 2>&1; then
  pass "T8"
else
  fail_ "T8" "chained 'cd && git commit' should have been recorded"
fi
teardown

# T9: --amend handling — option C: record amended commits as a fresh entry.
# Rationale: keeping the original entry as an orphan SHA is fine (the ledger
# is append-only). Recording the new HEAD ensures the out-of-band detector
# sees the amended SHA in the ledger and classifies it as Claude-issued
# rather than user-terminal. No special-casing needed in the hook — the
# normal flow handles --amend correctly.
echo "T9: PostToolUse hook records 'git commit --amend' as a fresh ledger entry (option C)"
setup
cd "$TMP"
# Pre-seed: record the initial commit.
cat <<EOF | bash "$HOOK" >/dev/null 2>&1
{"tool_input":{"command":"git commit -m 'first'"},"tool_response":{"exit_code":0}}
EOF
ORIG_SHA="$SHA"
# Now amend: HEAD SHA changes.
( cd "$TMP" && git commit --amend --no-edit -q 2>/dev/null )
AMENDED_SHA=$(cd "$TMP" && git rev-parse HEAD)
cat <<EOF | bash "$HOOK" >/dev/null 2>&1
{"tool_input":{"command":"git commit --amend --no-edit"},"tool_response":{"exit_code":0}}
EOF
if [ -f "$TMP/.claude/claude-commits.jsonl" ] && \
   [ "$(wc -l < "$TMP/.claude/claude-commits.jsonl" | tr -d ' ')" = "2" ] && \
   grep -q "$AMENDED_SHA" "$TMP/.claude/claude-commits.jsonl" && \
   grep -q "$ORIG_SHA" "$TMP/.claude/claude-commits.jsonl"; then
  pass "T9"
else
  fail_ "T9" "expected 2 entries (original + amended SHAs); got: $(cat "$TMP/.claude/claude-commits.jsonl" 2>/dev/null)"
fi
teardown

# T10-T12: BL-316. Claude Code's Bash tool_response carries stdout, stderr,
# interrupted, isImage and noOutputExpected, and no exit_code. Success is the
# event itself: a failed call fires PostToolUseFailure, never PostToolUse
# (the measurement recorded in session-mcp-gate.sh's BL-233 header). T1 to T9
# feed a synthetic exit_code envelope the host never sends, which is how a
# recorder that never recorded passed.

# T10: the real PostToolUse envelope, with no exit_code, records the commit.
echo "T10: PostToolUse hook records a commit from the real Claude Code envelope (no exit_code)"
setup
cd "$TMP"
cat <<'EOF' | bash "$HOOK" >/dev/null 2>&1
{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m 'feat: x'"},"tool_response":{"stdout":"[main abc1234] feat: x","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false}}
EOF
if [ -f "$TMP/.claude/claude-commits.jsonl" ] && \
   jq -e --arg sha "$SHA" '.sha == $sha' < "$TMP/.claude/claude-commits.jsonl" >/dev/null 2>&1; then
  pass "T10"
else
  fail_ "T10" "the host's real envelope carries no exit_code; the commit was not recorded"
fi
teardown

# T11: a PostToolUseFailure envelope never records.
echo "T11: hook ignores a git commit reported through PostToolUseFailure"
setup
cd "$TMP"
cat <<'EOF' | bash "$HOOK" >/dev/null 2>&1
{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"git commit -m nothing"},"error":"Exit code 1\nOn branch main\nnothing to commit, working tree clean","is_interrupt":false,"duration_ms":22}
EOF
if [ ! -f "$TMP/.claude/claude-commits.jsonl" ]; then
  pass "T11"
else
  fail_ "T11" "a failed commit (PostToolUseFailure) was recorded"
fi
teardown

# T12: an interrupted call never records, even on PostToolUse.
echo "T12: hook ignores an interrupted git commit"
setup
cd "$TMP"
cat <<'EOF' | bash "$HOOK" >/dev/null 2>&1
{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m 'feat: x'"},"tool_response":{"stdout":"","stderr":"","interrupted":true,"isImage":false,"noOutputExpected":false}}
EOF
if [ ! -f "$TMP/.claude/claude-commits.jsonl" ]; then
  pass "T12"
else
  fail_ "T12" "an interrupted commit was recorded"
fi
teardown

# T13: the vendor's documented PostToolUse example carries tool_response as a
# plain string; a successful commit in that shape still records.
echo "T13: hook records a commit whose tool_response is a plain string"
setup
cd "$TMP"
cat <<'EOF' | bash "$HOOK" >/dev/null 2>&1
{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m 'feat: x'"},"tool_response":"[main abc1234] feat: x"}
EOF
if [ -f "$TMP/.claude/claude-commits.jsonl" ]; then
  pass "T13"
else
  fail_ "T13" "a string tool_response on PostToolUse was not recorded"
fi
teardown

# T14: any event other than PostToolUse is skipped, not only
# PostToolUseFailure. A guard narrowed to the failure event would record this.
echo "T14: hook ignores a git commit reported under any other event"
setup
cd "$TMP"
cat <<'EOF' | bash "$HOOK" >/dev/null 2>&1
{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m 'feat: x'"}}
EOF
if [ ! -f "$TMP/.claude/claude-commits.jsonl" ]; then
  pass "T14"
else
  fail_ "T14" "a commit reported under PreToolUse was recorded"
fi
teardown

# M1-M3: mutation proofs for BL-316's marked lines. Each mutant is one line
# changed in a copy of the hook, must still parse, and must flip exactly the
# case that line exists for, in a fresh fixture. A guard whose removal no case
# notices is not tested.
_bl316_mutant() {  # $1 label, $2 perl program, $3 envelope, $4 expect: record|none
  local label="$1" prog="$2" envelope="$3" expect="$4" mdir mhook changed got
  mdir=$(mktemp -d)
  mhook="$mdir/record-claude-commit.sh"
  cp "$HOOK" "$mhook"
  perl -i -e "$prog" "$mhook"
  changed=$(diff "$HOOK" "$mhook" | grep -c '^[<>]' || true)
  case "$changed" in ''|*[!0-9]*) changed=0 ;; esac
  if [ "$changed" -lt 1 ] || [ "$changed" -gt 2 ]; then
    fail_ "$label" "mutant changed $changed diff lines; expected one line removed or replaced"
    rm -rf "$mdir"; return
  fi
  if ! bash -n "$mhook" 2>/dev/null; then
    fail_ "$label" "mutant does not parse"
    rm -rf "$mdir"; return
  fi
  setup
  cd "$TMP"
  printf '%s\n' "$envelope" | bash "$mhook" >/dev/null 2>&1
  if [ -f "$TMP/.claude/claude-commits.jsonl" ]; then got=record; else got=none; fi
  if [ "$got" = "$expect" ]; then
    pass "$label"
  else
    fail_ "$label" "mutant gave '$got', expected '$expect': the case does not see this line"
  fi
  teardown
  rm -rf "$mdir"
}

echo "M1: removing # BL-316-EVENT lets a PostToolUseFailure commit record"
_bl316_mutant "M1" 'while (<>) { print unless /# BL-316-EVENT$/ }' \
  '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"git commit -m nothing"},"error":"Exit code 1\nnothing to commit, working tree clean","is_interrupt":false,"duration_ms":22}' record

echo "M2: removing # BL-316-INTERRUPTED lets an interrupted commit record"
_bl316_mutant "M2" 'while (<>) { print unless /# BL-316-INTERRUPTED$/ }' \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m '"'"'x'"'"'"},"tool_response":{"stdout":"","stderr":"","interrupted":true}}' record

echo "M3: restoring the pre-BL-316 exit_code default of 1 drops the real envelope"
_bl316_mutant "M3" 'while (<>) { s/\(\.tool_response\.exit_code \/\/ 0\)/(.tool_response.exit_code \/\/ 1)/; print }' \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m '"'"'x'"'"'"},"tool_response":{"stdout":"ok","stderr":"","interrupted":false}}' none

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
