#!/usr/bin/env bash
# bg-snapshot.sh — persist the Stop payload's `background_tasks` so /reap can read it.
#
# Registered on Stop in ~/.claude/settings.json, listed BEFORE automerge-rewake.sh so the
# snapshot is written even on the turns where that hook exits 2.
#
# WHY THIS EXISTS. /reap used TaskList to enumerate live work. TaskList is the TaskCreate
# to-do board (subject/status/owner/blockedBy) — it has never listed running agents,
# monitors or background shells. On 2026-08-18 it returned "No tasks found" while 52
# background agents were live, and /reap reported a clean teardown. ListAgents covers the
# subagents from the model side; Monitors and backgrounded shells have no model-side
# enumerator at all. The harness DOES hand that list to hooks:
#   background_tasks — "In-flight background work (running/pending + backgrounded)
#     registered in this session. Lets hooks distinguish 'session is done' from 'session
#     is paused waiting for background work to wake it'. Empty array when nothing is in
#     flight."  (CLI 2.1.222 .describe(); same field automerge-rewake.sh reads.)
# Nothing persisted it, so a skill could not use it. This does, and nothing else.
#
# THREE-VALUED, for the same reason automerge-rewake.sh's bg_seen is: the field is
# `.optional()` and only populated when a tool-use context exists, so ABSENT is UNKNOWN,
# never "nothing is in flight". Collapsing those is the blind-monitor bug — /reap would
# print a clean summary off a payload it never received.
#   absent  → could not tell; /reap must report BLIND
#   none    → observed empty
#   listed  → the task list
#
# STALENESS is bounded and fails cheap. The snapshot is from the END of the previous turn,
# and /reap's own turn spawns nothing, so it can only OVER-report — a TaskStop against an
# already-finished id, which is harmless. It cannot under-report something still running.
#
# MUST STAY INERT. A Stop hook that writes stderr and exits 2 rewakes the agent; that is
# how the rewake loop feeds itself. This one never writes to stdout or stderr and always
# exits 0. If it cannot do its job it leaves no file, which /reap reads as BLIND.

set -u

INPUT=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

session=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$session" ] || exit 0

dir="$HOME/.claude/run"
mkdir -p "$dir" 2>/dev/null || exit 0
out="$dir/bg-tasks-$session.json"

# Once per session (the turn where the snapshot first appears), retire other sessions'
# leftovers. Kept off the steady-state path: a find per turn end buys nothing.
[ -e "$out" ] || find "$dir" -name 'bg-tasks-*.json' -mtime +7 -delete 2>/dev/null

now=$(date +%s)

if printf '%s' "$INPUT" | jq -e 'has("background_tasks")' >/dev/null 2>&1; then
  # One jq pass. A shape we did not expect aborts it — that is UNKNOWN, not empty.
  if snapshot=$(printf '%s' "$INPUT" | jq -c --argjson at "$now" '
        [ (.background_tasks // [])[]
          | { id:          ((.id // .task_id // .taskId // "") | tostring),
              name:        ((.name // "")        | tostring),
              description: ((.description // "") | tostring),
              agent_type:  ((.agent_type // .agentType // "") | tostring),
              type:        ((.type // "")        | tostring),
              status:      ((.status // .state // "") | tostring),
              command:     ((.command // "")     | tostring),
              keys:        (if type == "object" then keys else [] end) } ]
        | { seen: (if length == 0 then "none" else "listed" end), at: $at, tasks: . }
      ' 2>/dev/null); then
    :
  else
    snapshot=$(printf '{"seen":"absent","at":%s,"tasks":[]}' "$now")
  fi
else
  snapshot=$(printf '{"seen":"absent","at":%s,"tasks":[]}' "$now")
fi

# Written whole: /reap reads this file, and a half-written one would parse as truncated
# rather than as unknown.
tmp="$out.$$"
printf '%s\n' "$snapshot" > "$tmp" 2>/dev/null && mv -f "$tmp" "$out" 2>/dev/null
rm -f "$tmp" 2>/dev/null

exit 0
