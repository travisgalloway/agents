#!/usr/bin/env bash
# reference-integrity.sh — clause two of the fix-in-place rule, mechanically.
#
# THE RULE: when something changes, fix the reference in place; never leave a reference pointing
# at something that no longer exists. Prose cannot enforce that. A stale cross-reference reads as
# authoritative right up until someone follows it and finds nothing, and by then the document has
# already misled every task that trusted it.
#
# Four real violations found in this tree the day this suite was written, all shipped within the
# preceding week:
#   * skills/work/SKILL.md cited `/status` §3 for a base-ref refresh that lives in step 7
#   * tests/git-scenarios.sh said `/pr` §7 while tests/README.md said `/pr` §6 — and /pr has NO
#     `##` headings at all, so both were citing list items with a section marker
#   * three test files still referenced ~/.claude/commands/, deleted in the skills migration
#   * tests/README.md documented 10 of 13 suites and claimed a hardcoded assertion count
#
# What this suite deliberately does NOT flag: the append-only carve-outs. ADRs are superseded
# rather than edited, `Deprecated` matrix rows tombstone with a date, docs/parked-findings.md is a
# dated log, and COMMAND-AUDIT.md is a declared historical record whose header discloses its own
# stale paths. Those are the rule's boundary, not violations of it.
#
# No network. Nothing is executed — only read.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

ROOT="${CLAUDE_ROOT:-$HOME/.claude}"

# Locally-authored skills only; vendored ones (cloudflare, wrangler, …) are documentation snippets
# whose cross-references we neither own nor maintain.
OURS="automerge backlog ci closure-audit commit feature-closure pr reap reviews status sync work"

# Skills with NO `##` headings — flat numbered lists. Citing `§N` into one of these is a category
# error: it looks valid, resolves to nothing, and is how violation #2 above survived review.
FLAT="pr status"

FILES=""
for s in $OURS; do
  f="$ROOT/skills/$s/SKILL.md"
  [ -f "$f" ] && FILES="$FILES $f"
