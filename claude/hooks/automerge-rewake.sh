#!/usr/bin/env bash
# automerge-rewake.sh — asyncRewake guard for the bounded waits in /automerge and /work.
#
# Registered on Stop and TeammateIdle in ~/.claude/settings.json (asyncRewake: true).
# Runs in the background after the agent stops; if it exits 2, the harness rewakes
# the agent with this script's stderr as the message.
#
# Also registered on SubagentStop — but WITHOUT asyncRewake, and scoped by a matcher.
#
# The earlier rationale for skipping that event ("it fires when a subagent *finishes*, so it
# can never fire for one that stalled") is false for an LLM subagent: one that ends its turn
# a step short of its goal DOES finish, and returns its text to the parent. That is exactly
# how a subagent-hosted /automerge stalls with the PR green, CLEAN, and unmerged.
#
# Verified against the CLI bundle's Zod schemas and hook registry (2.1.221):
#   - SubagentStop's payload is Stop's plus agent_id / agent_transcript_path / agent_type.
#   - Its `matcher` is matched against agent_type — hence "work-exec|work-exec-opus" in
#     settings.json, keeping this off every unrelated Explore/Plan/general-purpose subagent.
#   - Exit 2 there means "show stderr to subagent and continue having it run" (Stop's
#     counterpart reads "…to model and continue conversation"). Synchronous and documented,
#     so this registration needs no asyncRewake — which in any case only backgrounds in an
#     interactive or streaming session, and so would buy nothing here.
#
# On SubagentStop this script evaluates ONLY the automerge sentinels; see the guard above the
# /work section for why reaching /work would loop a stage that had legitimately finished.
#
# Purpose: /automerge waits on CI + the Claude code review, and /work's orchestrator waits
# on plan/exec teammates. If the agent ends its turn mid-wait, nothing would
# otherwise resume it — this hook is the harness-enforced backstop that nudges it
# to keep polling instead of stalling for hours.
#
# It is a backstop, NOT the mechanism. Every wait it guards is independently
# capped (see automerge.md §2.3/§2.4 and work.md's heartbeat table); this hook only
# ensures a capped wait is not silently *abandoned*. It must never be the reason a
# wait is left uncapped.
#
# Scoping: inert everywhere except an active run owned by THIS session. It keys off
# sentinel files the commands write/delete themselves:
#   {repo_root}/.claude/automerge-active-{PR} — {"pr": N, "owner": "...", "repo": "...",
#                                                "session": "..."}
#   {repo_root}/.claude/work-active-{N}       — {"issue": N, "stage": "plan|exec",
#                                                "branch": "...", "owner": "...",
#                                                "repo": "...", "session": "..."}
# Both kinds are per-item (per-PR / per-issue) so `parallel>1` runs can't clobber
# each other's state; the legacy single-file `automerge-active` name is still
# honored for runs started by an older command version. Automerge sentinels are
# checked first (an inner /automerge wait during /work auto is the more specific
# signal), but a *silent* automerge pass FALLS THROUGH to the /work checks — an
# automerge sentinel with nothing to say must not starve a stalled /work stage.
#
# Exit 0  => silent, no rewake (no owned sentinel, terminal state, stale, or cap reached).
# Exit 2  => rewake; stderr becomes the message shown to the agent.

set -u

# No-progress caps. THIS is the stall measurement — how long the wait has gone without an
# OBSERVED change, in wall-clock seconds, not how many times this hook happened to fire.
#
# It used to be a firing counter (MAX_REWAKES=20), and that was never a stall measurement:
# this hook fires once per Stop/TeammateIdle, i.e. once per orchestrator turn-end, so a
# chatty session burned the entire budget in ~4 minutes. Observed 2026-08-05 — four healthy
# /work stages, at 12%/2%/17%/2% of their budgets with files actively landing, were all told
# to tear down. All four went on to merge. A counter of firings measures how talkative the
# session is; it cannot tell that apart from a stage that is doing nothing.
#
# These sit just ABOVE work.md's own escalation (10m no-progress → re-poke, 2 fruitless
# re-pokes ≈30m → teardown) so this hook stays the backstop rather than racing the mechanism.
# Overridable like reap-orphans.conf's settings, which is how tests/ drives them.
: "${REWAKE_STALL_CAP_PLAN:=$((30 * 60))}"
: "${REWAKE_STALL_CAP_EXEC:=$((45 * 60))}"
: "${REWAKE_STALL_CAP_AUTOMERGE:=$((45 * 60))}"

# Minimum gap between nudges for the SAME wait.
#
# Every exit 2 rewakes the agent, which produces a turn, whose end fires Stop again — so
# nudging on every firing is an infinite loop by construction. The only thing that ever broke
# it was MAX_REWAKES, which capped it at 20 firings by accident rather than by design; removing
# that cap (correctly, it measured the wrong thing) removed the rate limiter with it, and the
# loop ran at ~5s intervals injecting ~1.7KB of instructions each time.
#
# 10 minutes matches work.md's own escalation ladder, where 10 minutes of no progress is when a
# teammate re-poke first becomes warranted — so the nudge can no longer demand a re-poke more
# often than the skill sanctions one. This is the backstop's cadence; the Monitor (60s) and the
# teammate-completion notification remain the mechanism.
: "${REWAKE_NUDGE_INTERVAL:=$((10 * 60))}"

