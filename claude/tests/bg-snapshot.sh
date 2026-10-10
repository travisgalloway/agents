#!/usr/bin/env bash
# bg-snapshot.sh (test) — pin the contract of hooks/bg-snapshot.sh.
#
# THE BUG THIS EXISTS FOR: /reap enumerated live work with TaskList — the TaskCreate to-do board,
# which has never listed running agents, monitors or background shells. On 2026-08-18 it returned
# "No tasks found" while 52 background agents were live and /reap reported a clean teardown. This
# hook persists the one list that does answer the question (the Stop payload's `background_tasks`)
# so /reap can read it.
#
# Two properties carry the whole design:
#   1. THREE-VALUED. `absent` (field missing / unparseable) must never render as `none` (observed
#      empty). Collapsing them is the blind-monitor failure: /reap would print a clean summary off
#      a payload it never received.
#   2. INERT. A Stop hook that writes stderr and exits 2 REWAKES the agent. Every path here must be
#      silent and exit 0, or this snapshot becomes a rewake loop.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

HOOK="$HOME/.claude/hooks/bg-snapshot.sh"
[ -f "$HOOK" ] || { bad "not found: $HOOK"; summary; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bgsnap.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
RUN="$WORK/.claude/run"

# HOME is redirected so the suite never writes into the real ~/.claude/run.
run() { printf '%s' "$1" | HOME="$WORK" bash "$HOOK"; }
snap() { cat "$RUN/bg-tasks-$1.json" 2>/dev/null; }
field() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# ---------------------------------------------------------------------------------
section "listed — the payload's tasks are captured"
run '{"session_id":"s1","background_tasks":[{"id":"t1","name":"work-exec","description":"issue #7 exec"},{"id":"t2","description":"issue #7 monitor"}]}'
s=$(snap s1)
assert_eq "seen=listed" "listed" "$(field "$s" .seen)"
assert_eq "both tasks kept" "2" "$(field "$s" '.tasks|length')"
assert_eq "id preserved (TaskStop needs it)" "t1" "$(field "$s" '.tasks[0].id')"
assert_eq "description preserved (per-issue matching needs it)" "issue #7 monitor" \
  "$(field "$s" '.tasks[1].description')"
assert_contains "stamped with a read time" "$(field "$s" '.at|tostring')" ""
[ -n "$(field "$s" .at)" ] && ok "at is populated" || bad "at is empty — staleness unmeasurable"

section "type and status are kept, so /reap sees what the hook saw"
# Kept as reported. A returned teammate still reads "running" until TaskStop, so neither field
# is a liveness signal on its own; automerge-rewake.sh counts only Monitor entries.
run '{"session_id":"s-ts","background_tasks":[{"id":"t1","type":"teammate","status":"running","description":"#3 plan"}]}'
assert_eq "type kept" "teammate" "$(field "$(snap s-ts)" '.tasks[0].type')"
assert_eq "status kept" "running" "$(field "$(snap s-ts)" '.tasks[0].status')"
assert_eq "raw keys kept" "description,id,status,type" "$(field "$(snap s-ts)" '.tasks[0].keys | join(",")')"

section "none — observed empty, which is a real answer"
run '{"session_id":"s2","background_tasks":[]}'
assert_eq "seen=none" "none" "$(field "$(snap s2)" .seen)"

section "absent — the field was not in the payload (UNKNOWN, not empty)"
run '{"session_id":"s3"}'
assert_eq "seen=absent" "absent" "$(field "$(snap s3)" .seen)"

section "absent — a shape jq cannot walk is UNKNOWN too, never none"
# THE FAILURE THIS BLOCKS: reading a malformed payload as "nothing in flight" is what lets
# /reap claim a clean teardown while agents run. Same reasoning as bg_seen in automerge-rewake.sh.
run '{"session_id":"s4","background_tasks":"not-an-array"}'
assert_eq "seen=absent, not none" "absent" "$(field "$(snap s4)" .seen)"
run '{"session_id":"s5","background_tasks":{"id":"t9"}}'
assert_eq "an object is not a list either" "absent" "$(field "$(snap s5)" .seen)"

section "Inert on every path — a Stop hook that speaks up rewakes the agent"
out=$(printf '%s' '{"session_id":"s6","background_tasks":[]}' | HOME="$WORK" bash "$HOOK" 2>&1; echo "rc=$?")
assert_eq "silent, exit 0 (listed/none path)" "rc=0" "$out"
out=$(printf '%s' 'not json at all' | HOME="$WORK" bash "$HOOK" 2>&1; echo "rc=$?")
assert_eq "silent, exit 0 (garbage stdin)" "rc=0" "$out"
out=$(printf '%s' '' | HOME="$WORK" bash "$HOOK" 2>&1; echo "rc=$?")
assert_eq "silent, exit 0 (empty stdin)" "rc=0" "$out"
# A PATH with the basics but no jq — and /bin/bash by absolute path, since PATH no longer finds it.
mkdir -p "$WORK/nojq"; ln -sf /bin/cat "$WORK/nojq/cat"
out=$(printf '%s' '{"session_id":"s7"}' | HOME="$WORK" PATH="$WORK/nojq" /bin/bash "$HOOK" 2>&1; echo "rc=$?")
assert_eq "silent, exit 0 with no jq on PATH" "rc=0" "$out"
[ -f "$RUN/bg-tasks-s7.json" ] && bad "wrote a file without jq" || ok "no jq → no file (reads as BLIND)"

section "No session_id is a no-op"
out=$(printf '%s' '{"cwd":"/tmp","background_tasks":[{"id":"t1"}]}' | HOME="$WORK" bash "$HOOK" 2>&1; echo "rc=$?")
assert_eq "exits 0 silently" "rc=0" "$out"
n=$(find "$RUN" -name 'bg-tasks-*.json' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "wrote nothing unscoped" "7" "$n"   # s1-s6 and s-ts only

section "Session-scoped — one session never clobbers another"
run '{"session_id":"s1","background_tasks":[]}'
assert_eq "s1 updated in place" "none" "$(field "$(snap s1)" .seen)"
assert_eq "s2 untouched" "none" "$(field "$(snap s2)" .seen)"

section "Written whole — no temp files left for /reap to trip over"
n=$(find "$RUN" -name 'bg-tasks-*.json.*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no leftover temp files" "0" "$n"

section "Prunes only OTHER sessions' stale files, and only on first write"
touch -t 200001010000 "$RUN/bg-tasks-ancient.json"
printf '{"seen":"none"}' > "$RUN/bg-tasks-recent.json"
run '{"session_id":"s8","background_tasks":[]}'
[ -f "$RUN/bg-tasks-ancient.json" ] && bad "8-day-old snapshot survived" || ok "stale snapshot retired"
[ -f "$RUN/bg-tasks-recent.json" ] && ok "recent snapshot left alone" || bad "recent snapshot deleted"
touch -t 200001010000 "$RUN/bg-tasks-ancient2.json"
run '{"session_id":"s8","background_tasks":[]}'
[ -f "$RUN/bg-tasks-ancient2.json" ] \
  && ok "no find on the steady-state path (own snapshot already exists)" \
  || bad "prunes on every turn end — a find per turn buys nothing"

summary
