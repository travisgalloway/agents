#!/usr/bin/env bash
# stage-processes.sh — cover lib/stage-processes.sh, the sweep that ends the OS processes a /work
# or /backlog stage orphaned.
#
# THE CASE THIS SUITE EXISTS FOR is the one that shipped on 2026-09-04: a stage backgrounded twenty
# subshells under a non-interactive `zsh -c`, cleaned up with `kill $(jobs -p)`, and printed
# success while ending nothing. The shells reparented to PID 1 and ran for 3h26m at 601.8% CPU.
# The first test below reproduces that exact idiom rather than describing it, so a future change to
# the attribution logic fails here.
#
# Orphans are made with `sleep`, never a busy loop. A suite that pegs a core to test a CPU leak is
# its own bug, and the sweep does not read CPU.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

SCRIPT="../lib/stage-processes.sh"
[ -x "$SCRIPT" ] || { printf 'lib/stage-processes.sh missing or not executable\n'; exit 1; }

TMP=$(mktemp -d) || exit 1
HOME_DIR="$TMP/home"; TREE="$TMP/tree"; OUTSIDE="$TMP/outside"
mkdir -p "$HOME_DIR" "$TREE" "$OUTSIDE"

# Every orphan this suite creates, so the trap cannot miss one even if an assertion aborts early.
#
# A FILE, NOT A VARIABLE. `orphan_in` runs inside $( ), so anything it assigns to a shell variable
# lands in a subshell and never reaches this trap — the list would read empty at exit and the
# cleanup would silently do nothing. That is the same shape as the `jobs -p` bug this suite covers,
# and the first draft of this file had it.
SPAWNED_FILE="$TMP/spawned"
: > "$SPAWNED_FILE"
cleanup() {
  while IFS= read -r p; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done < "$SPAWNED_FILE"
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

run() { CLAUDE_HOME="$HOME_DIR" bash "$SCRIPT" "$@" 2>&1; }
run_rc() { CLAUDE_HOME="$HOME_DIR" bash "$SCRIPT" "$@" >/dev/null 2>&1; }

# Orphan one `sleep` with its cwd in $1. Returns after the parent has exited, so the child is
# already reparented to PID 1 by the time the caller looks.
orphan_in() {
  local dir="$1" before after pid
  before=$(pgrep -f 'sleep 3117' 2>/dev/null | tr '\n' ' ')
  # stdio goes to /dev/null deliberately. This function runs inside $( ), and a background
  # child holding the substitution's stdout pipe open makes the caller block until the sleep
  # exits — which is 3117 seconds, and reads as a hung suite.
  zsh -c "cd '$dir'; (exec sleep 3117 >/dev/null 2>&1 </dev/null) &" >/dev/null 2>&1
  # The PID is not knowable from here (the parent is gone), so diff the sets.
  after=$(pgrep -f 'sleep 3117' 2>/dev/null | tr '\n' ' ')
  for pid in $after; do
    case " $before " in *" $pid "*) ;; *) printf '%s\n' "$pid" >> "$SPAWNED_FILE"; printf '%s' "$pid"; return ;; esac
  done
}

# ---------------------------------------------------------------- blind paths

section 'BLIND is not clean'

out=$(run sweep 900 --tree "$TREE")
assert_contains 'sweep without a snapshot says BLIND' "$out" 'BLIND'
assert_rc 'sweep without a snapshot exits 5' 5 env CLAUDE_HOME="$HOME_DIR" bash "$SCRIPT" sweep 900 --tree "$TREE"

run_rc snapshot 901
: > "$HOME_DIR/run/stage-pids-901.txt"
out=$(run sweep 901 --tree "$TREE")
assert_contains 'an empty snapshot says BLIND' "$out" 'BLIND'
assert_rc 'an empty snapshot exits 5' 5 env CLAUDE_HOME="$HOME_DIR" bash "$SCRIPT" sweep 901 --tree "$TREE"