# Stage wall-clock caps, mirroring work.md's heartbeat table (plan 30m / exec 90m,
# extended to 2h once /automerge is in flight), plus grace. Past its cap a sentinel
# describes work nobody is doing: self-heal instead of rewaking — the orchestrator's
# own cap should have raised a blocker. Independent of the no-progress caps above, and
# deliberately so: this one bounds a wait that stays observable and keeps inching forever.
PLAN_CAP=$((45 * 60))
EXEC_CAP=$((2 * 60 * 60))
AUTOMERGE_CAP=$((2 * 60 * 60))

# Read the hook payload; the harness's writer blocks if nobody consumes it. Parsed after the
# jq check below, into $event.
#
# We deliberately do NOT honor `stop_hook_active`. It is true on every stop that
# followed a hook-initiated continuation, so acting on it caps this hook at ONE
# rewake per chain — which defeats its whole purpose. Every wait it guards spans
# several turns by design (/automerge's review wait is ~2 chunks of 9 minutes;
# /work stages run far longer), so the second stop is exactly the one that needs
# the nudge. (It also used to make the whole .rewakes counter dead code — it could
# never reach 2. Back when that counter WAS the cap, honoring stop_hook_active
# therefore hid the miscount described above rather than fixing it.)
#
# Nothing can run away as a result — the loop is bounded three independent ways:
#   - the no-progress caps, via progress_gate()
#   - the wall-clock caps, via expired()
#   - terminal-state self-heal (PR MERGED/CLOSED, plan file newer than sentinel)
# The harness's documented 8-block cap applies to hooks that block *synchronously*;
# asyncRewake is async and its contract is undocumented, so the bounds above are
# what we rely on. (Pinned by tests/rewake-observability.sh.)
INPUT=$(cat 2>/dev/null || true)

# Resolve repo root from cwd; if this isn't a git repo, there's nothing to guard.
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Tooling missing = fail safe (don't rewake on our own bug).
command -v gh >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Which event fired. Empty for a payload we can't parse, which just means the SubagentStop
# guard below stays off — the Stop/TeammateIdle behavior is unchanged.
event=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null)

