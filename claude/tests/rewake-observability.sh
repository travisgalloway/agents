#!/usr/bin/env bash
# rewake-observability.sh — pin the "cannot observe → do not report clean" rule in
# hooks/automerge-rewake.sh, and the merge-first wording of its all-clear message.
#
# THE BUG: the hook decided "nothing is pending" from two `gh … 2>/dev/null` calls whose
# failure is indistinguishable from an empty result. A network/auth/rate-limit error
# therefore fell straight through to the else branch, which injects "nothing is pending —
# proceed to the merge". Unobservable was reported as clean, and the message told the agent
# to merge a PR whose CI the hook had never managed to read.
#
# The same file already applies the correct rule to `pr_state` ("an empty result is a FAILED
# lookup … Unknown = keep the sentinel"); these assertions extend it to the other two probes.
#
# Also pinned here: the all-clear message must lead with the merge. The earlier wording
# ("resume at §2.5, re-check for new comments, and if clean proceed to the merge") is a
# multi-step instruction, and the failure being guarded against is an agent that stops
# halfway through exactly that sequence.
#
# All `gh` calls are served by a stub on PATH, so this test makes no network calls.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

HOOK="$HOME/.claude/hooks/automerge-rewake.sh"
[ -f "$HOOK" ] || { bad "hook not found at $HOOK"; summary; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rewake-obs.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@example.com; git config --global user.name Test

REPO="$WORK/repo"; mkdir -p "$REPO/.claude"
git -C "$REPO" init -q; echo x > "$REPO/x"; git -C "$REPO" add -A; git -C "$REPO" commit -qm x

# --- gh stub -------------------------------------------------------------------
# GH_FAIL=1 makes the combined status probe fail the way a real outage does: a message on
# stderr, a non-zero exit, and nothing on stdout.
#
# GH_ROLLUP has NO default on purpose. `${GH_ROLLUP:-{"...":[]}}` looks harmless but the
# default's own closing brace ends the parameter expansion early, so a stray `}` is appended
# to every response — malformed JSON, jq aborts, and the hook correctly goes silent. That
# made the "clean" and "pending" cases below pass for entirely the wrong reason. An unset
# variable is loud instead: the stub says so and fails.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *statusCheckRollup*)
    [ "${GH_FAIL:-0}" = "1" ] && { echo "gh: could not connect to api.github.com" >&2; exit 1; }
    [ -n "${GH_ROLLUP:-}" ] || { echo "stub misuse: GH_ROLLUP unset" >&2; exit 64; }
    printf '%s\n' "$GH_ROLLUP" ;;
  "pr list"*)
    [ "${GH_LIST_FAIL:-0}" = "1" ] && { echo "gh: could not connect to api.github.com" >&2; exit 1; }
    printf '%s\n' "${GH_PR_LIST:-OPEN}" ;;
  *"--json state"*) printf '%s\n' "${GH_PR_STATE:-OPEN}" ;;
  *contents/.github/workflows/claude-review.yml*)
    # The review-workflow probe. "notfound" is gh's own 404 text, which is the ONLY answer
    # that may be read as "this repo has no review workflow"; "fail" is any other outage.
    case "${GH_WF:-0123456789abcdef0123456789abcdef01234567}" in
      notfound) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      fail)     echo "gh: could not connect to api.github.com" >&2; exit 1 ;;
      *)        printf '%s\n' "${GH_WF:-0123456789abcdef0123456789abcdef01234567}" ;;
    esac ;;
  *actions/runs*)
    [ "${GH_RUN_FAIL:-0}" = "1" ] && { echo "gh: could not connect to api.github.com" >&2; exit 1; }
    # `-` not `:-`: a deliberately EMPTY GH_RUN must stay empty, which is what an
    # unreadable answer looks like. Only an unset GH_RUN gets the default.
    printf '%s\n' "${GH_RUN-completed}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

# Guard against the stub silently answering nothing — the trap tests/README.md calls out.
probe_json='{"statusCheckRollup":[],"headRefOid":"abc123"}'
GH_ROLLUP="$probe_json" gh pr view 1 --json statusCheckRollup,headRefOid \
  | grep -Fqx "$probe_json" \
  || { bad "gh stub does not echo GH_ROLLUP verbatim — every assertion below is void"; summary; exit 1; }

