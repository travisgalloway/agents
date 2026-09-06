#!/usr/bin/env bash
# session-cleanup.sh (test) — pin the contract of hooks/session-cleanup.sh.
#
# THE BUG THIS EXISTS FOR: the orphan reap was originally placed AFTER
#   repo_root=$(git ... ) || exit 0
# Orphan reaping is repo-independent — these are machine-wide processes, not session state — so
# ending a session from a non-repo directory reaped nothing at all. The same early exit also
# broke /reap, which delegates to this script with a synthetic hook payload.
#
# The script is normally a SessionEnd hook reading its payload from stdin; every case here feeds
# it that payload directly, which is exactly how /reap invokes it.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

HOOK="$HOME/.claude/hooks/session-cleanup.sh"
[ -f "$HOOK" ] || { bad "not found: $HOOK"; summary; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sesscleanup.XXXXXX")
ROOT="$WORK/fakeproj"; mkdir -p "$ROOT/bin"
NONREPO="$WORK/plain"; mkdir -p "$NONREPO"

# Every fixture this run spawns is recorded in a FILE, never a shell variable. `spawn_orphan` is
# always called as `p=$(spawn_orphan ...)`, so anything it assigns to a variable lands in the
# command-substitution subshell and never reaches this trap. SPAWNED read empty at exit, the
# cleanup killed nothing, and a fixture the hook under test did not kill would leak silently. Today the hook kills all three, so nothing escapes, but the trap has never been able to catch one that did. The `$WORK/.pid` handoff below already crosses that boundary
# for the same reason.
SPAWNED_FILE="$WORK/spawned"
: > "$SPAWNED_FILE"

# Kill every process this run started. The recorded PIDs are a convenience; the AUTHORITY is the
# unique $WORK path, which every fixture carries in its argv. Sweeping by that path also catches a
# fixture nobody remembered to record, which retires the bug class rather than one instance of it.
# `pgrep` omits itself, and this shell is excluded explicitly.
kill_fixtures() {
  local p
  if [ -f "$SPAWNED_FILE" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # disown first: killing a still-tracked background job makes the shell print a
      # "Killed: 9" job-control line to stderr after the summary, which reads like a failure.
      disown "$p" 2>/dev/null || true
      kill -KILL "$p" 2>/dev/null
    done < "$SPAWNED_FILE"
  fi
  for p in $(pgrep -f "$WORK" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    kill -KILL "$p" 2>/dev/null
  done
}

# Survivors of this run, excluding this shell. 0 is the only acceptable answer.
surviving_fixtures() {
  pgrep -f "$WORK" 2>/dev/null | grep -v "^$$\$" | wc -l | tr -d ' '
}

cleanup() {
  kill_fixtures
  rm -rf "$WORK"
}
# INT and TERM as well as EXIT: an interrupted run must not leave fixtures behind either.
trap cleanup EXIT INT TERM

export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@example.com; git config --global user.name Test

REPO="$WORK/repo"; mkdir -p "$REPO/.claude"
git -C "$REPO" init -q; echo x > "$REPO/x"; git -C "$REPO" add -A; git -C "$REPO" commit -qm x

MINE=aaaaaaaa-1111-2222-3333-444444444444
THEIRS=bbbbbbbb-5555-6666-7777-888888888888

# Symlink to a real signed binary: a copied system binary is SIGKILLed for a broken code
# signature, and `tail -f` blocks forever with no child process. Same approach as
# tests/reap-orphans.sh; see its notes.
ln -sf /usr/bin/tail "$ROOT/bin/fake-server"

spawn_orphan() {
  ( "$ROOT/bin/fake-server" -f /dev/null >/dev/null 2>&1 & echo $! > "$WORK/.pid" )
  local p; p=$(cat "$WORK/.pid"); printf '%s\n' "$p" >> "$SPAWNED_FILE"; echo "$p"
}

# run <cwd> <session_id> — feed the synthetic SessionEnd payload, scoped to our fake root.
run() {
  printf '{"session_id":"%s","cwd":"%s"}' "$2" "$1" \
    | REAP_CONF=/dev/null REAP_ROOTS="$ROOT" REAP_PROTECT='__nothing__' REAP_MIN_AGE=0 \
      bash "$HOOK" 2>/dev/null
}

alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }

# ---------------------------------------------------------------------------------
section "Orphans are reaped from a NON-repo cwd (the ordering bug)"
p=$(spawn_orphan); sleep 1
out=$(run "$NONREPO" "$MINE")
sleep 1
assert_eq "orphan died even though cwd is not a git repo" "no" "$(alive "$p")"
assert_contains "and it said so" "$out" "orphans"

section "Orphans are reaped from a repo cwd too"
p=$(spawn_orphan); sleep 1
run "$REPO" "$MINE" >/dev/null
sleep 1
assert_eq "orphan died" "no" "$(alive "$p")"

section "Sentinel ownership is respected"
printf '{"issue":7,"stage":"exec","session":"%s"}' "$MINE"   > "$REPO/.claude/work-active-7"
printf '{"pr":58,"session":"%s"}' "$THEIRS"                  > "$REPO/.claude/automerge-active-58"
echo 3 > "$REPO/.claude/work-active-7.rewakes"
run "$REPO" "$MINE" >/dev/null
[ -f "$REPO/.claude/work-active-7" ] \
  && bad "own sentinel not removed" || ok "own sentinel removed"
[ -f "$REPO/.claude/work-active-7.rewakes" ] \
  && bad "own .rewakes counter not removed" || ok "own .rewakes counter removed"
[ -f "$REPO/.claude/automerge-active-58" ] \
  && ok "another session's sentinel survived" || bad "another session's sentinel was deleted"
rm -f "$REPO/.claude/automerge-active-58"

section "Untagged sentinel is left alone (predates session stamping)"
printf '{"issue":9,"stage":"plan"}' > "$REPO/.claude/work-active-9"
run "$REPO" "$MINE" >/dev/null
[ -f "$REPO/.claude/work-active-9" ] \
  && ok "untagged sentinel survived" || bad "untagged sentinel was deleted"
rm -f "$REPO/.claude/work-active-9"

section "Missing session_id is a no-op"
p=$(spawn_orphan); sleep 1
out=$(printf '{"cwd":"%s"}' "$REPO" | REAP_CONF=/dev/null REAP_ROOTS="$ROOT" REAP_MIN_AGE=0 \
      bash "$HOOK" 2>/dev/null; echo "rc=$?")
assert_contains "exits 0" "$out" "rc=0"
assert_eq "and touches nothing — orphan still alive" "yes" "$(alive "$p")"
kill -KILL "$p" 2>/dev/null

section "Dirty worktree is reported, never force-removed"
WT="$REPO/.claude-work/$MINE/issue-3"
git -C "$REPO" worktree add -q "$WT" -b wt-test 2>/dev/null
echo dirty > "$WT/uncommitted.txt"
out=$(run "$REPO" "$MINE")
[ -d "$WT" ] && ok "dirty worktree still on disk" || bad "dirty worktree was removed"
assert_contains "reported as left behind" "$out" "uncommitted changes"

section "Clean worktree IS released"
git -C "$REPO" -c core.hooksPath=/dev/null worktree add -q "$REPO/.claude-work/$MINE/issue-4" \
  -b wt-clean 2>/dev/null
out=$(run "$REPO" "$MINE")
[ -d "$REPO/.claude-work/$MINE/issue-4" ] \
  && bad "clean worktree not released" || ok "clean worktree released"

section "Outside a repo it says the sweep did NOT run — silence would read as clean"
# THE FAILURE THIS BLOCKS: a quiet exit 0 is indistinguishable from "there was nothing to sweep",
# and /reap renders that silence as a clean teardown. Blind must never look like healthy.
out=$(run "$NONREPO" "$MINE")
assert_contains "names the sweep it could not perform" "$out" "NOT PERFORMED"
assert_contains "and why" "$out" "not in a git repo"
out=$(run "$REPO" "$MINE")
assert_not_contains "quiet again once there IS a repo" "$out" "NOT PERFORMED"

section "This session's bg-snapshot is released"
# Session state, not repo state — so it must be swept from a non-repo cwd too, above the repo check.
mkdir -p "$HOME/.claude/run"
printf '{"seen":"none"}' > "$HOME/.claude/run/bg-tasks-$MINE.json"
printf '{"seen":"none"}' > "$HOME/.claude/run/bg-tasks-$THEIRS.json"
run "$NONREPO" "$MINE" >/dev/null
[ -f "$HOME/.claude/run/bg-tasks-$MINE.json" ] \
  && bad "own snapshot survived" || ok "own snapshot removed from a non-repo cwd"
[ -f "$HOME/.claude/run/bg-tasks-$THEIRS.json" ] \
  && ok "another session's snapshot survived" || bad "another session's snapshot was deleted"
rm -f "$HOME/.claude/run/bg-tasks-$THEIRS.json"

section "Silent when there is nothing to do"
rm -rf "$REPO/.claude-work"; git -C "$REPO" worktree prune 2>/dev/null
assert_eq "no output" "" "$(run "$REPO" "$MINE")"

section "This suite leaves nothing behind"
# The leak this section exists for was invisible for 39 days because nothing ever asked. Two
# fixtures survive the tests above by design (none today, since the hook under test kills all three), so cleanup is
# exercised here, inside the assertion count, rather than trusted to the EXIT trap.
kill_fixtures
sleep 1
assert_eq "no fixture process survives the suite" "0" "$(surviving_fixtures)"

summary