# ---------------------------------------------------------------- is anything watching?
#
# THE QUESTION THIS HOOK ACTUALLY ASKS. A sentinel on disk means "a stage exists" — it is armed
# before dispatch and removed at stage end, so it is present for the whole stage (up to 2h),
# including every ordinary exchange with the user. It is NOT evidence that the session idled.
# Reading it as such is what turned this guard into a heartbeat: it fired after every reply,
# and since each exit 2 rewakes the agent — producing a turn, whose end fires Stop again —
# the loop feeds itself. Observed at roughly one firing every 5 seconds.
#
# `Stop` answers the real question directly. Verified in CLI 2.1.222, .describe() text:
#   background_tasks — "In-flight background work (running/pending + backgrounded) registered
#     in this session. Lets hooks distinguish 'session is done' from 'session is paused
#     waiting for background work to wake it'. Empty array when nothing is in flight."
#   session_crons    — scheduled tasks that will wake this session later.
# A /work stage's Monitor and teammate ARE that in-flight work, so this reads as "watched"
# for exactly the healthy case the heartbeat was firing on.
#
# THREE-VALUED, for the same reason pr_seen is. Both fields are `.optional()` and are only
# populated when a tool-use context exists, so ABSENT is UNKNOWN — never "nothing is in
# flight". Collapsing those is the blind-monitor bug: unobservable rendered as a clean
# negative, which here would nudge a fully-watched stage forever.
#   absent  → we cannot tell; fall through to the nudge debounce
#   none    → observed empty: nothing will wake this session — the genuine stall
#   <json>  → the task list, matched per-issue below
bg_seen="absent"; bg_tasks=""
if printf '%s' "$INPUT" | jq -e 'has("background_tasks")' >/dev/null 2>&1; then
  if bg_tasks=$(printf '%s' "$INPUT" | jq -r '[(.background_tasks // [])[]
        | [(.description // ""), (.name // ""), (.command // ""), (.agent_type // "")]
        | join(" ")] | join("\n")' 2>/dev/null); then
    [ -n "$bg_tasks" ] && bg_seen="listed" || bg_seen="none"
  else
    bg_seen="absent"   # jq aborted on a shape we did not expect — unknown, not empty
  fi
fi

# A scheduled wakeup means the session is paused, not stalled — same conclusion as a live
# background task, and it applies session-wide rather than per-issue, so it silences every
# sentinel including the automerge ones. Unlike the per-issue match this is unambiguous: a
# cron IS a guaranteed future turn, so the "nothing will ever run again" failure this hook
# exists to catch cannot be happening.
#
# Known consequence: a RECURRING cron — an active /loop, say — keeps this guard quiet for as
# long as it runs. That is the correct reading (the session is demonstrably still being
# driven), but it does mean the no-progress cap notice waits for the loop to end.
crons_pending=""
printf '%s' "$INPUT" | jq -e '(.session_crons // []) | length > 0' >/dev/null 2>&1 \
  && crons_pending=1

# watching <issue> — true when something in flight names THIS issue.
#
# Per-issue on purpose. A global "background_tasks is non-empty" test would let one issue's
# Monitor silence every other stage under parallel>1 — the same shape as the single shared
# sentinel that had parallel runs clobbering each other. The skill stamps both an issue-scoped
# description ("issue #{n} {stage}: progress + stalls") and the argv marker
# claude-work-monitor:{session}:#{n}, so match on "#{n}" at a word boundary.
watching() {   # watching <issue>
  [ "$bg_seen" = "listed" ] || return 1
  printf '%s' "$bg_tasks" | grep -qE "(^|[^0-9])#$1([^0-9]|$)"
}

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
now=$(date +%s)

# fmt_dur <seconds> — "41m" / "1h12m", for quoting a stall duration in the cap notice.
# An unknown duration renders as "an unknown time", never as "0m": the notice asks for a
# teardown, so it must not state a precise-looking figure it does not actually have.
fmt_dur() {
  local s="${1:-}" h m
  case "$s" in ''|*[!0-9]*) echo "an unknown time"; return ;; esac
  h=$((s / 3600)); m=$(((s % 3600) / 60))
  if [ "$h" -gt 0 ]; then echo "${h}h${m}m"; else echo "${m}m"; fi
}

# Age past a cap means the run died without cleaning up. Self-heal rather than
# rewaking a session for work nobody is doing.
expired() {   # expired <sentinel> <cap>
  local m; m=$(mtime "$1")
  [ -n "$m" ] && [ $((now - m)) -gt "$2" ]
}

# Every sentinel owns THREE side files. Removing it without them leaves state that a
# later run silently inherits, so there is exactly one place that knows the whole set —
# five self-heal paths used to open-code `rm -f "$sentinel" "$counter"` and every one of
# them left .capped behind. Mirrored by session-cleanup.sh and by work.md's teardown step 3.
drop_sentinel() {   # drop_sentinel <sentinel>
  rm -f "$1" "$1.rewakes" "$1.capped" "$1.progress"
}

# Nudge counter, stored beside its sentinel. A counter older than the sentinel belongs to a
# previous run — reset it rather than carrying the count forward.
#
# This is now purely INFORMATIONAL: it reports how many times the wait has been nudged, for
# the cap notice to quote. It is no longer a cap — see the header on REWAKE_STALL_CAP_* for
# why counting firings could never measure a stall.
rewake_count() {   # rewake_count <sentinel>
  local counter="$1.rewakes" count=0 cm sm
  [ -f "$counter" ] || { echo 0; return; }
  cm=$(mtime "$counter"); sm=$(mtime "$1")
  if [ -n "$sm" ] && [ -n "$cm" ] && [ "$cm" -lt "$sm" ]; then echo 0; return; fi
  count=$(cat "$counter" 2>/dev/null)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  echo "$count"
}

# progress_gate <sentinel> <fingerprint> <stall_cap> — has this wait stopped moving?
#
# The fingerprint is a compact rendering of everything the hook can observe about the wait
# (see the call sites). Stored beside the sentinel as `<observed_at_epoch> <fingerprint>`,
# one line, read without forking jq — which is why a fingerprint must contain NO SPACES.
#
# Exit 0 — unchanged for at least <stall_cap>: this is a stall, cap it.
# Exit 1 — changed, or first sample, or unchanged but still under the cap: keep going.
# Exit 2 — fingerprint is empty, meaning we could not observe the wait at all.
#
# Exit 2 is the important one. A failed lookup is UNKNOWN, never "nothing happened": capping
# on it would tear down a live stage because GitHub was unreachable for a minute — the
# blind-monitor failure, where unobservable reads as a clean negative. So an unobservable
# round leaves .progress untouched and can never contribute to a cap. The wall-clock caps
# still bound a wait that stays unobservable forever.
#
# On a change it also clears .capped, so a stage that starts moving again gets its guard back
# instead of staying permanently silenced by one bad stretch.
#
# Staleness follows rewake_count()'s rule: a .progress older than its sentinel describes a
# previous run, so it is treated as absent rather than as a very old stalled sample.
progress_gate() {   # progress_gate <sentinel> <fingerprint> <stall_cap>
  local sentinel="$1" fp="$2" cap="$3" file="$1.progress" fm sm observed_at="" fp_old=""

  [ -n "$fp" ] || return 2

  if [ -f "$file" ]; then
    fm=$(mtime "$file"); sm=$(mtime "$sentinel")
    if [ -n "$sm" ] && [ -n "$fm" ] && [ "$fm" -lt "$sm" ]; then
      observed_at=""; fp_old=""
    else
      read -r observed_at fp_old < "$file" 2>/dev/null || { observed_at=""; fp_old=""; }
      case "$observed_at" in ''|*[!0-9]*) observed_at=""; fp_old="" ;; esac
    fi
  fi

  if [ -z "$observed_at" ] || [ "$fp" != "$fp_old" ]; then
    printf '%s %s\n' "$now" "$fp" > "$file"
    rm -f "$sentinel.capped"
    return 1
  fi

  [ $((now - observed_at)) -ge "$cap" ] && return 0
  return 1
}