run_rc snapshot 902
assert_rc 'an unresolvable --tree exits 5' 5 \
  env CLAUDE_HOME="$HOME_DIR" bash "$SCRIPT" sweep 902 --tree "$TMP/no-such-dir"
out=$(run sweep 902 --tree "$TMP/no-such-dir")
assert_contains 'an unresolvable --tree says BLIND' "$out" 'BLIND'

# ---------------------------------------------------------------- snapshot

section 'snapshot'

out=$(run snapshot 903)
assert_contains 'snapshot reports a pid count' "$out" 'pids recorded'
[ -s "$HOME_DIR/run/stage-pids-903.txt" ] \
  && ok 'snapshot file is non-empty' || bad 'snapshot file is non-empty'
n=$(grep -cE '^[0-9]+$' "$HOME_DIR/run/stage-pids-903.txt" 2>/dev/null || echo 0)
[ "$n" -gt 1 ] && ok 'snapshot holds more than one pid' || bad 'snapshot holds more than one pid' "got $n"

assert_rc 'a label with a slash is refused' 64 env CLAUDE_HOME="$HOME_DIR" bash "$SCRIPT" snapshot ../escape
assert_rc 'an unknown subcommand is refused' 64 env CLAUDE_HOME="$HOME_DIR" bash "$SCRIPT" frobnicate 1
assert_rc '-h exits 0 without a label' 0 env CLAUDE_HOME="$HOME_DIR" bash "$SCRIPT" -h

# ---------------------------------------------------------------- the real case

section 'the 2026-09-04 leak, reproduced'

# The idiom itself, asserted rather than assumed: if `jobs -p` ever starts working under a
# non-interactive zsh -c, the rule in both skill prompts needs revisiting and this fails first.
jp=$(zsh -c 'for i in 1 2; do (exec sleep 3118 >/dev/null 2>&1 </dev/null) & done; printf "[%s]" "$(jobs -p)"' 2>/dev/null)
assert_eq 'jobs -p returns nothing under a non-interactive zsh -c' '[]' "$jp"
pkill -f 'sleep 3118' 2>/dev/null || true

run_rc snapshot 904
in_a=$(orphan_in "$TREE")
in_b=$(orphan_in "$TREE")
out_a=$(orphan_in "$OUTSIDE")

[ -n "$in_a" ] && [ -n "$in_b" ] && [ -n "$out_a" ] \
  && ok 'three orphans spawned' || bad 'three orphans spawned' "[$in_a][$in_b][$out_a]"

ppid=$(ps -o ppid= -p "$in_a" 2>/dev/null | tr -d ' ')
assert_eq 'an orphan is reparented to PID 1' '1' "$ppid"

# --dry-run first: the sweep must be able to report without acting.
out=$(run sweep 904 --tree "$TREE" --dry-run --keep)
assert_contains 'dry run names the in-tree orphan' "$out" "would end: pid $in_a"
assert_not_contains 'dry run does not claim to have ended anything' "$out" 'ended orphan'
kill -0 "$in_a" 2>/dev/null && ok 'dry run leaves the process running' || bad 'dry run leaves the process running'

out=$(run sweep 904 --tree "$TREE" --keep)
assert_contains 'sweep ends the first in-tree orphan' "$out" "ended orphan: pid $in_a"
assert_contains 'sweep ends the second in-tree orphan' "$out" "ended orphan: pid $in_b"
assert_contains 'sweep reports the out-of-tree orphan' "$out" "NOT THIS STAGE, left alone: pid $out_a"
assert_contains 'sweep prints a tally' "$out" 'ended 2, left alone 1'

kill -0 "$in_a" 2>/dev/null && bad 'in-tree orphan is gone' || ok 'in-tree orphan is gone'
kill -0 "$in_b" 2>/dev/null && bad 'second in-tree orphan is gone' || ok 'second in-tree orphan is gone'
kill -0 "$out_a" 2>/dev/null && ok 'out-of-tree orphan is untouched' || bad 'out-of-tree orphan is untouched'

