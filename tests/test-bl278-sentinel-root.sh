#!/usr/bin/env bash
# tests/test-bl278-sentinel-root.sh
#
# `## BL-278:` — THE PENDING-APPROVAL SENTINEL WAS READ FROM THE WRONG REPO.
#
# `pa_check` in scripts/pre-commit-gate.sh runs as a PreToolUse hook and reads
# the BARE RELATIVE LITERAL `.claude/pending-approval.json`. On that path the
# script never changes directory — its only `cd` is inside the TERMINAL_MODE
# branch, which this path does not take — and `CLAUDE_PROJECT_DIR` appears
# nowhere in the file. So the literal resolves against the cwd Claude Code hands
# the hook, the SESSION's project directory, never the repository the
# intercepted commit targets. That is the ABSENCE of root resolution, and it
# cuts both ways:
#
#   * a repository carrying its OWN sentinel is NOT protected when committed to
#     from a session rooted elsewhere — the case docs/builders-guide.md
#     § "Structured Decision Points: The Pending-Approval Sentinel" ships this
#     reader INTO each project to cover, and the one this suite exists to pin
#     (C1, and C1b for a `.cwd` below the repo root);
#   * and a sentinel in the session's project reaches every OTHER repository
#     (C2). That half is UNSTATED in the design and is deliberately left
#     unchanged — see the entry; this suite pins it as-is so a later scope
#     change has to be a decision rather than an accident.
#
# The fix is ADDITIVE: the session-relative read is untouched, a second read
# keyed on the envelope's `.cwd` is added behind it, and an unresolvable `.cwd`
# degrades to exactly today's behaviour (C4, C5).
#
# WHAT THE FIX COVERS, precisely. `.cwd` is the directory Claude is in BEFORE
# the command runs, not the repository the command will run in. So the second
# read fires for exactly one shape: a bare `git commit` issued while `.cwd` is
# inside the repository that owns the sentinel. `cd <target> && git commit` and
# `git -C <target> commit` from elsewhere are NOT covered — that is an open
# residual in the entry, and C6 pins the current behaviour so closing it has
# to flip a case rather than happen by accident.
#
# STRUCTURE: C1/C1b are the discriminators; C2/C3/C5 are controls; C4 is a
# pre-merge compatibility check on the `.cwd`-absent envelope; C6 is a residual
# pin; M0 is the marker; M1/M2 are mutants and name the case that kills each.
#
# HERMETIC: two throwaway git repos under one temp tree, the real gate driven
# over stdin the way Claude Code drives it. No network, no host state.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$REPO_ROOT/scripts/pre-commit-gate.sh"

PASSED=0
FAILED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }

TOPTMP="$(mktemp -d)"
trap 'rm -rf "$TOPTMP"' EXIT INT TERM
newtmp() { mktemp -d "$TOPTMP/fixXXXXXX"; }

[ -f "$GATE" ] || { echo "  [FAIL] setup — $GATE not found"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  [FAIL] setup — jq is required"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }

# Distinctive so the DENY reason can be traced to the sentinel that produced it.
Q_TARGET="BL278-QUESTION-FROM-THE-TARGET-REPO"
Q_SESSION="BL278-QUESTION-FROM-THE-SESSION-REPO"

# mk_repo DIR — a throwaway repo the gate will actually reach pa_check in.
#
# THE ORIGIN REMOTE IS LOAD-BEARING, and the C3 control is what found that out.
# An earlier arm of this same gate (the "no git remote configured" guard, around
# `_is_git_commit "$COMMAND" && ! echo … grep -qE 'git.*remote'`) denies BEFORE
# pa_check is ever called, and it denies on the SESSION repo. Without a remote
# every case in this file "passed" by denying for a reason that had nothing to
# do with sentinels. The URL is a local path that is never contacted — no
# network, and nothing here creates a real remote.
mk_repo() {
  local d="$1"
  mkdir -p "$d/.claude" || return 1
  git -C "$d" init -q . >/dev/null 2>&1 || return 1
  git -C "$d" config user.email "t@example.com" || return 1
  git -C "$d" config user.name "t" || return 1
  git -C "$d" remote add origin "$d/../bl278-not-a-real-remote.git" || return 1
  git -C "$d" remote get-url origin >/dev/null 2>&1 || return 1
  [ -d "$d/.git" ] || return 1
  return 0
}

put_sentinel() {
  jq -nc --arg q "$2" '{question:$q, options:["A1: accept","A2: decline"],
                        recommendation:"A2", offered_at:"2026-09-13T00:00:00Z"}' \
    > "$1/.claude/pending-approval.json"
}