# nudged_recently <sentinel> — true when this wait was nudged less than REWAKE_NUDGE_INTERVAL
# ago, so nudging again would just feed the exit-2 → turn → Stop → exit-2 loop.
#
# No new side file: .rewakes is rewritten on every nudge, so its mtime IS the last-nudge
# timestamp. Reusing it keeps drop_sentinel() and the six teardown sites unchanged — a fourth
# side file would be a fourth thing for each of them to forget.
#
# A counter older than its sentinel belongs to a previous run (rewake_count()'s rule), so it
# proves nothing about this one: treat that as "not nudged recently" and let the nudge through.
nudged_recently() {   # nudged_recently <sentinel>
  local counter="$1.rewakes" cm sm
  [ -f "$counter" ] || return 1
  cm=$(mtime "$counter"); sm=$(mtime "$1")
  [ -n "$cm" ] || return 1
  [ -n "$sm" ] && [ "$cm" -lt "$sm" ] && return 1
  [ $((now - cm)) -lt "$REWAKE_NUDGE_INTERVAL" ]
}

# stalled_for <sentinel> — seconds since this wait was last observed to change, or "" if
# it has no usable .progress. Quoted in the cap notice so the claim carries its evidence.
stalled_for() {
  local observed_at="" fp_old=""
  [ -f "$1.progress" ] || return 0
  read -r observed_at fp_old < "$1.progress" 2>/dev/null || return 0
  case "$observed_at" in ''|*[!0-9]*) return 0 ;; esac
  echo $((now - observed_at))
}

# mine <sentinel> — true when this session owns the sentinel. A sentinel owned by a
# different session is not ours to act on OR delete: its own session's hooks are
# responsible for it, and rewaking this agent would nudge it about work it never
# dispatched. An unstamped sentinel (predates session stamping) is treated as ours
# so older runs keep their guard.
mine() {
  local s; s=$(jq -r '.session // empty' "$1" 2>/dev/null)
  [ -z "$s" ] || [ -z "${CLAUDE_CODE_SESSION_ID:-}" ] || [ "$s" = "$CLAUDE_CODE_SESSION_ID" ]
}

# cap_notice_due <sentinel> — true the FIRST time a stage trips its no-progress cap, false
# after. progress_gate() deletes this marker whenever the fingerprint moves, so a stage that
# resumes and stalls a second time is entitled to a second notice.
#
# The cap notice is delivered with exit 2, because that is the only code that surfaces on
# all three registrations: Stop and TeammateIdle carry asyncRewake, and the harness's async
# handler branches solely on code 2, so a non-zero/non-2 exit would be invisible on exactly
# the registrations that matter most. ("Other exit codes - show stderr to user only" is real,
# but only reachable on the synchronous SubagentStop entry.)
#
# Firing ONCE is what keeps that from contradicting "stop nudging": the stage gets one final
# message telling it to tear down and record a blocker, then this hook is silent about it
# forever. The marker uses rewake_count()'s staleness rule — one older than its sentinel
# belongs to a previous run, so a re-armed stage gets its notice again.
cap_notice_due() {   # cap_notice_due <sentinel>
  local marker="$1.capped" mm sm
  if [ -f "$marker" ]; then
    mm=$(mtime "$marker"); sm=$(mtime "$1")
    if [ -n "$sm" ] && [ -n "$mm" ] && [ "$mm" -ge "$sm" ]; then return 1; fi
  fi
  : > "$marker"
  return 0
}

capped=""