done
for f in "$ROOT"/skills/feature-closure/references/*.md "$ROOT"/agents/*.md; do
  [ -f "$f" ] && FILES="$FILES $f"
done

section "The corpus is visible"
NF=$(printf '%s' "$FILES" | wc -w | tr -d ' ')
# A glob that matches nothing runs zero assertions and reports success. Count and assert.
if [ "$NF" -ge 15 ]; then ok "collected $NF files to check"
else bad "collected only $NF files — the globs broke, every check below is void"; summary; exit 1; fi

# ---------------------------------------------------------------- 1. dead directory
section "Nothing points at the removed ~/.claude/commands/"
# Three files legitimately NAME this path: COMMAND-AUDIT.md (a declared historical record that
# discloses its own stale paths), this suite (it cannot forbid a string without containing it),
# and the README row describing this suite. Excluding them is the carve-out, not a loophole —
# everything else that mentions the directory is pointing at something that is gone.
HITS=$(grep -rln 'claude/commands/\|\$ROOT/commands/\|~/\.claude/commands' \
         "$ROOT"/skills "$ROOT"/agents "$ROOT"/tests "$ROOT"/lib "$ROOT"/hooks 2>/dev/null \
       | grep -vE 'COMMAND-AUDIT|reference-integrity\.sh|tests/README\.md' || true)
if [ -z "$HITS" ]; then ok "no live reference to the deleted commands/ directory"
else
  for h in $HITS; do bad "references the deleted commands/ directory" "${h#$ROOT/}"; done
fi

# ---------------------------------------------------------------- 2. § into a flat-list skill
section "\`§\` is not used to cite a skill that has no sections"
FLATBAD=0
for f in $FILES; do
  for target in $FLAT; do
    # `/pr` §6  /  `/status` §3 — the backticked-command-then-section form used across the suite.
    if grep -qE '`/'"$target"'`[^.]{0,12}§' "$f"; then
      FLATBAD=$((FLATBAD+1))
      bad "cites /$target with § but /$target has no ## headings — say \"step N\"" \
          "${f#$ROOT/}: $(grep -oE '`/'"$target"'`[^.]{0,12}§[0-9A-Za-z.]+' "$f" | head -1)"
    fi
  done
done
[ "$FLATBAD" -eq 0 ] && ok "no § citations into flat-list skills (/${FLAT// //})"

# ---------------------------------------------------------------- 3. referenced .md files exist
section "Every referenced .md resolves on disk"
MISSING=0; CHECKED=0
for f in $FILES; do
  d=$(dirname "$f")
  for ref in $(grep -ohE '`(references/)?[a-z][a-z-]+\.md`' "$f" | tr -d '`' | sort -u); do
    case "$ref" in
      # Target-repo paths, not paths in this tree — correctly absent here.
      backlog.md|parked-findings.md|feature-matrix.md|test-plan.md|exports.md|README.md) continue ;;
    esac
    CHECKED=$((CHECKED+1))
    if [ -f "$d/$ref" ] || [ -f "$ROOT/skills/feature-closure/references/$(basename "$ref")" ] \
       || [ -f "$ROOT/agents/$(basename "$ref")" ]; then :
    else MISSING=$((MISSING+1)); bad "referenced file does not exist: $ref" "${f#$ROOT/}"; fi
  done
done
if [ "$CHECKED" -eq 0 ]; then bad "checked ZERO .md references — the extraction broke"
else [ "$MISSING" -eq 0 ] && ok "all $CHECKED .md references resolve"; fi

# ---------------------------------------------------------------- 4. README documents every suite
section "Every \`!\`cmd\`\` injection resolves to a real executable"
# THE BUG: skills/feature-closure said it carries no `` !`branches.sh` `` block — naming the
# syntax inside a code span inside a blockquote, as prose. The harness expands that form wherever
# it appears, so LOADING the skill ran `branches.sh`, which is not on PATH, and the skill failed
# to initialize before its first line was read. A reference that EXECUTES is the sharpest version
# of the rule this suite enforces: it must point at something that exists, and a relative name
# resolves against a PATH the skill does not control.
BANGBAD=0; BANGN=0
for f in $FILES; do
  # Strip the ! and the surrounding backticks; whatever is left is the command line.
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    BANGN=$((BANGN+1))
    bin=${cmd%% *}
    case "$bin" in
      /*) [ -x "$bin" ] || { BANGBAD=$((BANGBAD+1)); bad "injection targets a missing or non-executable file" "${f#$ROOT/}: $bin"; } ;;
      *)  BANGBAD=$((BANGBAD+1))
          bad "injection is not an absolute path — it resolves against PATH at load time" \
              "${f#$ROOT/}: $cmd" ;;
    esac
  done <<EOF
$(grep -o '![`][^`]*[`]' "$f" 2>/dev/null | sed 's/^!`//; s/`$//')
EOF
done
[ "$BANGBAD" -eq 0 ] && ok "all $BANGN command injections are absolute paths to executables"

section "tests/README.md documents every suite run-all.sh runs"
SUITES=$(sed -n '/^for t in/,/; do$/p' "$ROOT/tests/run-all.sh" \
         | sed -e 's/^for t in//' -e 's/; do$//' -e 's/\\$//' | tr -s ' \n' ' ')
NS=0; UNDOC=0
for s in $SUITES; do
  [ -n "$s" ] || continue
  NS=$((NS+1))
  grep -q "\`$s\.sh\`" "$ROOT/tests/README.md" || { UNDOC=$((UNDOC+1)); bad "suite not documented in README.md" "$s"; }
done
if [ "$NS" -lt 10 ]; then bad "parsed only $NS suites from run-all.sh — the parse broke"
else [ "$UNDOC" -eq 0 ] && ok "all $NS suites have a README row"; fi

# ---------------------------------------------------------------- 5. README states no rotting count
section "README.md does not restate a count that rots"
if grep -qE '^[0-9]+ assertions' "$ROOT/tests/README.md"; then
  bad "README hardcodes an assertion count — run-all.sh prints the real total"
else ok "no hardcoded assertion count"; fi

# ---------------------------------------------------------------- 6. the carve-outs survive
# Written as assertions so a future "consistency" pass that deletes them fails here rather than
# silently destroying the decision record they protect.
section "The append-only carve-outs are still stated"
LD="$ROOT/skills/feature-closure/references/living-docs.md"
assert_contains "ADRs are superseded, not edited" "$(cat "$LD")" "Supersede"
assert_contains "ADR carve-out explains WHY" "$(cat "$LD")" "destroys the record"
assert_contains "Deprecated rows still tombstone with a date" "$(cat "$LD")" \
  "rather than deleting the row"
assert_contains "the current-truth vs dated-log line is stated" "$(cat "$LD")" \
  "a dated log of events is appended to"

summary