# run_gate <gate> <session-dir> <cwd-or-empty> [command] -> GATE_OUT GATE_ERR GATE_RC
# Drives the gate exactly as a PreToolUse hook: envelope on stdin, cwd = the
# session's project dir. An EMPTY third argument omits `.cwd` entirely, which is
# the pre-schema envelope shape C4 pins. The fourth argument is the intercepted
# command; it defaults to the bare shape every case but C6 uses.
run_gate() {
  local gate="$1" sess="$2" tgt="${3:-}" cmd="${4:-git commit -m wip}" env
  if [ -n "$tgt" ]; then
    env=$(jq -nc --arg c "$tgt" --arg cmd "$cmd" \
          '{session_id:"bl278", hook_event_name:"PreToolUse",
            cwd:$c, tool_name:"Bash", tool_input:{command:$cmd}}')
  else
    env=$(jq -nc --arg cmd "$cmd" \
          '{session_id:"bl278", hook_event_name:"PreToolUse",
            tool_name:"Bash", tool_input:{command:$cmd}}')
  fi
  GATE_OUT="$(newtmp)/out"; GATE_ERR="$GATE_OUT.err"
  # SKIP_LINT=1 is this gate's own documented escape (docs/builders-guide.md
  # § "SKIP_LINT=1 escape hatch"), scoped narrowly to the operator-side lint
  # arms. Those arms run AFTER pa_check and resolve their lints against the
  # FRAMEWORK checkout, not the fixture — so without this every fall-through
  # case re-ran the repo-wide lint sweep and the suite took minutes. It cannot
  # affect what is under test: pa_check is reached before any of them.
  ( cd "$sess" && printf '%s' "$env" | SKIP_LINT=1 bash "$gate" >"$GATE_OUT" 2>"$GATE_ERR" )
  GATE_RC=$?
  return 0
}

denied()      { grep -q '"permissionDecision": "deny"' "$GATE_OUT" 2>/dev/null; }
reason_has()  { grep -qF "$1" "$GATE_OUT" 2>/dev/null; }

# fixture -> FX_SESS (session project) and FX_TGT (an unrelated repo)
mk_pair() {
  local d; d="$(newtmp)"
  FX_SESS="$d/session"; FX_TGT="$d/target"
  mk_repo "$FX_SESS" && mk_repo "$FX_TGT" || return 1
  # the two must be genuinely different repositories, or C1 proves nothing
  [ "$(git -C "$FX_SESS" rev-parse --show-toplevel)" != "$(git -C "$FX_TGT" rev-parse --show-toplevel)" ] || return 1
  return 0
}

echo "=== C — the sentinel is read from the repo the commit targets ==="

# C1 — THE DISCRIMINATOR. The target repo holds a sentinel; the session does
# not. Before the fix nothing fires and the commit sails through.
if ! mk_pair; then
  fail_ "C1 setup" "could not build two distinct fixture repos"
else
  put_sentinel "$FX_TGT" "$Q_TARGET"
  run_gate "$GATE" "$FX_SESS" "$FX_TGT"
  if denied && reason_has "$Q_TARGET"; then
    pass "C1 — a sentinel in the TARGET repo blocks a commit to it from a session rooted elsewhere"
  else
    fail_ "C1" "the target repo's own sentinel did not block (rc=$GATE_RC, output: $(head -c 160 "$GATE_OUT" 2>/dev/null))"
  fi
fi

# C1b — TOPLEVEL RESOLUTION. `.cwd` is a SUBDIRECTORY of the target repo, not
# its root. Every other case hands the gate a repository ROOT, so without this
# one the `rev-parse --show-toplevel` line is never exercised: adversarial
# review's mutant M2 (`root="$c"`) survived the whole suite at 7 / 0. M2 below
# is the same substitution, and this is the case that kills it.
if ! mk_pair; then
  fail_ "C1b setup" "could not build two distinct fixture repos"