# ---------------------------------------------------------------- automerge waits
am_msgs=""
for sentinel in "$repo_root"/.claude/automerge-active "$repo_root"/.claude/automerge-active-*; do
  [ -f "$sentinel" ] || continue
  # Skip our own side files — both globs would otherwise match them as sentinels.
  case "$sentinel" in *.rewakes|*.capped|*.progress) continue ;; esac
  counter="$sentinel.rewakes"

  # Ownership FIRST. A foreign session's sentinel is not ours to act on or delete — not even
  # an expired one. Its own session's hooks self-heal it; deleting it here would disarm that
  # session's stall guard. (Ordering pinned by tests/hook-sentinels.sh.)
  mine "$sentinel" || continue

  if expired "$sentinel" "$AUTOMERGE_CAP"; then
    drop_sentinel "$sentinel"; continue
  fi

  # Same debounce as the /work loop, and before the lookups for the same reason. A pending
  # cron applies here too — it is a guaranteed future turn. What this branch does NOT take is
  # the per-issue background_tasks match: a listed task matching "#41" could be issue 41
  # rather than PR 41, and silencing a merge wait on an ambiguous match is the expensive
  # direction to be wrong in — the pre-merge stall is the quietest one there is.
  if [ -n "$crons_pending" ] || nudged_recently "$sentinel"; then
    continue
  fi

  owner=$(jq -r '.owner // empty' "$sentinel" 2>/dev/null)
  repo=$(jq -r '.repo // empty' "$sentinel" 2>/dev/null)
  pr=$(jq -r '.pr // empty' "$sentinel" 2>/dev/null)
  { [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$pr" ]; } || continue   # malformed = fail safe

  pr_state=$(gh pr view "$pr" --repo "$owner/$repo" --json state -q .state 2>/dev/null)

  # Self-heal ONLY on an explicit terminal state. An empty result is a FAILED
  # lookup (network, auth, rate limit) — deleting on it would disarm the guard
  # for a live run. Unknown = keep the sentinel, stay silent this round.
  if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
    drop_sentinel "$sentinel"; continue
  fi
  [ "$pr_state" = "OPEN" ] || continue

  # OBSERVABILITY FIRST. A lookup that FAILED must never read as "nothing is pending" —
  # that is the blind-monitor bug: unobservable reported as clean, which here would tell
  # the agent to merge a PR whose CI we never actually managed to read.
  #
  # One call fetches every signal, so there is exactly one exit status to judge. `gh pr
  # checks` is unusable for this: it exits 8 for "pending" and 1 for "failing", so its rc
  # cannot distinguish a real API failure from an ordinary CI state.
  # network/auth/rate limit → stay silent this round and keep the sentinel.
  # headRefOid rides along for the progress fingerprint below — same call, still one rc.
  if ! pr_json=$(gh pr view "$pr" --repo "$owner/$repo" \
       --json statusCheckRollup,reviewRequests,headRefOid 2>/dev/null) || [ -z "$pr_json" ]; then
    continue
  fi

  # CheckRun rows carry .status (QUEUED/IN_PROGRESS/COMPLETED); StatusContext rows carry
  # .state (PENDING/SUCCESS/...). Read whichever is present.
  # total_ci rides along so the fingerprint moves when a check merely *finishes* — a run
  # going 5-pending → 4-pending is progress, and so is 5-of-5 → 5-of-6 after a re-push.
  ci_counts=$(printf '%s' "$pr_json" | jq -r '
    [ (.statusCheckRollup // [])[]
      | ((.status // .state // "") | ascii_upcase) ] as $s
    | "\($s | length):\($s | map(select(test("PENDING|QUEUED|IN_PROGRESS|WAITING|EXPECTED"))) | length)"
    ' 2>/dev/null)
  # jq aborted, or produced something that is not <total>:<pending> — unobservable, same
  # rule as a failed lookup. Never let an unreadable rollup render as "nothing is pending".
  case "$ci_counts" in
    *[0-9]:*[0-9]) pending_ci="${ci_counts#*:}" ;;
    *) continue ;;
  esac
  case "$pending_ci" in
    ''|*[!0-9]*) continue ;;
    0) pending_ci="" ;;        # observed, and genuinely nothing pending
  esac

  head_oid=$(printf '%s' "$pr_json" | jq -r '.headRefOid // empty' 2>/dev/null)

  # The Claude code review runs as a GitHub Actions workflow, so its own check rows are part
  # of the statusCheckRollup read above — but only once the run exists. GitHub delivers the
  # pull_request event asynchronously, so in the window between a push and the run appearing
  # the rollup reads "nothing pending" while a review is still inbound. That window is
  # exactly when this hook would say MERGE IT NOW, so ask about the run directly.
  #
  # Three-valued, same rule as every other lookup here: absent (no such workflow in the repo)
  # and completed are both "not pending"; anything else, INCLUDING a run that has not appeared
  # yet, is pending; and an unreadable answer concludes nothing and stays silent this round.
  # The 45-minute stall cap bounds the not-yet-appeared case, so a PR whose head predates the
  # workflow surfaces as a no-progress notice rather than as an instruction to merge.
  #
  # The `// []` guard must sit on the FIELD, not outside the array literal: `|` binds looser
  # than `//`, so `[...] // []` parses as `([...] // []) | sort_by(...)` and an array literal
  # is never null — the guard could never fire. Without it, a response missing .workflow_runs
  # aborts jq (rc=5) and the empty result reads as "no run for this commit" → the merge is
  # instructed while the review is inbound.
  # (Pinned by tests/jq-run-lookup.sh.)
  review_state="nohead"
  review_pending=""
  if [ -n "$head_oid" ]; then
    # The file at the head commit, not the workflows endpoint: GitHub keeps a deleted workflow
    # listed as active there, which would read a removed review as forever pending.
    wf_id=$(gh api "repos/$owner/$repo/contents/.github/workflows/claude-review.yml?ref=$head_oid" --jq '.sha' 2>&1)
    case "$wf_id" in
      *"Not Found"*) review_state="absent" ;;
      *)
        printf '%s' "$wf_id" | grep -Eq '^[0-9a-f]{40}$' || continue
        review_state=$(gh api "repos/$owner/$repo/actions/runs?head_sha=$head_oid&per_page=50" \
          --jq '[(.workflow_runs // [])[]
                 | select(.path == ".github/workflows/claude-review.yml")]
                | sort_by(.run_number) | last | .status // "none"' 2>/dev/null) || continue
        [ -n "$review_state" ] || continue ;;
    esac
    case "$review_state" in
      absent|completed) : ;;
      *) review_pending="1" ;;
    esac
  fi

  # Everything below this point was observed, so the wait is judgeable. The fingerprint is
  # every signal that moves while a merge is legitimately in flight: a new push (headRefOid),
  # a check starting or finishing (ci_counts), the review run appearing or completing
  # (review_state). No spaces in any component — progress_gate reads them back with `read`.
  progress_gate "$sentinel" "${head_oid:-nohead}|$ci_counts|${review_state:-none}" "$REWAKE_STALL_CAP_AUTOMERGE"
  case $? in
    0) cap_notice_due "$sentinel" \
         && capped="$capped PR #$pr (automerge, no change in $(fmt_dur "$(stalled_for "$sentinel")") over $(rewake_count "$sentinel") nudges);"
       continue ;;
  esac

  count=$(rewake_count "$sentinel")
  echo $((count + 1)) > "$counter"
  if [ -n "$pending_ci" ] || [ -n "$review_pending" ]; then
    am_msgs="$am_msgs
