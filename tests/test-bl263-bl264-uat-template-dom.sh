#!/usr/bin/env bash
# tests/test-bl263-bl264-uat-template-dom.sh
#
# `## BL-263:` — SCENARIO TEXT IS DATA, NOT MARKUP.
# `## BL-264:` — APPENDING A BUG MUST NOT ERASE THE ONES ALREADY THERE.
#
# Two defects in one shipped template, both in how it writes to the DOM, so one
# suite. B1-B3 are BL-264's; everything else is BL-263's.
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
# `s.id` NEEDS ITS OWN PINS, and they must be STATIC. The behavioural proof for
# the id escaping lives in R5, which needs jsdom — and NO CI lane installs
# jsdom, so reverting all eight sites left the gating lane at 24/0. These two
# are what the merge actually rests on. Eight is derived, not chosen: the
# render body has that many `s.id` interpolations.
chk "S5: every s.id site goes through escapeHtml" \
  "$(grep -c 'escapeHtml(s\.id)' "$_body")" "8"
chk "S5: and no RAW s.id survives in the render body" \
  "$(grep -c '+ s\.id' "$_body")" "0"
# S6 — THE FIFTH `g`. `escapeHtml` has four `g` flags and `E7` pins each; the
# `<br>` substitution one line below it carries a fifth that `E7` cannot reach.
# `R4` catches it behaviourally, but R needs jsdom and no CI lane has jsdom, so
# dropping that one letter left the gating lane at 27/0. Static, therefore, and
# by its literal bytes: a changed-line count would not know which `g` moved.
chk "S6: the steps <br> substitution is GLOBAL (the fifth g flag)" \
  "$(grep -c 'escapeHtml(s\.steps)\.replace(/\\n/g' "$_body")" "1"

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
  # EVERY OCCURRENCE, NOT THE FIRST. Dropping the four `g` flags is a
  # one-character regression that reverts this fix to a live injection, and
  # single-character inputs cannot see it: measured, the g-less mutant returns
  # `&lt;a<b` for `<a<b` and the suite stayed at 30/0. One case per arm, each
  # with the character twice.
  chk "E7: every '<' is escaped, not just the first"  "$(_esc '<a<b')"  '&lt;a&lt;b'
  chk "E7: every '>' is escaped, not just the first"  "$(_esc '>a>b')"  '&gt;a&gt;b'
  chk "E7: every '&' is escaped, not just the first"  "$(_esc '&a&b')"  '&amp;a&amp;b'
  chk 'E7: every double-quote is escaped, not just the first' "$(_esc '"a"b')" '&quot;a&quot;b'
  # And ordinary text is untouched, or the fix would mangle every scenario.
  chk "E6: text with nothing to escape is returned verbatim" \
    "$(_esc 'fails when a plus b')" 'fails when a plus b'
  # `String(t)` IS LOAD-BEARING and no other case can see it: `_esc` passes
  # argv, which is always a string. Eight `s.id` sites are NUMBERS, so dropping
  # `String()` throws `t.replace is not a function` inside renderScenarios and
  # the page renders ZERO scenarios — measured, and the gating lane stayed at
  # 24/0. A number in, a string out.
  chk "E8: escapeHtml(1) returns the string '1' — every s.id site needs String()" \
    "$(node -e "eval(require('fs').readFileSync('$WORK/esc.js','utf8')); process.stdout.write(escapeHtml(1))" 2>/dev/null)" "1"