else
  put_sentinel "$FX_TGT" "$Q_TARGET"
  if ! mkdir -p "$FX_TGT/deep/er"; then
    fail_ "C1b setup" "could not create a subdirectory in the target repo"
  else
    run_gate "$GATE" "$FX_SESS" "$FX_TGT/deep/er"
    if denied && reason_has "$Q_TARGET"; then
      pass "C1b — with .cwd BELOW the target's root, the target's sentinel still blocks: toplevel resolution is real"
    else
      fail_ "C1b" "a .cwd below the repo root did not reach the target's sentinel (rc=$GATE_RC, output: $(head -c 160 "$GATE_OUT" 2>/dev/null))"
    fi
  fi
fi

# C2 — the session-scoped reach, pinned AS-IS. Unchanged by the fix on purpose;
# if a later change narrows the scope, this case makes that a decision.
if ! mk_pair; then
  fail_ "C2 setup" "could not build fixtures"
else
  put_sentinel "$FX_SESS" "$Q_SESSION"
  run_gate "$GATE" "$FX_SESS" "$FX_TGT"
  if denied && reason_has "$Q_SESSION"; then
    pass "C2 — a sentinel in the SESSION project still blocks (scope left unchanged, deliberately)"
  else
    fail_ "C2" "the session sentinel stopped blocking — the fix is not additive (rc=$GATE_RC)"
  fi
fi

# C3 — no sentinel anywhere: no SENTINEL denial may be produced. Without this
# the suite could pass by denying everything.
#
# Scoped to a sentinel reason on purpose. This gate has many other arms and a
# bare fixture legitimately trips some of them (it was the "no git remote"
# guard that exposed the broken fixture above), so "denied at all" is the wrong
# predicate — it would make this control fire on unrelated enforcement. The
# question strings are unique to this suite, so their ABSENCE is exact.
if ! mk_pair; then
  fail_ "C3 setup" "could not build fixtures"
else
  run_gate "$GATE" "$FX_SESS" "$FX_TGT"
  if reason_has "$Q_TARGET" || reason_has "$Q_SESSION"; then
    fail_ "C3" "the gate produced a sentinel denial with NO sentinel present — every other case is meaningless"
  else
    pass "C3 (control) — with no sentinel in either repo, no sentinel denial is produced"
  fi
fi

# C4 — COMPATIBILITY on the `.cwd`-absent envelope, SCOPED TO THE SENTINEL
# DECISION. Two assertions per case (sentinel present / absent):
#
#   (a) behaviour, against THIS gate alone: with a session sentinel the gate
#       denies on the SESSION's question; with none, no sentinel denial and
#       rc 0. This half can never go vacuous.
#   (b) compatibility, against the PRISTINE origin/main gate on identical
#       fixtures: the pending-approval deny envelope — the stdout line carrying
#       "pending user decision" — is identical, or identically absent.
#
# An earlier cut compared the WHOLE of stdout, stderr and rc with `cmp`. That
# made C4 a permanent tripwire: any later change to any other arm's output on
# a branch fails it for reasons unrelated to BL-278, and once BL-278 is on
# main the comparison is main against itself. Scoping (b) to the one envelope
# this fix touches keeps the pre-merge comparison genuine — origin/main lacks
# the arm, so agreement is evidence — while (a) carries the case after merge.
echo "=== C4 — an envelope without .cwd leaves the sentinel decision as shipped ==="
# THE BASELINE MUST SIT IN A COMPLETE MIRROR OF scripts/, not in a bare temp
# dir. The gate resolves its siblings through SCRIPT_DIR — the
# `--check-commit-ready` call below the `# code-process-checklist-5` comment
# among them — so a lone copy denies with
# "…/process-checklist.sh: No such file or directory" and the comparison
# measures the copy's isolation instead of the gate's behaviour. Measured: bare
# copy 334 bytes of stdout, in-tree 0.
pa_envelope() { grep -F 'pending user decision' "$1" 2>/dev/null; return 0; }
BASE_MIRROR="$(newtmp)/base"
BASE_GATE="$BASE_MIRROR/scripts/pre-commit-gate.sh"
if ! mkdir -p "$BASE_MIRROR" \
   || ! cp -Rp "$REPO_ROOT/scripts" "$BASE_MIRROR/" \
   || ! git -C "$REPO_ROOT" show "origin/main:scripts/pre-commit-gate.sh" > "$BASE_GATE" 2>/dev/null \
   || [ ! -s "$BASE_GATE" ]; then
  fail_ "C4 setup" "could not build the origin/main baseline mirror"