- PR #$pr ($owner/$repo): CI and/or the Claude code review still pending. Re-check status (gh pr view --json statusCheckRollup, and the claude-review workflow run for the head SHA) and continue the /automerge remediation loop, honoring its caps (CI 30m, review 15m)."
  else
    # The quietest stall of all: everything finished but the merge never ran. There may be
    # no "next poll" to defer to — this hook fires at turn-end, and the merge wait's own
    # polling loop is exactly what may have stopped. Lead with the merge as ONE imperative
    # step — an earlier version opened with
    # "resume at §2.5, re-check for new comments, and if clean proceed to the merge",
    # and a multi-step instruction is easy to stop halfway through a second time.
    am_msgs="$am_msgs
- PR #$pr ($owner/$repo): CI is done and the Claude code review has completed. MERGE IT NOW — run /automerge Step 3 for this PR (confirm mergeable, then gh pr merge --squash --delete-branch) in THIS turn, before reporting anything. Then confirm with gh pr view --json state that it reads MERGED, and only then delete its automerge-active sentinel. Stop instead ONLY if Step 3 hits a genuine Stop condition (conflict, BLOCKED, mergeability still UNKNOWN after 5 polls) — and name which one."
  fi
done

# cap_text — the once-only blocker notice for whatever is currently in $capped, or "".
# Appended to whichever message is emitted below rather than read in a single branch: it
# used to live only in the no-$live path, so a capped PR was dropped entirely whenever any
# /work stage happened to be in flight.
cap_text() {
  [ -n "$capped" ] || return 0
  printf '\n\nNo observable progress for:%s. This hook is now DONE with that wait — it will not raise it again, so there is no later reminder coming.\n\nWhat that measurement is: the last commit on the branch, the PR'"'"'s state, and the plan file'"'"'s mtime (for an automerge wait: the head SHA, the check-run counts, and the review run status) have not changed once in that whole span. Rounds where the hook could not read those signals at all are excluded — they never count toward a stall.\n\nWhat it CANNOT see: uncommitted edits. A stage writing files in a worktree without committing looks identical to a stage doing nothing. So CHECK before you act — `git -C <tree> status --porcelain` and the stage'"'"'s Monitor output. If files are moving, this notice is wrong: ignore it, let the stage run, and rely on the wall-clock caps (plan 30m, exec 90m, 2h with /automerge in flight) instead.\n\nOnly if it is genuinely stuck: run the stage teardown from work.md (TaskStop the monitor and the teammate, remove the sentinel and its side files, release the worktree), then record it as a blocker. A blocker recorded without teardown leaves exactly the things that were stuck still running.' \
    "${capped%;}"
}

if [ -n "$am_msgs" ]; then
  echo "An automerge wait is still active and your turn ended — this hook cannot tell whether you idled or simply finished a reply, so treat it as a prompt to check rather than a verdict:$am_msgs

It will not raise the same PR again for 10 minutes. Do not stop until each PR above is merged or a genuine Stop condition is hit.$(cap_text)" >&2
  exit 2
fi

# --------------------------------------------------------------- /work stages
# SubagentStop stops here, deliberately. On that event exit 2 means "show stderr to the
# subagent and continue having it run" — right for a subagent-hosted /automerge that stopped
# short of the merge (handled above), and badly wrong for /work: a work-exec subagent that
# finished legitimately would be handed "stages still in flight … Do not idle" and told to
# keep working, looping a stage that was correctly done. Its own sentinel is still on disk at
# that moment, because the ORCHESTRATOR tears it down after the subagent returns — so this
# branch would fire on every clean exec stage. /work stages are guarded by Stop and
# TeammateIdle on the orchestrator, where "keep going" is addressed to the right agent.
# A pending cap notice still goes out — it concerns an automerge PR, which is this
# subagent's own business, and it is delivered only once.
if [ "$event" = "SubagentStop" ]; then
  if [ -n "$capped" ]; then
    echo "Automerge wait abandoned:$(cap_text)" >&2
    exit 2
  fi
  exit 0