else
  # NOT A SKIP. A skip never fails, and `E` is the only section that can tell
  # `escapeHtml(s.title)` from a helper that returns its argument — the static
  # cases pass on an identity function. If node is missing, this suite cannot
  # do its job, and saying so is `# BL-182-NO-UNEARNED-RECEIPT`: a green that
  # measured nothing is worse than a red. `ubuntu-latest` ships node, and
  # tests.yml's "Verify required tools are available" step now asserts it.
  bad "E0-E7 — node unavailable, so the escape was NOT verified; the static pins cannot distinguish escapeHtml(x) from identity"
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
// A SECOND scenario with an out-of-schema string id, so R5 has something to
// read. It is separate from scenario 1 rather than replacing it, because the
// numeric case is the one that must stay byte-identical.
const scenarios = [{
  id: 1, feature: 7,
  // Every character escapeHtml touches — < > & " — plus prose around them, so
  // an arm that DELETES instead of escaping is caught. A first draft used only
  // angle brackets, and a mutant that replaced the `"` arm's substitution with
  // '' passed 14/14.
  // Each character TWICE, so a g-less escape leaves a live element behind:
  // with one `<` the first-match escape covers it and R1-R3 pass on a broken fix.
  title: 'Repair has <button disabled> set & "quoted" > done <img src=x onerror=BOOM> & "again"',
  // TWO line breaks, not one. The `<br>` substitution one line below
  // escapeHtml carries a FIFTH `g` flag that E7 does not reach, and with a
  // single `\n` first-match and global are identical — measured, dropping that
  // `g` left the suite at 36/0 with jsdom and 24/0 without.
  steps: "1. open\n2. <script>alert(1)<\/script>\n3. done",
  expected: "an <img src=x onerror=alert(1)> must not appear"
}, {
  id: '1"><img src=q onerror=PWN>', feature: 7,
  title: "out-of-schema string id", steps: "x", expected: "y"
}];
eval(fs.readFileSync(process.argv[2], 'utf8'));
renderScenarios();
const c = document.getElementById('feature7');
const out = {
  injected_button: c.querySelectorAll('button[disabled]').length,
  injected_script: c.querySelectorAll('script').length,
  injected_img:    c.querySelectorAll('img').length,
  title_text:      (c.querySelector('.scenario-title') || {}).textContent,
  // SCOPED to the second scenario — the one with the string id. Container-wide
  // it would duplicate R3 and could not say WHICH scenario injected.
  id_imgs:         (c.querySelectorAll('.scenario')[1] || {querySelectorAll:()=>[]}).querySelectorAll('img').length,
  id_num_text:     (c.querySelectorAll('.scenario-num')[1] || {}).textContent,
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
      "$(_f title_text)" 'Repair has <button disabled> set & "quoted" > done <img src=x onerror=BOOM> & "again"'
    # Escaping happens BEFORE the <br> substitution, so line breaks survive.
    # THREE: the div opens with a literal `<strong>Steps:</strong><br>` and the
    # fixture's TWO `\n`s add one each. A first draft asserted 1 and failed
    # against correct code; a second used one `\n` and could not see the fifth
    # `g` flag drop. The count is of the rendered div, not of the substitution.
    chk "R4: EVERY steps line break renders as a <br> (1 literal + 2 from \n)" \
      "$(_f br_in_steps)" "3"
    # `s.id` goes through escapeHtml too. A draft left it raw on the stated
    # grounds that escaping would "corrupt" the onclick — measured false: for a
    # numeric id the HTML is byte-identical, and for a string id carrying markup
    # the raw form yields 7 live injected elements while the escaped form yields
    # 0. (A draft said 4. Seven: 8 `s.id` sites, and the `<textarea id="notes-…">`
    # one lands in RCDATA, yielding text rather than an element.) HTML escaping
    # does NOT close the JS context — an id shaped as JS still executes; see the
    # template comment. The scenario schema says `id` is a number;
    # `lint-uat-scenarios.sh` never checks that, so this is the guard.
    chk "R5: a string id carrying markup injects NOTHING"     "$(_f id_imgs)" "0"
    chk "R5: and the scenario num still reads as written"     "$(_f id_num_text)" '1"><img src=q onerror=PWN>'
  fi
else
  skip_ "R1-R4 — node + jsdom unavailable"
fi

echo '=== B — `## BL-264:` a second addBug() must not erase the first ==='   # single-quoted: backticks in "..." are command substitution

if [ "$HAVE_JSDOM" -eq 1 ]; then
  # Lift the REAL addBug out of the shipped template, same as above — a
  # hand-copied body is how a proof stops testing the artifact.
  awk '/^function addBug\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$TPL" > "$WORK/addbug.js"
  chk "B0: addBug was extracted from the template" \
    "$([ -s "$WORK/addbug.js" ] && echo yes || echo no)" "yes"
  cat > "$WORK/bug.js" <<'JSEOF'
const { JSDOM } = require('jsdom');
const fs = require('fs');
const dom = new JSDOM('<!doctype html><body><div id="bugs-list"></div></body>');
global.document = dom.window.document;
var bugCount = 0;
eval(fs.readFileSync(process.argv[2], 'utf8'));
addBug();
document.getElementById('bug-desc-1').value  = 'crash on export';
document.getElementById('bug-steps-1').value = '1. open  2. click export';
document.getElementById('bug-sev-1').value   = 'SEV-1 (crash/data loss)';
addBug();   // the tester clicks "+ Add Bug" a second time
console.log(JSON.stringify({
  desc:    document.getElementById('bug-desc-1').value,
  steps:   document.getElementById('bug-steps-1').value,
  sev:     document.getElementById('bug-sev-1').value,
  entries: document.querySelectorAll('.bug-entry').length,
}));
JSEOF
  BRES="$(node "$WORK/bug.js" "$WORK/addbug.js" 2>"$WORK/berr")" || BRES=""
  if [ -z "$BRES" ]; then
    bad "B0 — the lifted addBug did not execute (see $WORK/berr)"
    head -3 "$WORK/berr" 2>/dev/null | sed 's/^/        /'
  else
    _b() { printf '%s' "$BRES" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>console.log(JSON.parse(s)['$1']))"; }
    # The whole defect in one assertion: this read '' before the fix.
    chk "B1: a typed Description survives a second addBug()" "$(_b desc)"  "crash on export"
    chk "B1: a typed Steps survives a second addBug()"       "$(_b steps)" "1. open  2. click export"
    # A <select> is the sharper case — re-serialization reverts it to the
    # `selected` ATTRIBUTE, which is a different wrong answer from empty.
    chk "B2: a chosen <select> option survives too"          "$(_b sev)"   "SEV-1 (crash/data loss)"
    # And the append still appends — a fix that preserved the old entry by
    # never adding the new one would pass B1/B2 and be useless.
    chk "B3: and the second entry was actually added"        "$(_b entries)" "2"
  fi
else
  skip_ "B0-B3 — node + jsdom unavailable"
fi

echo "=== B — statically, the construct is gone ==="
chk "B4: the marker is present exactly once, alone on its line" \
  "$(grep -c '^// BL-264-APPEND-NOT-RESERIALIZE$' "$TPL")" "1"
_abody="$WORK/addbug-static.js"
awk '/^function addBug\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$TPL" > "$_abody"
chk "B4: the addBug body is non-empty (the extraction found it)" \
  "$([ -s "$_abody" ] && echo yes || echo no)" "yes"
chk "B5: addBug no longer uses innerHTML at all" \
  "$(grep -c 'innerHTML' "$_abody")" "0"
chk "B5: and appends with insertAdjacentHTML beforeend" \
  "$(grep -c "insertAdjacentHTML('beforeend'" "$_abody")" "1"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0
exit 1
