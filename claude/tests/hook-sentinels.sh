#!/usr/bin/env bash
# hook-sentinels.sh — pin the ownership/expiry ordering in hooks/automerge-rewake.sh.
#
# THE BUG: `expired()` runs BEFORE `mine()` in both sentinel loops, so this session's hook
# deletes a *foreign* session's sentinel once it passes a wall-clock cap. The script's own
# contract says the opposite: "A sentinel owned by a different session is not ours to act on
# OR delete: its own session's hooks are responsible for it."
#
# Deleting a foreign sentinel silently disarms that session's stall guard.
#
# All `gh` calls are served by a stub on PATH, so this test makes no network calls.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

HOOK="$HOME/.claude/hooks/automerge-rewake.sh"
[ -f "$HOOK" ] || { bad "hook not found at $HOOK"; summary; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/hook-sent.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@example.com; git config --global user.name Test

REPO="$WORK/repo"; mkdir -p "$REPO/.claude"
git -C "$REPO" init -q; echo x > "$REPO/x"; git -C "$REPO" add -A; git -C "$REPO" commit -qm x

# --- gh stub -------------------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal gh stub. GH_PR_STATE / GH_REVIEWERS / GH_CHECKS drive the responses.
case "$1 $2" in
  "pr view")
    case "$*" in
      *reviewRequests*) printf '%s\n' "${GH_REVIEWERS:-}" ;;
      *state*)          printf '%s\n' "${GH_PR_STATE:-OPEN}" ;;
      *)                printf '\n' ;;
    esac ;;
  "pr checks") printf '%s\n' "${GH_CHECKS:-lint\tpass\t1s}" ;;
  "pr list")   printf '%s\n' "${GH_PR_LIST_STATE:-}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

MINE=aaaaaaaa-1111-2222-3333-444444444444
THEIRS=bbbbbbbb-5555-6666-7777-888888888888

sentinel() {   # sentinel <file> <json> [age_hours]
  printf '%s\n' "$2" > "$REPO/.claude/$1"
  if [ -n "${3:-}" ]; then
    touch -t "$(date -v-"$3"H +%Y%m%d%H%M 2>/dev/null || date -d "-$3 hours" +%Y%m%d%H%M)" \
      "$REPO/.claude/$1"
  fi
}

# REWAKE_NUDGE_INTERVAL=0 disables the nudge debounce for the cases below, which drive
# several firings back-to-back. The debounce itself is exercised in its own section.
run_hook() {   # run_hook -> prints exit code
  ( cd "$REPO" && CLAUDE_CODE_SESSION_ID="$MINE" REWAKE_NUDGE_INTERVAL=0 \
      bash "$HOOK" <<< '{"hook_event_name":"Stop"}' >/dev/null 2>&1; echo $? )
}

# Same, with the no-progress caps forced to 0 so a single unchanged sample trips them.
# The caps are wall-clock, so without an override a cap test would have to sleep for
# 30 real minutes; they are env-overridable precisely so this suite can drive them.
run_hook_capped() {
  ( cd "$REPO" && CLAUDE_CODE_SESSION_ID="$MINE" REWAKE_NUDGE_INTERVAL=0 \
      REWAKE_STALL_CAP_PLAN=0 REWAKE_STALL_CAP_EXEC=0 REWAKE_STALL_CAP_AUTOMERGE=0 \
      bash "$HOOK" <<< '{"hook_event_name":"Stop"}' >/dev/null 2>&1; echo $? )
}

# With the debounce at its real value, and an arbitrary payload.
run_hook_payload() {   # run_hook_payload <json>
  ( cd "$REPO" && CLAUDE_CODE_SESSION_ID="$MINE" \
      bash "$HOOK" <<< "$1" >/dev/null 2>&1; echo $? )
}