MINE=aaaaaaaa-1111-2222-3333-444444444444

arm() {   # arm — write a live, owned automerge sentinel for PR 1
  rm -f "$REPO"/.claude/*active* 2>/dev/null
  printf '{"pr":1,"owner":"o","repo":"r","session":"%s"}\n' "$MINE" \
    > "$REPO/.claude/automerge-active-1"
}

# probe [VAR=VAL ...] — run the hook with those env vars; sets $RC and $out.
# Not a command substitution: that runs in a subshell, so an exit code assigned inside it
# would never reach the assertions.
# REWAKE_NUDGE_INTERVAL=0 by default: most sections here fire the hook several times in a row
# to inspect its message, and the real 10-minute debounce would silence every run after the
# first. A caller can override it by passing REWAKE_NUDGE_INTERVAL=... in "$@" (later env
# assignments win), which the debounce section below relies on.
ERRF="$WORK/err"; RC=0; out=""; PAYLOAD='{"hook_event_name":"Stop"}'
probe() {
  ( cd "$REPO" && CLAUDE_CODE_SESSION_ID="$MINE" env REWAKE_NUDGE_INTERVAL=0 "$@" \
      bash "$HOOK" <<< "$PAYLOAD" 2>"$ERRF" >/dev/null )
  RC=$?
  out=$(cat "$ERRF" 2>/dev/null)
}

# Every fixture carries headRefOid: the hook keys its review lookup on the head commit, and
# a fixture without one skips that lookup entirely — which would leave the review path in
# this suite untested while every assertion still passed.
CLEAN='{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"headRefOid":"abc123"}'
PENDING='{"statusCheckRollup":[{"status":"IN_PROGRESS"}],"headRefOid":"abc123"}'
LEGACY='{"statusCheckRollup":[{"state":"PENDING"}],"headRefOid":"abc123"}'
BROKEN='{"statusCheckRollup":"not-an-array","headRefOid":"abc123"}'

section "A failed lookup is NOT 'nothing is pending'"
arm; probe GH_FAIL=1
assert_eq "exit 0 (silent) when gh is unreachable" "0" "$RC"
assert_not_contains "no merge instruction from an unreadable state" "$out" "MERGE IT NOW"
[ -f "$REPO/.claude/automerge-active-1" ] \
  && ok "sentinel kept, so the guard stays armed" \
  || bad "sentinel deleted on a failed lookup — guard disarmed"

section "A malformed response is also unobservable, not clean"
arm; probe GH_ROLLUP="$BROKEN"
assert_eq "exit 0 (silent) when jq cannot read the rollup" "0" "$RC"
assert_not_contains "no merge instruction from a broken payload" "$out" "MERGE IT NOW"
[ -f "$REPO/.claude/automerge-active-1" ] \
  && ok "sentinel kept" || bad "sentinel deleted on a malformed response"

section "Genuinely clean → rewake, leading with the merge"
arm; probe GH_ROLLUP="$CLEAN"
assert_eq "exit 2 (rewake)" "2" "$RC"
assert_contains "message leads with the merge" "$out" "MERGE IT NOW"
assert_contains "and demands the merge be verified" "$out" "MERGED"
# The old multi-step opener is what the agent kept stopping halfway through.
assert_not_contains "no 'resume at §2.5' preamble" "$out" "Resume /automerge at §2.5"

section "Genuinely pending → rewake, but do not suggest merging"
arm; probe GH_ROLLUP="$PENDING"
assert_eq "exit 2 (rewake) with CI in progress" "2" "$RC"
assert_contains "reports still pending" "$out" "still pending"
assert_not_contains "does not instruct a merge" "$out" "MERGE IT NOW"

arm; probe GH_ROLLUP="$LEGACY"
assert_contains "StatusContext .state=PENDING also counts as pending" "$out" "still pending"

section "A review still running blocks the merge instruction"
# CI is green and the rollup says nothing is pending. Between the push and the review run
# appearing in that rollup, this is exactly the window the hook used to merge in.
arm; probe GH_ROLLUP="$CLEAN" GH_RUN="in_progress"
assert_eq "exit 2 (rewake) with the review in progress" "2" "$RC"
assert_contains "reports still pending" "$out" "still pending"
assert_not_contains "does not instruct a merge while the review runs" "$out" "MERGE IT NOW"

arm; probe GH_ROLLUP="$CLEAN" GH_RUN="queued"
assert_not_contains "a queued review also blocks the merge" "$out" "MERGE IT NOW"

# The run has not appeared at all: the jq default renders that as "none". Treating it as
# "no review" is the same collapse as treating an unreadable answer as clean, so it counts
# as pending and the 45-minute stall cap is what ends it.
arm; probe GH_ROLLUP="$CLEAN" GH_RUN="none"
assert_not_contains "a run that has not appeared yet blocks the merge" "$out" "MERGE IT NOW"

# An EMPTY answer is not "none" — jq always emits one or the other, so nothing at all means
# the call did not really answer. Silent, sentinel kept.
arm; probe GH_ROLLUP="$CLEAN" GH_RUN=""
assert_eq "exit 0 (silent) on an empty review answer" "0" "$RC"
assert_not_contains "no merge instruction from an empty answer" "$out" "MERGE IT NOW"

section "An unreadable review lookup is unobservable, not clean"
arm; probe GH_ROLLUP="$CLEAN" GH_RUN_FAIL=1
assert_eq "exit 0 (silent) when the runs lookup fails" "0" "$RC"
assert_not_contains "no merge instruction from an unreadable review" "$out" "MERGE IT NOW"
[ -f "$REPO/.claude/automerge-active-1" ] \
  && ok "sentinel kept, so the guard stays armed" \
  || bad "sentinel deleted on a failed review lookup — guard disarmed"

# A 500 from the workflow probe is not a 404. Only the 404 means "this repo has no review".
arm; probe GH_ROLLUP="$CLEAN" GH_WF=fail
assert_eq "exit 0 (silent) when the workflow probe fails" "0" "$RC"
assert_not_contains "no merge instruction from an unreachable probe" "$out" "MERGE IT NOW"

section "A repo with no review workflow still merges"
# The gate must not become an infinite hold on every repo that has not adopted the review.
arm; probe GH_ROLLUP="$CLEAN" GH_WF=notfound
assert_eq "exit 2 (rewake)" "2" "$RC"
assert_contains "instructs the merge" "$out" "MERGE IT NOW"

arm_work() {   # arm_work [branch] — live, owned /work sentinel for issue 9
  rm -f "$REPO"/.claude/*active* 2>/dev/null
  if [ -n "${1:-}" ]; then
    printf '{"issue":9,"stage":"exec","branch":"%s","owner":"o","repo":"r","session":"%s"}\n' \
      "$1" "$MINE" > "$REPO/.claude/work-active-9"
  else
    printf '{"issue":9,"stage":"exec","owner":"o","repo":"r","session":"%s"}\n' \
      "$MINE" > "$REPO/.claude/work-active-9"
  fi
}

section "The /work message states what it observed, not a verdict"
# THE BUG: it opened with "the session went idle — this is the dispatch-then-idle stall", a
# diagnosis the hook has no way to make. A sentinel is armed before dispatch and removed at
# stage end, so its presence says a stage EXISTS, not that the session idled.
arm_work f/9; probe
assert_eq "exit 2 (rewake)" "2" "$RC"
assert_not_contains "no longer asserts the session idled" "$out" "the session went idle"
assert_contains "says what it actually observed" "$out" "What this hook observed"
assert_contains "admits it cannot tell idle from a finished reply" "$out" "whether you idled"
# TaskList is the TaskCreate to-do board; it has never listed monitors, teammates or shells.
# The message used to call it an under-reporter and send the model to check it as a fallback,
# which is a check that answers "nothing" unconditionally. It must now steer AWAY from it.
assert_contains "steers the model off TaskList" "$out" "Do NOT check TaskList"
assert_not_contains "no longer calls TaskList an under-reporter" "$out" "under-reports"
assert_contains "arms a monitor when nothing is watching" "$out" "arm one"
# The re-poke must carry work.md's own threshold. Unconditional re-poking at the observed
# ~5s cadence injected context into the teammate ~120x more often than the skill sanctions.
assert_contains "re-poke is gated on the 10-minute threshold" "$out" "10 minutes with no progress"
# And a proportionate answer must be legitimate — the old text closed on a bare "Do not idle",
# leaving no cheap-but-honest response available.
assert_contains "permits a short answer when the stage is moving" "$out" "a short answer is the correct one"

section "/work PR state distinguishes observed / failed / unqueried"
# The old assertion here matched the bare substring "PR ", which the static prose "PR state
# above" already satisfies — it passed whether or not the interpolation worked at all. Anchor
# on the rendered value instead. (tests/README.md's trap #1, in its subtler form.)
arm_work f/9; probe GH_PR_LIST=OPEN
assert_contains "an OBSERVED state is rendered verbatim" "$out" "PR OPEN"

arm_work f/9; probe GH_LIST_FAIL=1
assert_contains "a FAILED lookup says so" "$out" "PR lookup-failed"
assert_not_contains "and is never rendered as an observed absence" "$out" "PR none"

arm_work ""; probe
assert_contains "no branch on the sentinel → not-queried" "$out" "PR not-queried"
assert_contains "message warns these two are not evidence" "$out" "lookup-failed"

section "SubagentStop: guards the merge, never the /work stage"
# Exit 2 on SubagentStop means "show stderr to the subagent and continue having it run".
# For a stalled /automerge that is the whole point; for a work-exec subagent that finished
# legitimately it would loop a completed stage — and its sentinel is still on disk at that
# moment, because the ORCHESTRATOR tears it down after the subagent returns.
SUBAGENT='{"hook_event_name":"SubagentStop","agent_id":"a1","agent_type":"work-exec"}'

arm_work f/9; PAYLOAD="$SUBAGENT"; probe
assert_eq "live /work sentinel → exit 0, does NOT nudge the subagent" "0" "$RC"
assert_not_contains "no in-flight message to a finished stage" "$out" "looks UNWATCHED"

arm; PAYLOAD="$SUBAGENT"; probe GH_ROLLUP="$CLEAN"
assert_eq "clean automerge sentinel → exit 2 (continue the subagent)" "2" "$RC"
assert_contains "and tells it to merge" "$out" "MERGE IT NOW"

arm; PAYLOAD="$SUBAGENT"; probe GH_FAIL=1
assert_eq "unreadable state still stays silent on SubagentStop" "0" "$RC"

# No regression: Stop still reaches the /work branch with the same state on disk.
arm_work f/9; PAYLOAD='{"hook_event_name":"Stop"}'; probe
assert_eq "Stop still rewakes for a live /work stage" "2" "$RC"
assert_contains "with the /work message" "$out" "looks UNWATCHED"

section "A firing count is not a stall — the cap must never trip on chatter"
# THE BUG THIS REPLACES. The cap used to be `.rewakes >= MAX_REWAKES=20`, a count of hook
# FIRINGS. This hook fires once per Stop/TeammateIdle, so an idle-looping session produced
# ~20 in four minutes and demanded teardown of four /work stages that were at 2-17% of their
# budgets with files landing. All four went on to merge. Nothing about a firing count can
# distinguish a stalled stage from a talkative session.
PLANC=$(sed -n 's/^: "${REWAKE_STALL_CAP_PLAN:=\$((\([0-9]*\) \* 60))}".*/\1/p' "$HOOK" | head -1)
EXECC=$(sed -n 's/^: "${REWAKE_STALL_CAP_EXEC:=\$((\([0-9]*\) \* 60))}".*/\1/p' "$HOOK" | head -1)
assert_eq "plan no-progress cap parsed from the hook (minutes)" "30" "$PLANC"
assert_eq "exec no-progress cap parsed from the hook (minutes)" "45" "$EXECC"

# Negative control first: an ordinary rewake must carry no notice. Without this, a hook that
# emitted it unconditionally would pass every assertion below.
arm_work f/9; probe
assert_eq "ordinary rewake" "2" "$RC"
assert_not_contains "no cap notice on an ordinary rewake" "$out" "No observable progress"

# 40 firings — double the old cap — with the real 45-minute exec threshold in force. Seconds
# of wall clock have passed, so this stage is not stalled and must not be capped.
arm_work f/9; echo 40 > "$REPO/.claude/work-active-9.rewakes"; probe
assert_eq "40 firings: still an ordinary rewake" "2" "$RC"
assert_not_contains "40 firings alone never cap" "$out" "No observable progress"
[ -f "$REPO/.claude/work-active-9.capped" ] \
  && bad "chatter capped a healthy stage" "the exact regression this replaces" \
  || ok "no .capped marker written from firing count alone"

section "No observable progress DOES cap — exactly once, with its evidence"
# REWAKE_STALL_CAP_EXEC=0 makes any *unchanged* sample count as stalled. The first sample is
# only ever a baseline, so it takes two rounds.
arm_work f/9; probe REWAKE_STALL_CAP_EXEC=0
assert_eq "first sample is a baseline, not a stall" "2" "$RC"
assert_not_contains "baseline round raises no notice" "$out" "No observable progress"

probe REWAKE_STALL_CAP_EXEC=0
assert_eq "at the cap: exit 2 so the notice is actually shown" "2" "$RC"
assert_contains "at the cap: names the capped stage" "$out" "#9 (exec,"
assert_contains "at the cap: says no reminder is coming" "$out" "no later reminder coming"
assert_contains "at the cap: demands teardown, not just a blocker" "$out" "teardown"
# The notice asks for a destructive action on evidence the hook admits is partial, so it must
# say what it measured and what it cannot see. Without this it is the old bare assertion that
# could not be judged — which is why all four were declined by hand.
assert_contains "at the cap: quotes the no-progress duration" "$out" "no change in"
assert_contains "at the cap: names its own blind spot" "$out" "uncommitted edits"
assert_contains "at the cap: says to check before acting" "$out" "status --porcelain"

probe REWAKE_STALL_CAP_EXEC=0
assert_eq "second run at the cap: silent" "0" "$RC"
assert_not_contains "second run at the cap: nothing emitted" "$out" "No observable progress"

section "Observed progress resets the gate"
# The plan file's mtime is one third of the /work fingerprint — it is what makes a plan stage
# observable at all, since one produces no commits and no PR for its whole legitimate life.
mkdir -p "$REPO/.claude/plans"
arm_work f/9; : > "$REPO/.claude/plans/issue-9.md"
probe REWAKE_STALL_CAP_EXEC=0
assert_eq "baseline" "2" "$RC"

touch -t "$(date -v+1M +%Y%m%d%H%M 2>/dev/null || date -d '+1 minute' +%Y%m%d%H%M)" \
  "$REPO/.claude/plans/issue-9.md"
probe REWAKE_STALL_CAP_EXEC=0
assert_eq "a moved fingerprint is not a stall, even at a 0s cap" "2" "$RC"
assert_not_contains "progress means no cap notice" "$out" "No observable progress"

# And once it stops moving again, the gate re-arms from the NEW observation, not the old one.
probe REWAKE_STALL_CAP_EXEC=0
assert_contains "stalling again after progress caps again" "$out" "No observable progress"
rm -f "$REPO/.claude/plans/issue-9.md"

section "A stage that resumes after a cap gets its guard back"
# progress_gate() clears .capped whenever the fingerprint moves. Without that, one bad
# stretch silences the guard permanently — including for the merge stall, the quietest one.
arm_work f/9; : > "$REPO/.claude/plans/issue-9.md"
probe REWAKE_STALL_CAP_EXEC=0; probe REWAKE_STALL_CAP_EXEC=0
[ -f "$REPO/.claude/work-active-9.capped" ] || bad "expected a .capped marker to clear"
touch -t "$(date -v+1M +%Y%m%d%H%M 2>/dev/null || date -d '+1 minute' +%Y%m%d%H%M)" \
  "$REPO/.claude/plans/issue-9.md"
probe REWAKE_STALL_CAP_EXEC=0
[ -f "$REPO/.claude/work-active-9.capped" ] \
  && bad ".capped survived observed progress" "the stage stays silenced forever" \
  || ok "progress clears .capped, so a second stall can be raised"
rm -f "$REPO/.claude/plans/issue-9.md"

section "An UNOBSERVABLE stage can never be capped"
# The blind-monitor rule, applied to the cap: a failed lookup is UNKNOWN, never "nothing
# happened". Capping on it would tear down a live stage because gh was briefly unreachable.
arm_work f/9
probe REWAKE_STALL_CAP_EXEC=0 GH_LIST_FAIL=1
probe REWAKE_STALL_CAP_EXEC=0 GH_LIST_FAIL=1
probe REWAKE_STALL_CAP_EXEC=0 GH_LIST_FAIL=1
assert_eq "still an ordinary rewake" "2" "$RC"
assert_not_contains "unreadable state never caps" "$out" "No observable progress"
[ -f "$REPO/.claude/work-active-9.progress" ] \
  && bad ".progress written from an unobservable round" "an unknown recorded as a sample" \
  || ok "no .progress written when the wait could not be observed"

section "A stale .progress is treated as absent, not as an ancient stall"
# Same staleness rule as .rewakes and .capped: one older than its sentinel describes a
# PREVIOUS run. Inheriting it would cap a freshly armed stage on its very first sample.
arm_work f/9
printf '%s %s\n' 0 'nobranch|noplan|OPEN' > "$REPO/.claude/work-active-9.progress"
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '-2 hours' +%Y%m%d%H%M)" \
  "$REPO/.claude/work-active-9.progress"
