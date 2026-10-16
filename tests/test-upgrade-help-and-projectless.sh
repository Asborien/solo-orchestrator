#!/usr/bin/env bash
# tests/test-upgrade-help-and-projectless.sh
#
# Issues #419 and #426, and `## BL-177:`.
#
#   H  `--help` is the one invocation an operator runs to learn what a script
#      will do. #419: it died before the help block (`cd: null directory`,
#      rc 1) because the idempotent backfill ran first. #426: combined with
#      --sync-framework, --plan or --validate-only it did the work instead —
#      116 files written on a request for help. Help now wins, whatever else
#      is on the line, and writes nothing.
#   P  run outside any project, the backfill's `( cd "$PROJECT_ROOT"` ran on
#      an empty string and killed the script with bash's own words; and
#      `--backfill-only` wrote `.claude/skills/` and `scripts/lib/` copies into
#      whatever directory it was run from (BL-177). A projectless run now
#      gets the script's own refusal and writes nothing.
#
# Every case snapshots the directory it runs in (names + cksum) and requires
# it unchanged.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE="$REPO_ROOT/scripts/upgrade-project.sh"

PASSED=0
FAILED=0
pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
fail_() { echo "  [FAIL] $1 — $2"; FAILED=$((FAILED + 1)); }

TOPTMP="$(mktemp -d)"
trap 'rm -rf "$TOPTMP"' EXIT INT TERM
newtmp() { mktemp -d "$TOPTMP/fixXXXXXX"; }

