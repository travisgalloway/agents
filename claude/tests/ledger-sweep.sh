#!/usr/bin/env bash
# ledger-sweep.sh — pin the "armed without teardown" query in skills/backlog Step 9 and Step 8.
#
# THE BUG THIS PINS: a /backlog run over 20 issues ended on 2026-09-06 with 41 agents still
# registered, one plan and one exec per issue. Two things went wrong together. The teammate's
# agentId was never written to the ledger (the dispatch line is written before the Agent call
# returns), so the final sweep had nothing to stop; and the resumed session wrote its stage lines
# keyed "status" instead of "event", so a sweep keyed on the schema skipped that session entirely.
#
# The fix records an `armed` line after dispatch and a `teardown` line on every exit path. This
# suite pins the query that pairs them: a stage with an `armed` line and no `teardown` is a leak,
# a torn-down stage is not, a re-armed stage that was torn down again is not, and a malformed
# `status` line is reported by its own probe rather than silently ignored.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

SKILL="$HOME/.claude/skills/backlog/SKILL.md"

section "The skill carries the sweep query"
BLOCK=$(extract_block "$SKILL" 'select(last.event=="armed")')
[ -n "$BLOCK" ] && ok "Step 9 block found" || bad "Step 9 block with the armed/teardown pairing is missing"
assert_contains "the Step 9 block pairs by issue and stage" "$BLOCK" 'group_by([.issue,.stage])'
assert_contains "the Step 8 resume block carries the malformed-line probe" "$(extract_block "$SKILL" 'has("status")')" 'select(.t=="stage" and has("status"))'

# The two-stage query as the skill writes it: filter to armed/teardown, then pair by issue+stage.
FILTER='select(.t=="stage" and (.event=="armed" or .event=="teardown"))'
PAIR='group_by([.issue,.stage]) | map(select(last.event=="armed") | last) | .[] | {issue,stage,name,monitor,teammate}'
MALFORMED='select(.t=="stage" and has("status"))'

L=$(mktemp)
cat > "$L" <<'JSONL'
{"t":"run","session":"s1","queue":[9,10,11]}
{"t":"stage","issue":9,"stage":"plan","event":"dispatch","epoch":1}
{"t":"stage","issue":9,"stage":"plan","event":"armed","name":"plan-9","monitor":"b111","teammate":"a111"}
{"t":"stage","issue":9,"stage":"plan","event":"done","plan_mtime":2}
{"t":"stage","issue":9,"stage":"plan","event":"teardown","monitor":"stopped","teammate":"already-gone","rc":0}
{"t":"stage","issue":9,"stage":"exec","event":"dispatch","head_before":"abc"}
{"t":"stage","issue":9,"stage":"exec","event":"armed","name":"exec-9","monitor":"b222","teammate":"a222"}
{"t":"stage","issue":9,"stage":"exec","event":"done","pr":81}
{"t":"stage","issue":10,"stage":"plan","status":"dispatched","epoch":3}
{"t":"stage","issue":11,"stage":"plan","event":"armed","name":"plan-11","monitor":"b333","teammate":"a333"}
{"t":"stage","issue":11,"stage":"plan","event":"teardown","monitor":"stopped","teammate":"stopped","rc":3}
{"t":"stage","issue":11,"stage":"plan","event":"armed","name":"plan-11","monitor":"b444","teammate":"a444"}
{"t":"stage","issue":11,"stage":"plan","event":"teardown","monitor":"stopped","teammate":"stopped","rc":0}
JSONL

section "Leaked stages: armed with no teardown"
OUT=$(jq -c "$FILTER" "$L" | jq -sc "$PAIR")
assert_eq "exactly one leaked stage" "1" "$(printf '%s\n' "$OUT" | grep -c .)"
assert_contains "the leak is issue 9 exec" "$OUT" '"issue":9,"stage":"exec"'
assert_contains "it carries the monitor ID" "$OUT" '"monitor":"b222"'
assert_contains "it carries the teammate agentId" "$OUT" '"teammate":"a222"'
assert_not_contains "a torn-down stage is not listed" "$OUT" '"stage":"plan","name":"plan-9"'
assert_not_contains "a re-armed stage torn down again is not listed" "$OUT" 'plan-11'
assert_not_contains "the malformed status line is not mistaken for a leak" "$OUT" '"issue":10'

section "Malformed lines are found by their own probe, never folded into the sweep"
M=$(jq -c "$MALFORMED" "$L")
assert_eq "one malformed stage line" "1" "$(printf '%s\n' "$M" | grep -c .)"
assert_contains "it is issue 10" "$M" '"issue":10'

section "An empty or absent ledger answers nothing, without aborting"
: > "$L"
assert_eq "empty ledger lists no leaks" "" "$(jq -c "$FILTER" "$L" | jq -sc "$PAIR")"
assert_rc "empty ledger rc 0" 0 sh -c "jq -c '$FILTER' '$L' | jq -sc '$PAIR'"

rm -f "$L"
summary