probe REWAKE_STALL_CAP_EXEC=0
assert_eq "fresh stage is not capped by a previous run's sample" "2" "$RC"
assert_not_contains "and raises no notice" "$out" "No observable progress"

section "A re-armed stage gets its cap notice again"
# .capped follows the same staleness rule. Age the marker, leave the sentinel fresh.
arm_work f/9; probe REWAKE_STALL_CAP_EXEC=0; probe REWAKE_STALL_CAP_EXEC=0
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '-2 hours' +%Y%m%d%H%M)" \
  "$REPO/.claude/work-active-9.capped"
probe REWAKE_STALL_CAP_EXEC=0
assert_eq "stale marker is ignored → notice fires again" "2" "$RC"
assert_contains "and names the stage" "$out" "#9 (exec,"

section "A capped PR is not dropped when a /work stage is live"
# THE SECOND BUG. Issue 9 live and uncapped; PR 1 capped. Both must appear in one message.
# Only the AUTOMERGE threshold is zeroed, so this doubles as proof that the thresholds are
# genuinely per-stage: the exec stage sits at its real 45m and stays live throughout.
rm -f "$REPO"/.claude/*active* 2>/dev/null
printf '{"issue":9,"stage":"exec","branch":"f/9","owner":"o","repo":"r","session":"%s"}\n' "$MINE" \
  > "$REPO/.claude/work-active-9"
printf '{"pr":1,"owner":"o","repo":"r","session":"%s"}\n' "$MINE" \
  > "$REPO/.claude/automerge-active-1"
probe REWAKE_STALL_CAP_AUTOMERGE=0 GH_ROLLUP="$CLEAN"
probe REWAKE_STALL_CAP_AUTOMERGE=0 GH_ROLLUP="$CLEAN"
assert_eq "exit 2" "2" "$RC"
assert_contains "the /work stage is reported" "$out" "looks UNWATCHED"
assert_contains "AND the capped PR rides along" "$out" "PR #1 (automerge,"
# Anchor on the CAPPED rendering specifically. The live listing legitimately reads
# "#9 (exec, f/9, PR OPEN)", so a bare "#9 (exec," would match the healthy message too and
# could never fail — tests/README.md's trap #1.
assert_contains "the exec stage is listed as LIVE" "$out" "#9 (exec, f/9, PR OPEN,"
assert_not_contains "the live exec stage is NOT capped at its real threshold" \
  "$out" "#9 (exec, no change in"

section "The debounce DEFERS a due cap notice — it must never lose one"
# The debounce sits before the gh lookup, so a debounced round evaluates no cap at all. That
# is deliberate (it is what keeps this at ~6 API calls an hour per stage instead of ~720), and
# it means a cap notice can be delayed by up to one nudge interval. What must NOT happen is
# losing it: the notice is once-only and final ("there is no later reminder coming"), so if a
# debounced round consumed it, the blocker would vanish with nothing to recover it.
arm_work f/9
probe REWAKE_STALL_CAP_EXEC=0            # baseline sample
probe REWAKE_STALL_CAP_EXEC=0            # trips the cap, marker written
assert_contains "cap notice raised when not debounced" "$out" "No observable progress"

# Re-arm so a fresh notice is due, then fire with the debounce ACTIVE.
arm_work f/9
probe REWAKE_STALL_CAP_EXEC=0                                   # baseline for the new sentinel
probe REWAKE_STALL_CAP_EXEC=0 REWAKE_NUDGE_INTERVAL=99999
assert_eq "a debounced round is silent" "0" "$RC"
[ -f "$REPO/.claude/work-active-9.capped" ] \
  && bad "the debounced round consumed the once-only notice" "the blocker is now unrecoverable" \
  || ok "the notice is NOT consumed — no .capped marker written"

# Once the interval passes, the deferred notice arrives. Age the counter, since its mtime is
# what the debounce reads.
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '-2 hours' +%Y%m%d%H%M)" \
  "$REPO/.claude/work-active-9.rewakes"
probe REWAKE_STALL_CAP_EXEC=0 REWAKE_NUDGE_INTERVAL=99999
assert_eq "and is delivered on the next eligible round" "2" "$RC"
assert_contains "carrying the cap notice" "$out" "No observable progress"

section "The gate and the debounce are both env-overridable, like the stall caps"
# reap-orphans.conf's convention: `: \"\${VAR:=default}\"`, so tests drive them without
# sleeping. A hardcoded 10 minutes would make every case above a 10-minute test.
assert_contains "nudge interval is overridable" \
  "$(cat "$HOOK")" ': "${REWAKE_NUDGE_INTERVAL:='
NUDGEI=$(sed -n 's/^: "${REWAKE_NUDGE_INTERVAL:=\$((\([0-9]*\) \* 60))}".*/\1/p' "$HOOK" | head -1)
assert_eq "and defaults to work.md's 10-minute re-poke threshold" "10" "$NUDGEI"

