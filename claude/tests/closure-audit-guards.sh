#!/usr/bin/env bash
# closure-audit-guards.sh — the invariants /closure-audit cannot be allowed to lose.
#
# This command is the only one in the suite that CREATES issues, and it does so in bulk behind a
# single gate. Three failure shapes are specific to it, and all three read as success:
#
#   1. A TRUNCATED fetch. `gh issue list` defaults to --limit 30. A groom run against 30 of 400
#      issues proposes creates for capabilities that are already ticketed — a duplicate backlog,
#      generated confidently. Hence --limit 1000 plus a truncation assertion.
#   2. A BLIND pass. "0 findings" and "my probe does not understand this repo" render identically,
#      and the clean answer is the one nobody interrogates. Hence denominator-before-count, and a
#      zero denominator being a blocker rather than a clean bill of health.
#   3. A LOST DISPOSITION. The command must never close an issue and never create a label outside
#      the gate. Both are irreversible-ish and both are easy to "helpfully" add later.
#
# Blocks are extracted from the markdown and run under the shell that actually runs them (zsh),
# so doc and behavior cannot diverge — same contract as automerge-merge-gate.sh and work-probes.sh.
#
# No network: `gh` is a stub on PATH. Git scenarios are throwaway repos under $TMPDIR.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

ROOT="${CLAUDE_ROOT:-$HOME/.claude}"
SKILL="$ROOT/skills/closure-audit/SKILL.md"
METHOD="$ROOT/skills/feature-closure/references/gap-detection.md"
FC="$ROOT/skills/feature-closure/SKILL.md"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/closure-audit.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

section "The interpreter these blocks are checked under"
assert_block_shell "$BLOCK_SHELL"

section "The files exist"
for f in "$SKILL" "$METHOD"; do
  if [ -f "$f" ]; then ok "present: ${f#$ROOT/}"; else bad "MISSING: ${f#$ROOT/}"; fi
done
[ -f "$SKILL" ] || { summary; exit 1; }

SRC=$(cat "$SKILL")
MSRC=$(cat "$METHOD" 2>/dev/null)

# ---------------------------------------------------------------- the backlog fetch
# Guard against failure shape 1.
section "The backlog fetch cannot silently truncate"

FETCH=$(extract_block "$SKILL" 'gh issue list')
if [ -n "$FETCH" ]; then
  ok "extracted the backlog-fetch fence"
  # STRIP COMMENTS BEFORE ASSERTING. The fence documents its own flags in a `#` comment, so a
  # needle like "--state all" matches the prose whether or not the flag is still on the command.
  # Both of these assertions passed against a copy with the flag deleted before this line existed.
  FETCH_CODE=$(printf '%s' "$FETCH" | sed -E 's/^[[:space:]]*#.*$//')
  assert_contains "fetch raises the limit off gh's default 30" "$FETCH_CODE" "--limit 1000"
  # --state all, not open-only: a CLOSED issue is how a superseded ticket is recognised. This is a
  # DELIBERATE divergence from /backlog, which is open-only by construction — pin it so a later
  # "make it consistent with /backlog" edit fails here instead of silently disabling pass E.
  assert_contains "fetch is --state all, not open-only" "$FETCH_CODE" "--state all"
  assert_contains "fetch asks for the fields pass E needs" "$FETCH_CODE" "stateReason"
else
  bad "no gh issue list fence found — every check below is void"
fi

# The assertion itself lives in prose (the model performs it), so pin the prose. Deleting it is
# how the truncation guard silently becomes a comment.
assert_contains "truncation assertion is stated" "$SRC" "exactly equal to \`--limit\` is truncation"

# ---------------------------------------------------------------- blind passes
# Guard against failure shape 2.
section "A pass that cannot see reports BLIND, never clean"

assert_contains "denominator rule is stated in the command" "$SRC" \
  "reports BLIND, never clean"
assert_contains "the method file carries the same rule" "$MSRC" \
  "reports BLIND, never clean"

# A zero denominator has THREE meanings, and an earlier draft of this command collapsed them into
# one ("a denominator of zero is a blocker"). Verified against a real SvelteKit repo, that draft
# would have reported `adapter-static`'s legitimately absent server routes as a blocker AND — far
# worse — reported 0 e2e specs as a coverage gap on a repo with five Playwright specs, because the
# probe globbed *.spec.ts while the repo names them *.e2e.ts. Twelve fabricated findings from one
# collapsed state. Same shape as /automerge's review wait: done / not-applicable / pending.
# Anchored on the TABLE ROW, not the bare word. Bare "n/a" / "BLIND" / "clean" all occur in
# ordinary prose in this file, so those needles passed against a copy with the whole three-state
# table deleted — three assertions that could never fail, reading as coverage. tests/README.md
# trap #1, found by running the break test rather than by reading the suite.
for needle in "n/a" "BLIND" "clean"; do
  assert_contains "zero-meaning has its own table row: $needle" "$SRC" "| **$needle** |"
