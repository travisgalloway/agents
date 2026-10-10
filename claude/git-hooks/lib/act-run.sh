# shellcheck shell=bash
# act-run.sh: child-process and act-container cleanup shared by pre-commit and pre-push.
# Sourced, never run. The caller defines say(), sets TMP and HOOK_NAME, then calls hook_traps.
#
# Every long child runs in the background, in its own process group, under a watchdog. A signal
# reaches the hook's trap, and the trap stops the child's whole group, so a grandchild forked a
# moment before the stop is reached too. act runs with --rm, and a sweep afterwards removes what
# act left. The sweep finds containers two ways, because act drops --container-options for a job
# that sets `container:`: by this run's label, and by an act- container that mounts this
# repository's path and did not exist before the run. The second key skips a container that a
# concurrent run in the same checkout already owned.
#
# Knob: HOOK_STOP_GRACE (seconds between TERM and KILL, default 20; act removes its containers
# in that window).

STOP_GRACE=${HOOK_STOP_GRACE:-20}
# One label per hook run, so the sweep never touches a concurrent act run from another repo.
ACT_RUN_LABEL="claude.githook.run=${HOOK_NAME}-$$-$(date +%s)"
ACT_PENDING=0
CUR_PID=""
CUR_WD=""

# group_alive <pgid>: a member of the group is running. A child not yet reaped reads as a zombie.
group_alive() {
  ps -A -o pgid=,stat= 2>/dev/null | awk -v g="$1" '$1 == g && $2 !~ /^Z/ { f = 1 } END { exit !f }'
}

# stop_group <pgid>: TERM the group, then KILL it if anything outlives STOP_GRACE.
stop_group() {
  local g=$1 i
  group_alive "$g" || return 0
  kill -TERM -- "-$g" 2>/dev/null || true
  for ((i = 0; i < STOP_GRACE * 5; i++)); do
    group_alive "$g" || return 0
    sleep 0.2
  done
  kill -KILL -- "-$g" 2>/dev/null || true
}

# spawn <out> <err> <cmd...>: start cmd in its own process group; the group id is $! (SPAWNED).
spawn() {
  local out=$1 err=$2
  shift 2
  set -m
  if [ "$out" = "$err" ]; then
    "$@" </dev/null >"$out" 2>&1 &
  else
    "$@" </dev/null >"$out" 2>>"$err" &
  fi
  SPAWNED=$!
  set +m
}

# run_limited <seconds> <out> <err> <cmd...>: cmd under a watchdog; macOS ships no `timeout`.
# On expiry the watchdog writes $TMP/timedout and stops the whole tree; the call returns 124.
run_limited() {
  local limit=$1 out=$2 err=$3 rc=0
  shift 3
  rm -f "$TMP/timedout"
  spawn "$out" "$err" "$@"
  CUR_PID=$SPAWNED
  # The watchdog escalates by itself: the hook is blocked in `wait` until the child dies, so a
  # child that ignores TERM would never reach the KILL in stop_group below.
  # shellcheck disable=SC2016
  spawn /dev/null /dev/null bash -c 'sleep "$1" && : >"$2" && kill -TERM -- "-$3" && sleep "$4"
    kill -KILL -- "-$3" 2>/dev/null' _ "$limit" "$TMP/timedout" "$CUR_PID" "$STOP_GRACE"
  CUR_WD=$SPAWNED
  # wait's stderr carries job control's "Terminated" notice, which is noise here.
  wait "$CUR_PID" 2>/dev/null || rc=$?
  # Normally a no-op: the child has exited, by itself or by the watchdog's TERM and KILL.
  stop_group "$CUR_PID"
  stop_group "$CUR_WD"
  wait "$CUR_WD" 2>/dev/null || true
  CUR_PID=""
  CUR_WD=""
  [ -e "$TMP/timedout" ] && return 124
  return "$rc"
}

# act_run <log> <seconds> <act args...>: act with --rm and this run's label, then the sweep.
act_run() {
  local log=$1 limit=$2 rc=0
  shift 2
  ACT_PENDING=1
  act_snapshot
  run_limited "$limit" "$log" "$log" act --rm --container-options "--label $ACT_RUN_LABEL" "$@" || rc=$?
  act_sweep
  ACT_PENDING=0
  return "$rc"
}

# act_by_path: act containers that mount the current directory, which the hooks set to the top level.
act_by_path() { docker ps -aq --filter 'name=^act-' --filter "volume=$PWD" 2>/dev/null; }

# act_snapshot: the path-matched containers present before the run, which the sweep leaves alone.
act_snapshot() {
  if act_by_path >"$TMP/act.before"; then
    sort -u -o "$TMP/act.before" "$TMP/act.before"
  else
    rm -f "$TMP/act.before"
  fi
}

# act_sweep: remove the containers this run left, and their named act volumes. A docker that
# cannot be read is reported, never taken as clean.
act_sweep() {
  local ids vols by_label by_path
  if ! by_label=$(docker ps -aq --filter "label=$ACT_RUN_LABEL" 2>/dev/null) ||
    [ ! -e "$TMP/act.before" ] || ! by_path=$(act_by_path); then
    say "WARNING could not list act containers; check: docker ps -a --filter name=^act- --filter volume=$PWD"
    return 0
  fi
  ids=$({
    printf '%s\n' "$by_label"
    printf '%s\n' "$by_path" | sort -u | comm -23 - "$TMP/act.before"
  } | grep -v '^$' | sort -u || true)
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2086
  vols=$(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' $ids 2>/dev/null |
    tr ' ' '\n' | grep -E '^act-' | grep -vx 'act-toolcache' || true)
  say "removing $(printf '%s\n' "$ids" | wc -l | tr -d ' ') leftover act container(s)"
  # shellcheck disable=SC2086
  docker rm -f $ids >/dev/null 2>&1 || say "WARNING docker rm failed for: $(printf '%s ' $ids)"
  # shellcheck disable=SC2086
  [ -z "$vols" ] || docker volume rm $vols >/dev/null 2>&1 || say "WARNING docker volume rm failed for: $(printf '%s ' $vols)"
}

hook_cleanup() {
  if [ -n "$CUR_PID" ]; then stop_group "$CUR_PID"; fi
  if [ -n "$CUR_WD" ]; then stop_group "$CUR_WD"; fi
  if [ "$ACT_PENDING" = 1 ]; then act_sweep; fi
  rm -rf "$TMP"
}

# Every exit path, a signal included, goes through hook_cleanup once.
hook_traps() {
  trap hook_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}