section "Side files are never mistaken for sentinels"
# All three globs (work-active-* / automerge-active-*) match every side file too.
assert_contains "hook skips all three suffixes" \
  "$(cat "$HOOK")" '*.rewakes|*.capped|*.progress) continue'
assert_contains "session-cleanup skips all three" \
  "$(cat "$HOME/.claude/hooks/session-cleanup.sh")" '*.rewakes|*.capped|*.progress) continue'
assert_contains "session-cleanup removes .capped" \
  "$(cat "$HOME/.claude/hooks/session-cleanup.sh")" '"$sentinel.capped"'
assert_contains "session-cleanup removes .progress" \
  "$(cat "$HOME/.claude/hooks/session-cleanup.sh")" '"$sentinel.progress"'
# Every self-heal path in the hook goes through one helper that knows the whole set — five
# open-coded `rm -f "$sentinel" "$counter"` sites each used to leave .capped behind.
assert_contains "hook has a single teardown helper" \
  "$(cat "$HOOK")" 'rm -f "$1" "$1.rewakes" "$1.capped" "$1.progress"'
# Strip comments first — the helper's own docstring quotes the pattern it replaced.
if grep -v '^[[:space:]]*#' "$HOOK" | grep -q 'rm -f "\$sentinel" "\$counter"'; then
  bad "a self-heal path still open-codes its rm" "it will leak whichever side file it forgot"
else
  ok "no self-heal path open-codes its rm"
fi

summary