done
assert_contains "command names all three meanings together" "$SRC" \
  "three meanings"
assert_contains "method names all three meanings together" "$MSRC" \
  "three meanings, not two"
# The discriminator has to be concrete or it is unusable at 2am.
assert_contains "corroboration is the n/a test" "$SRC" "Corroborate before calling a zero"
assert_contains "positive control is required before reporting a zero" "$SRC" \
  "positive control"
assert_contains "method requires positive controls" "$MSRC" "Positive controls"
# n/a and UNAUDITED must stay distinct words; swapping them silently downgrades an incomplete run.
assert_contains "n/a and UNAUDITED are not interchangeable" "$SRC" \
  "must never be swapped"
# A halted pass must reach the gate. Dropping it is how a partial audit reads as a complete one.
assert_contains "a blocked pass is disclosed as UNAUDITED" "$SRC" "UNAUDITED"
assert_contains "stack must be identified before scanning" "$SRC" \
  "do not scan with guessed patterns"

# ---------------------------------------------------------------- irreversible acts
# Guard against failure shape 3.
section "The two acts this command must never take"

# Two DISTINCT anchors, because the rule is stated in two places and a single loose needle
# ("Never close") is satisfied by either — so deleting the Important Notes bullet passed.
assert_contains "Step 4 forbids closing" "$SRC" "stale label. Never close.**"
assert_contains "Important Notes forbids closing" "$SRC" "**Never closes an issue.**"
assert_contains "superseded issues get evidence + label instead" "$SRC" "NOT closed"
assert_contains "no label is created outside the gate" "$SRC" \
  "Never creates a label outside the gate"
# The suite-wide rule is "never create a label SILENTLY" — the gate is what makes it not silent.
assert_contains "labels are matched defensively first" "$SRC" "gh label list"

# ---------------------------------------------------------------- idempotency
section "A second run must propose zero creates"

assert_contains "stable capability ID is the dedup key" "$SRC" \
  "The ID is what makes this command idempotent"
assert_contains "existing matrix is authoritative for IDs" "$SRC" "never renumbered"
assert_contains "idempotency is named as the acceptance test" "$SRC" \
  "must propose **zero creates**"
# A partial write that gets blind-retried is the other way to duplicate the backlog.
assert_contains "a partial write is not blind-retried" "$SRC" "Do not retry the whole batch"
# gh issue edit --body is a whole-body overwrite, so a stale snapshot silently reverts edits made
# between the scan and the write. /work §6A learned this one.
assert_contains "issue bodies are re-fetched before editing" "$SRC" \
  "re-fetch each body immediately"

# ---------------------------------------------------------------- ticket vs park
section "The filter that keeps the backlog small"

assert_contains "capability phrasing decides ticket vs park" "$SRC" \
  "parked, not ticketed"
assert_contains "new issues are sliced vertically" "$SRC" "vertical slice"
assert_contains "the method states the same sorting rule" "$MSRC" \
  "whether you can write the Capability line"

# ---------------------------------------------------------------- read-only until the gate
section "Everything before the gate is read-only"

assert_contains "read-only phase is stated" "$SRC" "ead-only until Step 6"
assert_contains "there is exactly one gate" "$SRC" "This is the only gate"
assert_contains "dry-run stops before the gate" "$SRC" "\`dry-run\` stops after Step 5"

# ---------------------------------------------------------------- exit-status discipline
section "A failed lookup is unverified, never none"

SUMMARY_BLOCK=$(extract_block "$SKILL" 'status --porcelain')
if [ -n "$SUMMARY_BLOCK" ]; then
  ok "extracted the summary-verification fence"
  # `|| true` collapses "failed" and "none" into one indistinguishable result — the exact shape
  # CLAUDE.md names. /work §11 and /backlog §9 both carry this rule; so must this.
  assert_not_contains "summary fence does not swallow exit status" "$SUMMARY_BLOCK" "|| true"
else
  bad "no summary-verification fence found"
fi
assert_contains "unverified is preferred to none" "$SRC" "**unverified**, never \`none\`"
# Positive assertion, not a negative one: `assert_not_contains` on a hand-typed multi-line needle
# passes whether or not the rule is there, which is tests/README.md trap #1 exactly.
# Needle avoids "Do not append" because the sentence wraps between those words in the markdown —
# matching across a line break is how a real rule reads as absent (tests/README.md trap #1).
assert_contains "the skill forbids appending || true" "$SRC" "append \`|| true\`"