else
  # EACH GATE GETS AN IDENTICAL FRESH FIXTURE AT THE SAME PATH, and that is
  # load-bearing rather than tidiness. Running both gates over one fixture
  # compares run 1 against run 2, not gate against gate: with no sentinel the
  # gate falls through to arms that WRITE project state (ledgers under
  # .claude/), so the first run changes what the second one sees and the
  # comparison fails against an unmodified file. The path is held constant too,
  # because gate output can quote it.
  C4DIR="$TOPTMP/c4"
  c4_build() {
    rm -rf "$C4DIR" || return 1
    mkdir -p "$C4DIR" || return 1
    mk_repo "$C4DIR/session" || return 1
    [ "$1" = "with-sentinel" ] && { put_sentinel "$C4DIR/session" "$Q_SESSION" || return 1; }
    return 0
  }

  c4_fail=""
  for c4_case in with-sentinel without-sentinel; do
    if ! c4_build "$c4_case"; then c4_fail="fixture ($c4_case)"; break; fi
    run_gate "$GATE" "$C4DIR/session" ""
    new_env="$(pa_envelope "$GATE_OUT")"; new_rc="$GATE_RC"
    # (a) behaviour of this gate, on its own
    case "$c4_case" in
      with-sentinel)
        denied && reason_has "$Q_SESSION" || { c4_fail="with .cwd absent the session sentinel did not deny (rc=$new_rc)"; break; } ;;
      without-sentinel)
        if reason_has "$Q_SESSION" || reason_has "$Q_TARGET" || [ -n "$new_env" ] || [ "$new_rc" -ne 0 ]; then
          c4_fail="with .cwd absent and no sentinel, a sentinel denial or non-zero rc appeared (rc=$new_rc)"; break
        fi ;;
    esac

    if ! c4_build "$c4_case"; then c4_fail="fixture rebuild ($c4_case)"; break; fi
    run_gate "$BASE_GATE" "$C4DIR/session" ""
    old_env="$(pa_envelope "$GATE_OUT")"
    # (b) the sentinel envelope, and only that, against origin/main
    [ "$new_env" = "$old_env" ] || { c4_fail="sentinel deny envelope differs from origin/main ($c4_case)"; break; }
  done
  if [ -z "$c4_fail" ]; then
    pass "C4 — with .cwd absent, the sentinel decision is as shipped: session sentinel denies, none denies nothing, envelope identical to origin/main"
  else
    fail_ "C4" "$c4_fail"
  fi
fi

# C5 — an unresolvable `.cwd` (a path that is not a repo) must fail CLOSED to
# today's behaviour, not open a hole.
if ! mk_pair; then
  fail_ "C5 setup" "could not build fixtures"
else
  NOTREPO="$(newtmp)/plain"; mkdir -p "$NOTREPO"
  put_sentinel "$FX_SESS" "$Q_SESSION"
  run_gate "$GATE" "$FX_SESS" "$NOTREPO"
  if denied && reason_has "$Q_SESSION"; then
    pass "C5 — a .cwd that is not a repository degrades to the session-relative read, still blocking"
  else
    fail_ "C5" "an unresolvable .cwd changed the outcome (rc=$GATE_RC)"
  fi
fi

