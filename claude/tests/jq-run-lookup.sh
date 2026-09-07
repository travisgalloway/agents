#!/usr/bin/env bash
# jq-run-lookup.sh — pin the workflow-run lookup used by the Claude code review wait.
#
# Consumers:
#   skills/automerge/SKILL.md §2.4
#   hooks/automerge-rewake.sh        (review-pending probe)
#
# It replaced the Copilot reviewer poll this suite used to pin, and it inherits that suite's
# bug verbatim: when `.workflow_runs` is absent from the response — a failed/partial `gh`
# call, or an API shape change — `[.workflow_runs[]...]` aborts with rc=5. Both call sites
# wrap the command in `2>/dev/null`, so the error is swallowed and the empty result reads as
# "no review run for this commit" → past the grace window the wait is skipped → the PR can
# merge while the review is still running.
#
# `[.workflow_runs[]] // []` looks like a guard and is dead code: `|` binds looser than `//`,
# so it parses as `([...] // []) | sort_by(...)`, and an array literal is never null. The
# guard has to sit on the *field*: `(.workflow_runs // [])[]`.
#
# Secondary: the runs endpoint returns every workflow's runs for the commit, so the select on
# `.path` is what makes the answer about the review and not about CI. And `last` must be
# taken after `sort_by(.run_number)` — the API's own order is newest-first, so an unsorted
# `last` reads the OLDEST run and reports a superseded run's status.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

WFPATH='.github/workflows/claude-review.yml'
OLD='[.workflow_runs[] | select(.path == "'"$WFPATH"'")] // [] | sort_by(.run_number) | last | .status // "none"'
SEL='[(.workflow_runs // [])[] | select(.path == "'"$WFPATH"'")] | sort_by(.run_number)'
# The skill's form: "<status> <conclusion>", empty string when there is no run at all.
NEW_SKILL="$SEL"' | last | if . == null then "" else "\(.status) \(.conclusion // "")" end'
# The hook's form: the bare status, "none" when there is no run at all.
NEW_HOOK="$SEL"' | last | .status // "none"'

r() { printf '{"path":"%s","run_number":%s,"status":"%s","conclusion":%s}' "$1" "$2" "$3" "$4"; }
CI_RUN=$(r '.github/workflows/ci.yml' 9 completed '"success"')

F_DONE='{"workflow_runs":['$(r "$WFPATH" 3 completed '"success"')']}'
F_FAILED='{"workflow_runs":['$(r "$WFPATH" 3 completed '"failure"')']}'
F_RUNNING='{"workflow_runs":['$(r "$WFPATH" 3 in_progress null)']}'
F_QUEUED='{"workflow_runs":['$(r "$WFPATH" 3 queued null)']}'
F_OTHER_ONLY='{"workflow_runs":['"$CI_RUN"']}'
F_EMPTY='{"workflow_runs":[]}'
F_NULL='{}'
# Newest run LAST by run_number, but the API hands them back newest-FIRST. Without the sort,
# `last` would read run 3 (superseded, completed) and report the review as done while run 7
# is still going.
F_SUPERSEDED='{"workflow_runs":['$(r "$WFPATH" 7 in_progress null)','"$CI_RUN"','$(r "$WFPATH" 3 completed '"success"')']}'

run() { printf '%s' "$2" | jq -r "$1" 2>/dev/null; }
rc_of() { printf '%s' "$2" | jq -r "$1" >/dev/null 2>&1; echo $?; }

section "Regression: the unguarded expression aborts when .workflow_runs is null"
assert_eq "old expr rc on null field" "5" "$(rc_of "$OLD" "$F_NULL")"

section "Regression: a trailing '// []' never fires (dead guard)"
# If the guard worked, the null fixture would yield "none" at rc=0 like the new expression.
assert_eq "'// []' after the array literal does not rescue null" "5" "$(rc_of "$OLD" "$F_NULL")"

section "Fixed expressions survive every fixture at rc=0"
for name in DONE FAILED RUNNING QUEUED OTHER_ONLY EMPTY NULL SUPERSEDED; do
  eval "fx=\$F_$name"
  assert_eq "skill expr rc=0 on $name" "0" "$(rc_of "$NEW_SKILL" "$fx")"
  assert_eq "hook expr  rc=0 on $name" "0" "$(rc_of "$NEW_HOOK"  "$fx")"