# ---------------------------------------------------------------- every fence runs under zsh
# skill-blocks-portability.sh covers this repo-wide, but a targeted run here names THIS file when
# it breaks, rather than reporting a line number in a shared 72-block sweep.
section "Every fence in the command parses under $BLOCK_SHELL"

i=0; PARSE_FAIL=0
awk '
  /^[ \t]*```bash[ \t]*$/ { inb=1; nb++; fn=sprintf("'"$WORK"'/%02d.sh", nb); next }
  /^[ \t]*```[ \t]*$/ { inb=0; next }
  inb { print > fn }
' "$SKILL"
for b in "$WORK"/*.sh; do
  [ -f "$b" ] || continue
  i=$((i+1))
  # Doc placeholders are documentation, not dialect: zsh parses <x> as a redirection and {n} is
  # not a word it can evaluate. Same normalisation skill-blocks-portability.sh applies.
  sed -E -e 's/<[A-Za-z_][^ >]*>/PLACEHOLDER/g' -e 's/\{[A-Za-z_][A-Za-z_0-9]*\}/PLACEHOLDER/g' \
    "$b" > "$b.norm"
  if "$BLOCK_SHELL" -n "$b.norm" 2>/dev/null; then :; else
    PARSE_FAIL=$((PARSE_FAIL+1)); bad "fence $i does not parse under $BLOCK_SHELL" "$(cat "$b")"
  fi
done
if [ "$i" -eq 0 ]; then
  bad "extracted NO fences from the command — the checks above are void"
else
  [ "$PARSE_FAIL" -eq 0 ] && ok "all $i fences parse under $BLOCK_SHELL"
fi

# ---------------------------------------------------------------- scanning routes off Opus
section "Every audit skill pins its scanning model"

# A paragraph that dispatches `Agent` must name the model in the same paragraph. Dropping
# `model: "sonnet"` silently scans on the Opus session default.
for f in "$ROOT"/skills/{closure,design,api,requirements,ux}-audit/SKILL.md \
         "$ROOT"/skills/audit/SKILL.md; do
  [ -f "$f" ] || { bad "MISSING: ${f#$ROOT/}"; continue; }
  n=$(basename "$(dirname "$f")")
  assert_eq "$n: frontmatter model is opus" "opus" "$(sed -n '2,/^---$/s/^model: *//p' "$f" | head -1)"
  assert_not_contains "$n: never names fable" "$(cat "$f")" "fable"
  unpinned=$(awk '
    BEGIN { RS = ""; ORS = "\n" }
    /^---/ { next }
    /`Agent`|subagent_type/ { if ($0 !~ /model: "(sonnet|haiku)"/) print substr($0, 1, 80) }
  ' "$f")
  if [ -z "$unpinned" ]; then ok "$n: every Agent dispatch pins sonnet or haiku"
  else bad "$n: an Agent dispatch has no model pin" "$unpinned"; fi
done

section "The capability set is derived off Opus from the repo map"

assert_contains "Step 0 reads the repo map" "$SRC" 'Read repo memory first.'
assert_contains "Step 0 confirms a stale map against a manifest" "$SRC" 'Confirm its stack against one manifest'
assert_contains "Step 2 dispatches a sonnet subagent" "$SRC" 'Dispatch one `Agent` with `model: "sonnet"` to derive the set'
assert_contains "Step 2 checks surviving IDs" "$SRC" "check every ID already in \`docs/feature-matrix.md\`"
assert_contains "Step 2 makes a missing ID a blocker" "$SRC" "A missing ID is a blocker."
assert_contains "Step 3 passes the repo map path" "$SRC" 'the repo map path (`$(~/.claude/lib/repo-map.sh path)`)'

# ---------------------------------------------------------------- progressive-disclosure integrity
# A reference file nothing links to is dead weight the model will never load — and it fails
# silently, because the skill still works, just without that part.
section "Every feature-closure reference is reachable from its SKILL.md"

REFS=0; ORPHANS=0
for r in "$ROOT"/skills/feature-closure/references/*.md; do
  [ -f "$r" ] || continue
  REFS=$((REFS+1)); base=$(basename "$r")
  case "$(cat "$FC")" in
    *"$base"*) ;;
    *) ORPHANS=$((ORPHANS+1)); bad "orphaned reference, not linked from SKILL.md: $base" ;;
  esac
done
if [ "$REFS" -eq 0 ]; then
  bad "no reference files found — the glob broke, this check is void"
else
  [ "$ORPHANS" -eq 0 ] && ok "all $REFS references are linked from feature-closure/SKILL.md"
fi

summary