fi
# Collect every live per-issue sentinel. Each is independently checked for
# liveness; we rewake once, naming all of them, so parallel runs cost one message.
live=""
for sentinel in "$repo_root"/.claude/work-active-*; do
  [ -f "$sentinel" ] || continue
  # Skip our own side files — both globs would otherwise match them as sentinels.
  case "$sentinel" in *.rewakes|*.capped|*.progress) continue ;; esac
  counter="$sentinel.rewakes"

  issue=$(jq -r '.issue // empty' "$sentinel" 2>/dev/null)
  stage=$(jq -r '.stage // "exec"' "$sentinel" 2>/dev/null)
  branch=$(jq -r '.branch // empty' "$sentinel" 2>/dev/null)
  owner=$(jq -r '.owner // empty' "$sentinel" 2>/dev/null)
  repo=$(jq -r '.repo // empty' "$sentinel" 2>/dev/null)
  { [ -n "$issue" ] && [ -n "$owner" ] && [ -n "$repo" ]; } || continue   # malformed = skip

  # Ownership FIRST, for the same reason as the automerge loop above: a foreign session's
  # sentinel must survive even past its cap.
  mine "$sentinel" || continue

  # Past its stage cap — the stage is not coming back. Self-heal, stay silent.
  cap=$EXEC_CAP
  [ "$stage" = "plan" ] && cap=$PLAN_CAP
  if expired "$sentinel" "$cap"; then
    drop_sentinel "$sentinel"; continue
  fi

  # Liveness: a plan stage whose plan file this run produced has already finished —
  # the sentinel just outlived it. The file must be NEWER than the sentinel to prove
  # that: plan files are never deleted, so a stale one from an earlier aborted run
  # would otherwise read as "finished" and drop the sentinel of a plan stage that is
  # genuinely in flight — silently disarming the guard for that issue.
  # Read once: this mtime is both the plan-stage liveness signal and one third of the
  # progress fingerprint below. It is what makes a plan stage observable at all — a plan
  # stage produces no commits and no PR for its whole legitimate 30-minute life, so a
  # fingerprint of commits+PR alone would read every healthy one as stalled.
  plan_file="$repo_root/.claude/plans/issue-$issue.md"
  plan_mtime=$(mtime "$plan_file")
  if [ "$stage" = "plan" ] && [ -f "$plan_file" ]; then
    if [ -n "$plan_mtime" ] && [ -n "$(mtime "$sentinel")" ] \
       && [ "$plan_mtime" -gt "$(mtime "$sentinel")" ]; then
      drop_sentinel "$sentinel"; continue
    fi
  fi

  # Something in flight names this issue — a Monitor, a teammate, a backgrounded task. The
  # session is paused waiting to be woken, which is the healthy case, not the stall. Stay
  # silent. Placed BEFORE the gh lookup on purpose: this is the common case during a normal
  # stage, and paying a network round-trip per turn-end to say nothing is how a backstop
  # becomes a poller.
  if [ -n "$crons_pending" ] || watching "$issue"; then
    continue
  fi

  # Nudged for this stage within the last REWAKE_NUDGE_INTERVAL. Nudging again would only
  # feed the exit-2 → turn → Stop → exit-2 loop. Also before the gh lookup: at the observed
  # ~5s firing rate, checking here rather than after costs ~6 API calls an hour per stage
  # instead of ~720.
  #
  # The trade: a debounced round evaluates no cap either, so a due cap notice can be DEFERRED
  # by up to one nudge interval. It is never lost — cap_notice_due() is not consumed on a
  # round that never runs, so the notice arrives on the next eligible firing. Against a 30-45
  # minute stall threshold, up to 10 minutes of lag on the blocker is the right side of the
  # trade. (Pinned by tests/rewake-observability.sh, "DEFERS a due cap notice".)
  if nudged_recently "$sentinel"; then
    continue
  fi

  # Liveness: this issue's PR already reached a terminal state — the stage is done.
  # (Only explicit MERGED/CLOSED counts; an empty result is a failed lookup.)
  # Reset first: this variable is reused by the automerge loop above and by earlier
  # iterations, so a leaked value would describe the wrong PR.
  # Three distinct outcomes, kept distinct. Collapsing "the lookup failed" into "no PR
  # found" is the blind-monitor bug — the message below tells the model to trust this
  # reading, so it must never present an unreadable state as an observed negative.
  pr_state=""; pr_seen="not-queried"
  if [ -n "$branch" ]; then
    if pr_state=$(gh pr list --head "$branch" --repo "$owner/$repo" --state all \
         --json state -q '.[0].state' 2>/dev/null); then
      pr_seen="${pr_state:-none}"
    else
      pr_state=""; pr_seen="lookup-failed"
    fi
    if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
      drop_sentinel "$sentinel"; continue
    fi
  fi

  # The same three signals the stage's own Monitor watches (work.md's monitor block), so the
  # two agree about what "moving" means: last commit, PR state, plan-file mtime.
  #
  # The SHA comes from the MAIN repo's ref store, which every worktree shares — so this sees
  # commits made inside an issue's worktree without needing to know the worktree's path. A
  # branch that does not exist yet is the plan stage's expected starting state, not a failure.
  head_sha=$(git -C "$repo_root" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null)
  fingerprint="${head_sha:-nobranch}|${plan_mtime:-noplan}|$pr_seen"

  # Unobservable is UNKNOWN, not "nothing happened". 'lookup-failed' means gh could not be
  # reached, so this round is evidence of nothing and must not push the stage toward a
  # teardown it may not deserve. ('not-queried' — a sentinel with no branch — IS observed:
  # that is a plan stage, and its plan-file mtime still moves.)
  [ "$pr_seen" = "lookup-failed" ] && fingerprint=""

  stall_cap=$REWAKE_STALL_CAP_EXEC
  [ "$stage" = "plan" ] && stall_cap=$REWAKE_STALL_CAP_PLAN

  # This stage has gone <stall_cap> without a single observable change. Stop nudging it, but
  # remember it so the last word is a blocker rather than silence.
  progress_gate "$sentinel" "$fingerprint" "$stall_cap"
  case $? in
    0) cap_notice_due "$sentinel" \
         && capped="$capped #$issue ($stage, no change in $(fmt_dur "$(stalled_for "$sentinel")") over $(rewake_count "$sentinel") nudges);"
       continue ;;
  esac

  count=$(rewake_count "$sentinel")
  echo $((count + 1)) > "$counter"

  # Carry what the hook itself OBSERVED into the message. The model has no equivalent view
  # of its own — TaskList is the TaskCreate to-do board and tracks none of this — so this
  # is the reading, not a second opinion. (hooks/bg-snapshot.sh persists the same field for
  # /reap; here we already hold it.)
  # ...including WHY this stage looked unwatched, which is the reading that decided to nudge
  # at all. Kept distinct the same way pr_seen is: "unreadable" must never render as "none".
  case "$bg_seen" in
    none)   watched_seen="nothing in flight" ;;
    listed) watched_seen="in-flight work listed, none of it naming this issue" ;;
    *)      watched_seen="in-flight work UNREADABLE" ;;
  esac
  live="$live #$issue ($stage, ${branch:-no branch}, PR $pr_seen, $watched_seen);"