# C6 — RESIDUAL PIN, NOT A CONTROL. `.cwd` is the directory Claude is in BEFORE
# the command runs, so `cd <target> && git commit` issued from the session's
# directory arrives with .cwd = session, and the target's sentinel is never
# consulted. Reviewer probes (2026-09-13), each against the fixed gate:
#   git -C target commit      .cwd=session  -> ALLOW
#   cd target && git commit   .cwd=session  -> ALLOW
#   git commit                .cwd=target   -> DENY
# (`git -C` never reaches pa_check at all: `_is_git_commit` does not match it.)
# This case pins the CURRENT behaviour honestly — rc 0 and no sentinel denial —
# and it is expected to pass on origin/main too. The day someone closes the
# residual by resolving the target from the command text, THIS is the case that
# must be inverted, and that is the point of it: the change becomes a decision.
if ! mk_pair; then
  fail_ "C6 setup" "could not build fixtures"
else
  put_sentinel "$FX_TGT" "$Q_TARGET"
  run_gate "$GATE" "$FX_SESS" "$FX_SESS" "cd $FX_TGT && git commit -m wip"
  if [ "$GATE_RC" -eq 0 ] && ! reason_has "$Q_TARGET" && ! reason_has "$Q_SESSION"; then
    pass "C6 (RESIDUAL PIN) — 'cd <target> && git commit' from the session dir is NOT denied on the target's sentinel; invert this when the residual in ## BL-278: is closed"
  else
    fail_ "C6 (RESIDUAL PIN)" "the target's sentinel was consulted for a cd-and-commit shape (rc=$GATE_RC) — if that is deliberate, the residual is closed: invert this pin, do not delete it"
  fi
fi

echo "=== M — marker and mutation ==="

M_ROOT="# BL-278-SENTINEL-ROOT"
n="$(grep -cF "$M_ROOT" "$GATE" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
if [ "$n" -ge 1 ]; then
  pass "M0 — '$M_ROOT' is present in pre-commit-gate.sh ($n occurrence(s))"
else
  fail_ "M0" "'$M_ROOT' occurs $n times in pre-commit-gate.sh (need at least 1)"
fi

# A real parse check for a mutated gate. `bash -c 'set -n; . file'` is NOT one:
# once `set -n` is active the `. file` that follows is read and never executed,
# so it returns 0 on a file with an unterminated `if` (measured).
parses() { bash -n "$1" 2>/dev/null; }

# M1 — MUTATION. A marker-only landing check is necessary and NOT sufficient
# (MT4's lesson), so this asserts the OPERATIVE TEXT verbatim, syntax-checks the
# mutated file, and only then re-runs C1 against it.
OPERATIVE='sentinel="$(_pa_target_sentinel)" || sentinel=""'
MUT="$(newtmp)/fw"
if ! mkdir -p "$MUT" || ! cp -Rp "$REPO_ROOT/scripts" "$MUT/"; then
  fail_ "M1 setup" "could not mirror scripts/"
else
  tgt="$MUT/scripts/pre-commit-gate.sh"
  before="$(newtmp)/before"; cp "$tgt" "$before"
  # the operative line must exist EXACTLY ONCE before we can claim to remove it
  n_op="$(grep -cF "$OPERATIVE" "$before")"; case "$n_op" in ''|*[!0-9]*) n_op=0 ;; esac
  if [ "$n_op" -ne 1 ]; then
    fail_ "M1 setup" "the operative line occurs $n_op times, need exactly 1 — the assertion is not pinned to real code"
  else
    # neutralise the resolution: the helper is never consulted
    grep -vF "$OPERATIVE" "$before" > "$tgt"
    n_after="$(grep -cF "$OPERATIVE" "$tgt")"; case "$n_after" in ''|*[!0-9]*) n_after=0 ;; esac
    changed="$(diff "$before" "$tgt" | grep -c '^[<>]')"; case "$changed" in ''|*[!0-9]*) changed=0 ;; esac
    if ! parses "$tgt"; then
      fail_ "M1 setup" "the mutated gate does not parse — a mangled substitution must not pass as a landed mutation"
    elif [ "$n_after" -ne 0 ] || [ "$changed" -ne 1 ]; then
      fail_ "M1 setup" "the mutation did not land cleanly (operative lines left=$n_after, changed lines=$changed, want 0 and 1)"
    elif ! mk_pair; then
      fail_ "M1 setup" "could not build the mutant's fixtures"
    else
      put_sentinel "$FX_TGT" "$Q_TARGET"
      run_gate "$tgt" "$FX_SESS" "$FX_TGT"
      # scoped to the TARGET's question, not "denied at all" — the mutated gate
      # still runs every other arm and may legitimately deny for another reason
      if reason_has "$Q_TARGET"; then
        fail_ "M1 (MUTATION)" "removing the resolution changed nothing — C1 may be passing for another reason"
      else
        pass "M1 (MUTATION) — with the target-repo read removed, the target's own sentinel stops blocking: C1 is what catches it"
      fi
    fi
  fi