done

section "The skill's expression reports status and conclusion"
assert_eq "completed success"  "completed success"  "$(run "$NEW_SKILL" "$F_DONE")"
assert_eq "completed failure"  "completed failure"  "$(run "$NEW_SKILL" "$F_FAILED")"
assert_eq "in_progress"        "in_progress "       "$(run "$NEW_SKILL" "$F_RUNNING")"
assert_eq "no review run"      ""                   "$(run "$NEW_SKILL" "$F_OTHER_ONLY")"
assert_eq "empty list"         ""                   "$(run "$NEW_SKILL" "$F_EMPTY")"
assert_eq "null field"         ""                   "$(run "$NEW_SKILL" "$F_NULL")"

section "The hook's expression reports the bare status"
assert_eq "completed"     "completed"   "$(run "$NEW_HOOK" "$F_DONE")"
assert_eq "in_progress"   "in_progress" "$(run "$NEW_HOOK" "$F_RUNNING")"
assert_eq "queued"        "queued"      "$(run "$NEW_HOOK" "$F_QUEUED")"
assert_eq "no review run" "none"        "$(run "$NEW_HOOK" "$F_OTHER_ONLY")"
assert_eq "null field"    "none"        "$(run "$NEW_HOOK" "$F_NULL")"

section "Another workflow's run is never mistaken for the review"
# CI finishing first is the normal case, and reading it as the review would merge every PR
# before the review ever posted.
assert_eq "ci.yml only → skill sees no run"  ""     "$(run "$NEW_SKILL" "$F_OTHER_ONLY")"
assert_eq "ci.yml only → hook sees no run"   "none" "$(run "$NEW_HOOK"  "$F_OTHER_ONLY")"

section "A superseded run never masks the current one"
assert_eq "skill takes the highest run_number" "in_progress " "$(run "$NEW_SKILL" "$F_SUPERSEDED")"
assert_eq "hook takes the highest run_number"  "in_progress"  "$(run "$NEW_HOOK"  "$F_SUPERSEDED")"

section "Pending detection (the decision the call sites actually make)"
review_pending() {
  case "$(run "$NEW_HOOK" "$1")" in
    completed) echo no ;;
    *)         echo yes ;;
  esac
}
assert_eq "in_progress → pending"        "yes" "$(review_pending "$F_RUNNING")"
assert_eq "queued      → pending"        "yes" "$(review_pending "$F_QUEUED")"
assert_eq "superseded  → pending"        "yes" "$(review_pending "$F_SUPERSEDED")"
assert_eq "completed   → not pending"    "no"  "$(review_pending "$F_DONE")"
# A red review job is still a finished review. CI's own gate is what reports the failure;
# waiting past it here would ride every failed review to the 15-minute cap.
assert_eq "completed failure → not pending" "no" "$(review_pending "$F_FAILED")"
# The important one: a null field must be indistinguishable from "no data", and the call
# site must not silently conclude "no run" from a crashed jq.
assert_eq "null field  → pending (rc was 0, not a swallowed crash)" "yes" "$(review_pending "$F_NULL")"

section "Live call sites use the guarded expression"
ROOT="${CLAUDE_ROOT:-$HOME/.claude}"
# `found` guards against all of them being absent, which would skip every assertion below and
# read as a pass.
found=0
for f in "$ROOT/skills/automerge/SKILL.md" "$ROOT/hooks/automerge-rewake.sh"; do
  [ -f "$f" ] || continue
  found=$((found+1)); body=$(cat "$f")
  # The needle is the code form, not the prose form: both files quote `[.workflow_runs[]...]`
  # in a comment explaining why the guard exists.
  assert_not_contains "$(basename "$f"): no unguarded [.workflow_runs[] | select" \
    "$body" '[.workflow_runs[] | select'
  assert_contains "$(basename "$f"): uses (.workflow_runs // [])[]" \
    "$body" '(.workflow_runs // [])[]'
  assert_contains "$(basename "$f"): selects the review workflow by path" \
    "$body" "$WFPATH"
  assert_contains "$(basename "$f"): sorts before taking last" \
    "$body" 'sort_by(.run_number) | last'
done
[ "$found" -ge 2 ] || bad "expected the automerge skill and the hook, found $found"

summary