done

if [ -z "$live" ]; then
  # The notice is delivered with exit 2 on purpose. It used to be written to stderr and
  # then exit 0 — which the harness documents as "stdout/stderr not shown", so the intent
  # that "the last word is a blocker rather than silence" silently never worked.
  if [ -n "$capped" ]; then
    echo "A guarded wait has been abandoned:$(cap_text)" >&2
    exit 2
  fi
  exit 0
fi

echo "A /work stage looks UNWATCHED:${live%;}.

What this hook observed, and nothing more: a sentinel for that stage is on disk, your turn ended, and the harness listed no in-flight background work naming that issue. It does NOT know whether you idled or simply finished a reply — a sentinel is armed before dispatch and removed at stage end, so it is present for the whole stage. Treat this as one reading to check, not as a verdict.

That reading is why this fires at all now: while a Monitor or teammate for the issue IS listed as in flight, this hook stays silent, because the session is paused waiting to be woken rather than stalled. It will not nudge the same stage again for 10 minutes.

Read each field for what it is. 'lookup-failed' means gh could not be reached and the PR's state is UNKNOWN; 'not-queried' means the sentinel carries no branch; 'in-flight work UNREADABLE' means the payload did not carry that list. None of those is evidence of an absence — go and look before concluding anything from them.

What to do, in proportion to what is actually missing:
- Monitor: the hook already read the in-flight list — use it. Do NOT check TaskList: it is the TaskCreate to-do board and does not track monitors, teammates or background shells, so it answers "nothing" whatever is running. If the list says nothing is watching this issue, arm one — and TaskStop any duplicate that later surfaces. If it says UNREADABLE, resolve toward the cheaper failure and arm one anyway: a second 60s poller beats a blind stage.
- Teammate: re-poke the EXISTING one via SendMessage only once the stage has gone 10 minutes with no progress — that is work.md's threshold, and a re-poke costs the teammate context too. Never spawn a second: a duplicate teammate makes conflicting commits, which is not recoverable the way a duplicate poller is.
- Then re-check progress from ground truth (git log -1 on its branch, gh pr list --head <branch>) and apply the stage caps (plan 30m, exec 90m / 2h once /automerge is in flight). After 2 fruitless re-pokes, run the full stage teardown from work.md — TaskStop the monitor AND the teammate, remove the sentinel, release the worktree — then record the issue as blocked. Recording a blocker without teardown leaves exactly the things that were stuck still running.

If you re-arm the watcher and the stage is genuinely moving, say so briefly and stop — a short answer is the correct one here. What is not correct is answering with a token check that cannot distinguish a live stage from a dead one.$(cap_text)" >&2
exit 2