fi

# M2 — MUTATION, the one adversarial review found surviving. Replace the
# toplevel resolution with `root="$c"`: a `.cwd` at the repo root still resolves
# to the right sentinel, so C1 passes, and only a `.cwd` BELOW the root (C1b)
# tells the two apart. Same landing discipline as M1: operative text exactly
# once before, zero after, exactly one line removed and one added, parse check,
# then C1b's fixture against the mutant.
OPERATIVE2='root=$(git -C "$c" rev-parse --show-toplevel 2>/dev/null) || return 1'
MUT2="$(newtmp)/fw"
if ! mkdir -p "$MUT2" || ! cp -Rp "$REPO_ROOT/scripts" "$MUT2/"; then
  fail_ "M2 setup" "could not mirror scripts/"
else
  tgt2="$MUT2/scripts/pre-commit-gate.sh"
  before2="$(newtmp)/before"; cp "$tgt2" "$before2"
  n_op2="$(grep -cF "$OPERATIVE2" "$before2")"; case "$n_op2" in ''|*[!0-9]*) n_op2=0 ;; esac
  if [ "$n_op2" -ne 1 ]; then
    fail_ "M2 setup" "the operative line occurs $n_op2 times, need exactly 1 — the assertion is not pinned to real code"
  else
    # substitute the whole line, keeping its indentation; awk -v is used so the
    # operative text is matched literally, not as a regex
    awk -v op="$OPERATIVE2" -v rep='root="$c"' \
      '{ i = index($0, op); if (i) print substr($0, 1, i - 1) rep; else print }' \
      "$before2" > "$tgt2"
    n_after2="$(grep -cF "$OPERATIVE2" "$tgt2")"; case "$n_after2" in ''|*[!0-9]*) n_after2=0 ;; esac
    removed2="$(diff "$before2" "$tgt2" | grep -c '^<')"; case "$removed2" in ''|*[!0-9]*) removed2=0 ;; esac
    added2="$(diff "$before2" "$tgt2" | grep -c '^>')";   case "$added2"   in ''|*[!0-9]*) added2=0 ;; esac
    if ! parses "$tgt2"; then
      fail_ "M2 setup" "the mutated gate does not parse — a mangled substitution must not pass as a landed mutation"
    elif [ "$n_after2" -ne 0 ] || [ "$removed2" -ne 1 ] || [ "$added2" -ne 1 ]; then
      fail_ "M2 setup" "the mutation did not land cleanly (operative lines left=$n_after2, removed=$removed2, added=$added2, want 0, 1 and 1)"
    elif ! mk_pair || ! mkdir -p "$FX_TGT/deep/er"; then
      fail_ "M2 setup" "could not build the mutant's fixtures"
    else
      put_sentinel "$FX_TGT" "$Q_TARGET"
      # C1 would NOT catch this: with .cwd at the root, root="$c" is correct
      run_gate "$tgt2" "$FX_SESS" "$FX_TGT"
      if ! reason_has "$Q_TARGET"; then
        fail_ "M2 setup" "the mutant did not survive C1's fixture — the mutation is not the one that hid at 7 / 0"
      else
        run_gate "$tgt2" "$FX_SESS" "$FX_TGT/deep/er"
        if reason_has "$Q_TARGET"; then
          fail_ "M2 (MUTATION)" "root=\"\$c\" still found the target's sentinel from a subdirectory — C1b is not exercising toplevel resolution"
        else
          pass "M2 (MUTATION) — with toplevel resolution replaced by root=\"\$c\", C1 still passes and a .cwd below the root stops blocking: C1b is what catches it"
        fi
      fi
    fi
  fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] && exit 0
exit 1