# rc 3 is the "something was left for you" signal the teardown scripts branch on.
CLAUDE_HOME="$HOME_DIR" bash "$SCRIPT" sweep 904 --tree "$TREE" --keep >/dev/null 2>&1
assert_eq 'an out-of-tree orphan makes the sweep exit 3' '3' "$?"

kill -9 "$out_a" 2>/dev/null || true

section 'attribution requires a tree'

run_rc snapshot 905
lone=$(orphan_in "$TREE")
out=$(run sweep 905 --keep)
assert_contains 'without --tree nothing is ended' "$out" 'NOT THIS STAGE, left alone'
assert_not_contains 'without --tree nothing is claimed ended' "$out" 'ended orphan'
kill -0 "$lone" 2>/dev/null && ok 'without --tree the process survives' || bad 'without --tree the process survives'
kill -9 "$lone" 2>/dev/null || true

section 'the snapshot bounds what counts as new'

# A process that predates the snapshot is not this stage's, however it is parented.
pre=$(orphan_in "$TREE")
run_rc snapshot 906
out=$(run sweep 906 --tree "$TREE" --keep)
assert_not_contains 'a pre-existing orphan is not swept' "$out" "pid $pre"
kill -0 "$pre" 2>/dev/null && ok 'the pre-existing orphan survives' || bad 'the pre-existing orphan survives'
kill -9 "$pre" 2>/dev/null || true

section 'snapshot lifecycle'

run_rc snapshot 907
run_rc sweep 907 --tree "$TREE"
[ -f "$HOME_DIR/run/stage-pids-907.txt" ] \
  && bad 'a clean sweep consumes its snapshot' || ok 'a clean sweep consumes its snapshot'

run_rc snapshot 908
run_rc sweep 908 --tree "$TREE" --keep
[ -f "$HOME_DIR/run/stage-pids-908.txt" ] \
  && ok '--keep retains the snapshot' || bad '--keep retains the snapshot'

section 'the callers wire it up'

td="../lib/backlog-teardown.sh"
assert_contains 'backlog-teardown calls the sweep' "$(cat "$td")" 'stage-processes.sh" sweep'
assert_contains 'backlog-teardown treats rc 5 as blind' "$(cat "$td")" 'PROCESS SWEEP BLIND'
# Order matters: a process holding a cwd in the worktree makes `git worktree remove` fail.
sweep_line=$(grep -n 'stage-processes.sh" sweep' "$td" | head -1 | cut -d: -f1)
# Match the command, not the prose: the comment above the sweep block mentions
# `git worktree remove` too, and a looser pattern finds that first and inverts the comparison.
wt_line=$(grep -n 'git -C "\$root" worktree remove' "$td" | head -1 | cut -d: -f1)
[ -n "$sweep_line" ] && [ -n "$wt_line" ] && [ "$sweep_line" -lt "$wt_line" ] \
  && ok 'the sweep runs before the worktree release' \
  || bad 'the sweep runs before the worktree release' "sweep@$sweep_line worktree@$wt_line"

for s in work backlog; do
  f="../skills/$s/SKILL.md"
  body=$(cat "$f")
  assert_contains "$s grants stage-processes.sh in allowed-tools" "$body" 'lib/stage-processes.sh:*)'
  assert_contains "$s takes a snapshot before dispatch" "$body" 'stage-processes.sh snapshot {n}'
  assert_contains "$s forbids jobs -p as cleanup" "$body" 'jobs -p'
  assert_contains "$s requires processes to end before returning" "$body" 'must end before you return'
  assert_contains "$s asks the stage to report procs=N" "$body" 'procs=N'
done

assert_contains 'work teardown runs the sweep' "$(cat ../skills/work/SKILL.md)" 'stage-processes.sh sweep {n} --tree "{tree}"'
assert_contains 'CLAUDE.md scopes the detach rule out of stages' "$(cat ../CLAUDE.md)" 'is off inside a `/work` or `/backlog` stage'
assert_contains 'CLAUDE.md names the jobs -p trap' "$(cat ../CLAUDE.md)" '`jobs -p` is not a cleanup mechanism'

summary
