#!/usr/bin/env bash
# tests/test-bl263-uat-scenario-escaping.sh
#
# `## BL-263:` — SCENARIO TEXT IS DATA, NOT MARKUP.
#
# `templates/uat/test-session-template.html` concatenates `s.title`, `s.steps`
# and `s.expected` into innerHTML. Before `# BL-263-ESCAPE-SCENARIO-TEXT` they
# went in raw, so a scenario that merely NAMED markup rendered as markup — and
# the template's OWN shipped example says "Read the Repair button's disabled
# attribute", so that is ordinary content, not an exotic input.
#
# NOT A SECURITY SUITE. `__SCENARIOS_JSON__` is substituted at generation time
# from the operator's own docs, so there is no untrusted input (`## BL-262:`
# carries that measurement). This pins CORRECTNESS, and it closes the trust
# assumption before some future generator sources scenario text from a
# dependency name or a failing test's message.
#
# THE STATIC CASES ARE THE FLOOR, NOT THE PROOF. S1-S3 grep the template. A
# grep cannot tell `escapeHtml(s.title)` from a helper that returns its
# argument, so R1-R4 EXECUTE the template's real `renderScenarios` body in a
# DOM and read the resulting tree. Those need node + jsdom; without them the
# suite SKIPS LOUDLY rather than passing on the greps alone.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TPL="$REPO_ROOT/templates/uat/test-session-template.html"