reset() { rm -f "$REPO"/.claude/*active* 2>/dev/null; }

section "Foreign session's EXPIRED automerge sentinel must survive"
reset
sentinel automerge-active-1 "{\"pr\":1,\"owner\":\"o\",\"repo\":\"r\",\"session\":\"$THEIRS\"}" 3
run_hook >/dev/null
if [ -f "$REPO/.claude/automerge-active-1" ]; then
  ok "foreign expired automerge sentinel survived"
else
  bad "foreign expired automerge sentinel was deleted" "expired() runs before mine()"
fi

section "Foreign session's EXPIRED work sentinel must survive"
reset
sentinel work-active-2 "{\"issue\":2,\"stage\":\"plan\",\"branch\":\"f/2\",\"owner\":\"o\",\"repo\":\"r\",\"session\":\"$THEIRS\"}" 3
run_hook >/dev/null
if [ -f "$REPO/.claude/work-active-2" ]; then
  ok "foreign expired work sentinel survived"
else
  bad "foreign expired work sentinel was deleted" "expired() runs before mine()"
fi

section "Own EXPIRED sentinels are still swept (self-heal must keep working)"
reset
sentinel automerge-active-3 "{\"pr\":3,\"owner\":\"o\",\"repo\":\"r\",\"session\":\"$MINE\"}" 3
sentinel work-active-4 "{\"issue\":4,\"stage\":\"plan\",\"branch\":\"f/4\",\"owner\":\"o\",\"repo\":\"r\",\"session\":\"$MINE\"}" 3
run_hook >/dev/null
[ -f "$REPO/.claude/automerge-active-3" ] \
  && bad "own expired automerge sentinel not swept" || ok "own expired automerge sentinel swept"
[ -f "$REPO/.claude/work-active-4" ] \
  && bad "own expired work sentinel not swept" || ok "own expired work sentinel swept"

section "Foreign LIVE sentinel: no rewake, and left untouched"
reset
sentinel work-active-5 "{\"issue\":5,\"stage\":\"exec\",\"branch\":\"f/5\",\"owner\":\"o\",\"repo\":\"r\",\"session\":\"$THEIRS\"}"
rc=$(run_hook)
assert_eq "exit 0 (silent, not ours)" "0" "$rc"
[ -f "$REPO/.claude/work-active-5" ] && ok "foreign live sentinel untouched" \
  || bad "foreign live sentinel deleted"

section "Own LIVE sentinel: rewakes"
reset
sentinel work-active-6 "{\"issue\":6,\"stage\":\"exec\",\"branch\":\"f/6\",\"owner\":\"o\",\"repo\":\"r\",\"session\":\"$MINE\"}"
rc=$(run_hook)
assert_eq "exit 2 (rewake)" "2" "$rc"

section "stop_hook_active must NOT short-circuit"
# Reversed deliberately. Honoring stop_hook_active capped this hook at ONE rewake per
# chain, because it is true on every stop that followed a hook-initiated continuation.
# That is precisely the second stop that needs the nudge: every wait this guards spans
# several turns by design. The run is still bounded by the no-progress caps, the
# wall-clock caps, and terminal-state self-heal — see the header comment on the
# `cat >/dev/null` drain.
reset
sentinel work-active-7 "{\"issue\":7,\"stage\":\"exec\",\"branch\":\"f/7\",\"owner\":\"o\",\"repo\":\"r\",\"session\":\"$MINE\"}"
rc=$( cd "$REPO" && CLAUDE_CODE_SESSION_ID="$MINE" \
        bash "$HOOK" <<< '{"stop_hook_active":true}' >/dev/null 2>&1; echo $? )
assert_eq "exit 2 (still rewakes on a continued stop)" "2" "$rc"

section "The nudge counter counts, but no longer caps"
# THE BUG THIS REPLACES: the cap used to be `.rewakes >= MAX_REWAKES`, i.e. a count of hook
# FIRINGS. This hook fires once per Stop/TeammateIdle — once per orchestrator turn-end — so a
# chatty session burned all 20 in ~4 minutes and demanded teardown of four healthy stages that
# were at 2-17% of their budgets with files landing. A firing counter measures how talkative
# the session is. It cannot tell that apart from a stage doing nothing.
#
# The counter survives as an informational figure quoted in the notice, so prove it still
# increments — and prove that reaching 20+ of them, on its own, caps NOTHING.
reset
sentinel work-active-8 "{\"issue\":8,\"stage\":\"exec\",\"branch\":\"f/8\",\"owner\":\"o\",\"repo\":\"r\",\"session\":\"$MINE\"}"
run_hook >/dev/null; run_hook >/dev/null; run_hook >/dev/null
assert_eq "counter reached 3 after 3 stops" "3" "$(cat "$REPO/.claude/work-active-8.rewakes" 2>/dev/null)"

grep -q '^MAX_REWAKES=' "$HOOK" \
  && bad "MAX_REWAKES is back" "the firing-count cap was the bug — the cap must be no-progress time" \
  || ok "no MAX_REWAKES constant (the cap is no-progress time, not firings)"

# 25 firings, well past the old cap of 20, with the stall caps at their real values. The
# stage never changes here, but only ~seconds pass — so it is NOT stalled, and must not cap.
echo 25 > "$REPO/.claude/work-active-8.rewakes"
assert_eq "still rewaking after 25 firings" "2" "$(run_hook)"
[ -f "$REPO/.claude/work-active-8.capped" ] \
  && bad "a firing count alone capped the stage" "this is the regression: chatter read as a stall" \
  || ok "25 firings raise no cap notice"

section "No observable progress DOES cap — once"
# Same stage, same unchanging fingerprint, but now the stall cap is 0s: the second sample
# is 'unchanged for >= the cap'. The first is only ever a baseline, never a stall.
reset
sentinel work-active-9 "{\"issue\":9,\"stage\":\"exec\",\"branch\":\"f/9\",\"owner\":\"o\",\"repo\":\"r\",\"session\":\"$MINE\"}"
assert_eq "first sample is a baseline, not a stall" "2" "$(run_hook_capped)"
[ -f "$REPO/.claude/work-active-9.progress" ] \
  && ok ".progress written with the observed fingerprint" || bad ".progress not written"
assert_eq "exit 2 once at the no-progress cap (the final blocker notice)" "2" "$(run_hook_capped)"
assert_eq "exit 0 on every stop after that" "0" "$(run_hook_capped)"

section "The nudge debounce breaks the exit-2 feedback loop"
# THE BUG: every exit 2 rewakes the agent, which produces a turn, whose end fires Stop again.
# Nudging on every firing therefore loops by construction — observed at ~5s intervals, each
# injecting ~1.7KB of instructions. MAX_REWAKES had been capping that loop by accident; when
# it was removed as a *stall* measure, the rate limit went with it.
reset
sentinel work-active-10 "{\"issue\":10,\"stage\":\"exec\",\"branch\":\"f/10\",\"owner\":\"o\",\"repo\":\"r\",\"session\":\"$MINE\"}"
assert_eq "first firing nudges" "2" "$(run_hook_payload '{"hook_event_name":"Stop"}')"
assert_eq "second firing seconds later is silent" "0" "$(run_hook_payload '{"hook_event_name":"Stop"}')"
assert_eq "and so is the third" "0" "$(run_hook_payload '{"hook_event_name":"Stop"}')"

# Age the counter past the interval — its mtime IS the last-nudge timestamp, which is why
# no fourth side file was needed.
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '-2 hours' +%Y%m%d%H%M)" \
  "$REPO/.claude/work-active-10.rewakes"
assert_eq "nudges again once the interval has passed" "2" "$(run_hook_payload '{"hook_event_name":"Stop"}')"

section "A watched stage is silent; an unwatched one is not"
# Stop carries background_tasks: "Lets hooks distinguish 'session is done' from 'session is
# paused waiting for background work to wake it'." A live Monitor for the issue means paused,
# which is the healthy case the heartbeat was firing on.
reset
sentinel work-active-11 "{\"issue\":11,\"stage\":\"exec\",\"branch\":\"f/11\",\"owner\":\"o\",\"repo\":\"r\",\"session\":\"$MINE\"}"
WATCHED='{"hook_event_name":"Stop","background_tasks":[{"id":"1","type":"monitor","status":"running","description":"issue #11 exec: progress + stalls"}],"session_crons":[]}'
assert_eq "a Monitor naming this issue → silent" "0" "$(run_hook_payload "$WATCHED")"
assert_eq "still silent on repeat" "0" "$(run_hook_payload "$WATCHED")"

reset
sentinel work-active-11 "{\"issue\":11,\"stage\":\"exec\",\"branch\":\"f/11\",\"owner\":\"o\",\"repo\":\"r\",\"session\":\"$MINE\"}"
EMPTY='{"hook_event_name":"Stop","background_tasks":[],"session_crons":[]}'
assert_eq "nothing in flight → the genuine stall, nudge" "2" "$(run_hook_payload "$EMPTY")"

# Per-issue, not global: one issue's monitor must not silence another's stage.
reset
sentinel work-active-11 "{\"issue\":11,\"stage\":\"exec\",\"branch\":\"f/11\",\"owner\":\"o\",\"repo\":\"r\",\"session\":\"$MINE\"}"
OTHER='{"hook_event_name":"Stop","background_tasks":[{"id":"1","type":"monitor","status":"running","description":"issue #7 exec: progress + stalls"}],"session_crons":[]}'
assert_eq "another issue's monitor does NOT silence this stage" "2" "$(run_hook_payload "$OTHER")"

# A scheduled wakeup is also "paused, not stalled" — and it is session-wide.
reset
sentinel work-active-11 "{\"issue\":11,\"stage\":\"exec\",\"branch\":\"f/11\",\"owner\":\"o\",\"repo\":\"r\",\"session\":\"$MINE\"}"
CRON='{"hook_event_name":"Stop","background_tasks":[],"session_crons":[{"id":"c1","schedule":"*/5 * * * *","recurring":true,"prompt":"x"}]}'
assert_eq "a pending session cron → silent" "0" "$(run_hook_payload "$CRON")"

section "An ABSENT background_tasks field is UNKNOWN, never 'nothing in flight'"
# THE BLIND-MONITOR RULE, applied to the new gate. background_tasks is .optional() and is only
# populated when a tool-use context exists. If absent were read as empty, the hook would treat
# every payload that omits it as a confirmed stall and nudge a fully-watched stage forever.
reset
sentinel work-active-12 "{\"issue\":12,\"stage\":\"exec\",\"branch\":\"f/12\",\"owner\":\"o\",\"repo\":\"r\",\"session\":\"$MINE\"}"
assert_eq "absent field still nudges once (falls through to the debounce)" \
  "2" "$(run_hook_payload '{"hook_event_name":"Stop"}')"
assert_eq "but the debounce holds it — NOT a free-running heartbeat" \
  "0" "$(run_hook_payload '{"hook_event_name":"Stop"}')"
# And it must not be rendered to the model as an observed absence.
out=$( cd "$REPO" && CLAUDE_CODE_SESSION_ID="$MINE" REWAKE_NUDGE_INTERVAL=0 \
         bash "$HOOK" <<< '{"hook_event_name":"Stop"}' 2>&1 >/dev/null )
assert_contains "absent renders as UNREADABLE" "$out" "in-flight work UNREADABLE"
assert_not_contains "never as 'nothing in flight'" "$out" "nothing in flight"

section "Non-repo cwd is inert"
rc=$( cd "$WORK" && CLAUDE_CODE_SESSION_ID="$MINE" \
        bash "$HOOK" <<< '{}' >/dev/null 2>&1; echo $? )
assert_eq "exit 0 outside a git repo" "0" "$rc"

summary