[ -f "$UPGRADE" ] || { echo "  [FAIL] setup — $UPGRADE not found"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  [FAIL] setup — jq is required"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }

snap() { (cd "$1" && { find . -type d; find . -type f -exec cksum {} +; } | LC_ALL=C sort); }

# mk_project <dir> — the smallest tree find_project_root accepts.
mk_project() {
  local d="$1"
  mkdir -p "$d/.claude" || return 1
  ( cd "$d" && git init -q . && git config user.email t@t.invalid && git config user.name T ) >/dev/null 2>&1
  printf '{"project":"P","current_phase":0,"track":"light","deployment":"personal","poc_mode":null}\n' > "$d/.claude/phase-state.json"
  printf '{"host":"github","mode":"personal"}\n' > "$d/.claude/manifest.json"
}

# run <dir> <args…> — the real script, cwd <dir>, no stdin. Sets RC, OUT.
run() {
  local d="$1"; shift
  OUT="$(cd "$d" && GITHUB_BASE_REF='' bash "$UPGRADE" "$@" </dev/null 2>&1)"; RC=$?
}

echo "=== H — --help wins over every mode, and writes nothing (#419, #426) ==="

for args in "--help" "-h" "--sync-framework --help" "--plan --help" "--validate-only --track standard --help" "--backfill-only --help"; do
  d="$(newtmp)/proj"; mk_project "$d"; before="$(snap "$d")"
  # shellcheck disable=SC2086
  run "$d" $args
  bad=""
  [ "$RC" -eq 0 ] || bad="$bad [rc $RC]"
  printf '%s' "$OUT" | grep -q 'Project Upgrade' || bad="$bad [no help text]"
  [ "$before" = "$(snap "$d")" ] || bad="$bad [the project changed]"
  [ -z "$bad" ] && pass "H ($args) — help printed, rc 0, project byte-identical" \
                || fail_ "H ($args)" "$bad :: $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ' | cut -c1-160)"
done

d="$(newtmp)/empty"; mkdir -p "$d"; before="$(snap "$d")"
run "$d" --help
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'Project Upgrade' && [ "$before" = "$(snap "$d")" ]; then
  pass "H (outside any project) — --help prints help at rc 0 (#419's own reproduction)"
else
  fail_ "H (outside any project)" "rc $RC :: $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ' | cut -c1-160)"
fi

echo "=== P — a projectless run is refused by the script, and writes nothing (#419, BL-177) ==="

d="$(newtmp)/empty"; mkdir -p "$d"; before="$(snap "$d")"
run "$d" --track standard
bad=""
[ "$RC" -ne 0 ] || bad="$bad [rc 0]"
printf '%s' "$OUT" | grep -q 'No Solo Orchestrator project found' || bad="$bad [not the script's own refusal]"
printf '%s' "$OUT" | grep -q 'null directory' && bad="$bad [died on cd \"\"]"
[ "$before" = "$(snap "$d")" ] || bad="$bad [the directory changed]"
[ -z "$bad" ] && pass "P1 — --track standard outside a project: 'No Solo Orchestrator project found', rc $RC, nothing written" \
              || fail_ "P1" "$bad :: $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ' | cut -c1-160)"

# P2 — BL-177's leak: a cwd that merely HAS a scripts/ dir, no project marker.
d="$(newtmp)/notproj"; mkdir -p "$d/scripts"; before="$(snap "$d")"
run "$d" --backfill-only
bad=""
[ "$RC" -ne 0 ] || bad="$bad [rc 0]"
printf '%s' "$OUT" | grep -q 'No Solo Orchestrator project found' || bad="$bad [no refusal]"
[ ! -e "$d/.claude/skills" ] || bad="$bad [wrote .claude/skills]"
[ ! -e "$d/scripts/lib" ] || bad="$bad [wrote scripts/lib]"
[ "$before" = "$(snap "$d")" ] || bad="$bad [the directory changed]"
[ -z "$bad" ] && pass "P2 — --backfill-only outside a project is refused and writes nothing (BL-177's two leaks)" \
              || fail_ "P2" "$bad :: $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ' | cut -c1-160)"

# P3 — the backfill function itself, with no project root, returns without
# writing (the structural guard, independent of which caller reaches it).
d="$(newtmp)/notproj"; mkdir -p "$d/scripts"; before="$(snap "$d")"
fn="$TOPTMP/backfill-fn.sh"
awk '$0 == "_run_idempotent_backfill() {" { f = 1 } f { print } f && $0 == "}" { exit }' "$UPGRADE" > "$fn"
out="$(cd "$d" && bash -c '
  . "$1"
  print_step() { :; }; print_ok() { :; }; print_info() { :; }; print_warn() { :; }
  ORCHESTRATOR_ROOT="$2"; PROJECT_ROOT=""
  _run_idempotent_backfill; echo "rc=$?"' _ "$fn" "$REPO_ROOT" 2>&1)"
if [ -s "$fn" ] && printf '%s' "$out" | grep -q '^rc=0$' && [ "$before" = "$(snap "$d")" ]; then
  pass "P3 — _run_idempotent_backfill with no project root returns 0 and writes nothing"
else
  fail_ "P3" "$(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-160)"
fi

# P4/P5 — each half of # BL-177-BACKFILL-GUARD on its own; P3 alone cannot
# tell them apart, because either half stops that fixture.
bf() {  # bf <cwd> <PROJECT_ROOT value> → rc line
  (cd "$1" && bash -c '
  . "$1"
  print_step() { :; }; print_ok() { :; }; print_info() { :; }; print_warn() { :; }
  ORCHESTRATOR_ROOT="$2"; PROJECT_ROOT="$3"
  _run_idempotent_backfill; echo "rc=$?"' _ "$fn" "$REPO_ROOT" "$2" 2>&1)
}
# P4 — a root is given but carries neither marker: the marker half stops it.
d="$(newtmp)/notproj"; mkdir -p "$d/scripts"; before="$(snap "$d")"
out="$(bf "$d" "$d")"
if printf '%s' "$out" | grep -q '^rc=0$' && [ "$before" = "$(snap "$d")" ]; then
  pass "P4 — a project root with no .claude marker: the backfill writes nothing"
else
  fail_ "P4" "the backfill wrote into a marker-less root :: $(printf '%s' "$out" | tail -1)"
fi
# P5 — NO root, and a cwd that has a manifest (but no phase-state, so
# find_project_root gives ""). bash 3.2's `cd ""` stays put and the marker
# half would pass: only the empty-root half stops it.
d="$(newtmp)/halfproj"; mkdir -p "$d/scripts" "$d/.claude"; printf '{}\n' > "$d/.claude/manifest.json"; before="$(snap "$d")"
out="$(bf "$d" "")"
if printf '%s' "$out" | grep -q '^rc=0$' && [ "$before" = "$(snap "$d")" ]; then
  pass "P5 — an empty project root, even over a cwd with a manifest: the backfill writes nothing"
else
  fail_ "P5" "the backfill wrote with no project root :: $(printf '%s' "$out" | tail -1)"
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