PASS=0; FAIL=0; SKIP=0
ok()    { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad()   { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
skip_() { SKIP=$((SKIP+1)); echo "  [SKIP] $1"; }
chk()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bl263.XXXXXX")" || exit 1
case "$WORK" in "$REPO_ROOT"*) echo "FATAL: fixture inside repo"; exit 1 ;; esac
trap 'rm -rf "$WORK"' EXIT INT TERM

[ -f "$TPL" ] || { echo "  [FAIL] setup — $TPL not found"; echo ""; echo "Results: 0 passed, 1 failed, 0 skipped"; exit 1; }

echo "=== S — the template carries the escape, statically ==="

# `//`, not `#` — this is JS. The token is still greppable on its own line,
# which is the whole point of the citation rule.
chk "S1: the marker is present exactly once, alone on its line" \
  "$(grep -c '^// BL-263-ESCAPE-SCENARIO-TEXT$' "$TPL")" "1"
chk "S2: escapeHtml is defined exactly once" \
  "$(grep -c '^function escapeHtml(t) {$' "$TPL")" "1"
# The three fields, each wrapped. Derived from the source, not transcribed.
for fld in title steps expected; do
  chk "S3: s.$fld reaches innerHTML only through escapeHtml" \
    "$(grep -c "escapeHtml(s\.$fld)" "$TPL")" "1"
done
# And the raw spellings are gone from the render path. `s.title` still appears
# in exportResults, which builds MARKDOWN — that one is not a sink and must not
# be counted, so scope the check to the renderScenarios body.
_body="$WORK/body.js"
awk '/^function renderScenarios\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$TPL" > "$_body"
chk "S4: the render body is non-empty (the extraction found it)" \
  "$([ -s "$_body" ] && echo yes || echo no)" "yes"
for fld in title steps expected; do
  chk "S4: no RAW s.$fld survives in the render body" \
    "$(grep -c "+ s\.$fld" "$_body")" "0"
done

echo "=== E — escapeHtml's BEHAVIOUR, node only, no jsdom ==="

# THIS SECTION EXISTS BECAUSE THE GATING LANE HAS NO jsdom. The R cases below
# are the strongest proof but they SKIP on any host without it, and
# `unit-shard` is such a host — which would leave the PR-blocking checks
# resting on greps alone. A grep cannot tell `escapeHtml(s.title)` from a
# helper that returns its argument: measured, an identity-function mutant
# passes every static case here. Node IS on the runner, so lift the real
# function out of the shipped template and check what it RETURNS.
if command -v node >/dev/null 2>&1; then
  awk '/^function escapeHtml\(t\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$TPL" > "$WORK/esc.js"
  chk "E0: escapeHtml was extracted from the template (not hand-copied)" \
    "$([ -s "$WORK/esc.js" ] && echo yes || echo no)" "yes"
  _esc() { node -e "
    const fs=require('fs'); eval(fs.readFileSync('$WORK/esc.js','utf8'));
    process.stdout.write(escapeHtml(process.argv[1]));
  " -- "$1" 2>/dev/null; }
  # One case per arm, each asserting the ESCAPED form — not merely 'changed'.
  # A helper that DELETES the character also 'changes' the input, and that
  # mutant survived a draft of this suite at 14/14.
  chk "E1: '<' becomes &lt;   (not dropped)"  "$(_esc '<')"  '&lt;'
  chk "E2: '>' becomes &gt;   (not dropped)"  "$(_esc '>')"  '&gt;'
  chk "E3: '&' becomes &amp;  (not dropped)"  "$(_esc '&')"  '&amp;'
  chk "E4: '\"' becomes &quot; (not dropped)" "$(_esc '"')"  '&quot;'
  # Ordering: `&` must be escaped FIRST or the ampersands it introduces get
  # double-escaped. `<` -> `&lt;` and a later `&` pass would give `&amp;lt;`.
  chk "E5: '<' does not double-escape (the & arm runs first)" "$(_esc '<')" '&lt;'
  # And ordinary text is untouched, or the fix would mangle every scenario.
  chk "E6: text with nothing to escape is returned verbatim" \
    "$(_esc 'fails when a plus b')" 'fails when a plus b'
else
  skip_ "E0-E6 — node unavailable"
fi

echo "=== R — the template's OWN render body, executed in a DOM ==="

HAVE_JSDOM=0
if command -v node >/dev/null 2>&1 \
   && node -e "require.resolve('jsdom')" >/dev/null 2>&1; then
  HAVE_JSDOM=1
else
  echo ""
  echo "#################################################################"
  echo "## node + jsdom NOT AVAILABLE. R1-R4 are SKIPPED, NOT PASSED.  ##"
  echo "## The static pins above cannot tell escapeHtml(x) from a      ##"
  echo "## helper that returns x. Install: npm i jsdom                 ##"
  echo "#################################################################"
  echo ""
fi

if [ "$HAVE_JSDOM" -eq 1 ]; then
  # Lift the REAL helper and the REAL render body out of the shipped template,
  # so this cannot drift from what ships. A hand-copied body is how a proof
  # stops testing the artifact.
  {
    awk '/^function escapeHtml\(t\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$TPL"
    cat "$_body"
  } > "$WORK/lifted.js"
  cat > "$WORK/run.js" <<'JSEOF'
const { JSDOM } = require('jsdom');
const fs = require('fs');
const dom = new JSDOM('<!doctype html><body><div id="feature7"></div></body>');
global.document = dom.window.document;
const scenarios = [{
  id: 1, feature: 7,
  // Every character escapeHtml touches — < > & " — plus prose around them, so
  // an arm that DELETES instead of escaping is caught. A first draft used only
  // angle brackets, and a mutant that replaced the `"` arm's substitution with
  // '' passed 14/14.
  title: 'Repair has <button disabled> set & "quoted" > done',
  steps: "1. open\n2. <script>alert(1)<\/script>",
  expected: "an <img src=x onerror=alert(1)> must not appear"
}];
eval(fs.readFileSync(process.argv[2], 'utf8'));
renderScenarios();
const c = document.getElementById('feature7');
const out = {
  injected_button: c.querySelectorAll('button[disabled]').length,
  injected_script: c.querySelectorAll('script').length,
  injected_img:    c.querySelectorAll('img').length,
  title_text:      (c.querySelector('.scenario-title') || {}).textContent,
  br_in_steps:     (c.querySelectorAll('.steps')[0] || {querySelectorAll:()=>[]}).querySelectorAll('br').length,
};
console.log(JSON.stringify(out));
JSEOF
  RES="$(node "$WORK/run.js" "$WORK/lifted.js" 2>"$WORK/err")" || RES=""
  if [ -z "$RES" ]; then
    bad "R0 — the lifted render body did not execute (see $WORK/err)"
    head -3 "$WORK/err" 2>/dev/null | sed 's/^/        /'
  else
    _f() { printf '%s' "$RES" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>console.log(JSON.parse(s)['$1']))"; }
    chk "R1: a title naming <button disabled> creates NO button element" "$(_f injected_button)" "0"
    chk "R2: a <script> in steps creates NO script element"              "$(_f injected_script)" "0"
    chk "R3: an <img onerror> in expected creates NO img element"        "$(_f injected_img)" "0"
    # The escape must not EAT the text — a helper that returns '' would pass
    # R1-R3 and destroy the scenario. Assert the words survive, as TEXT.
    chk "R4: and the title still READS as written, as text" \
      "$(_f title_text)" 'Repair has <button disabled> set & "quoted" > done'
    # Escaping happens BEFORE the <br> substitution, so line breaks survive.
    # TWO, not one: the div opens with a literal `<strong>Steps:</strong><br>`
    # and the single \n in the fixture adds the second. A first draft of this
    # case asserted 1 and failed against correct code — the count is of the
    # rendered div, not of the substitution.
    chk "R4: the steps line break still renders as a <br> (1 literal + 1 from \n)" \
      "$(_f br_in_steps)" "2"
  fi
else
  skip_ "R1-R4 — node + jsdom unavailable"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0
exit 1
