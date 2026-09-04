#!/usr/bin/env bash
# session-cleanup.sh — SessionEnd teardown for /work and /automerge leftovers.
#
# Registered on SessionEnd (matcher: clear|logout|prompt_input_exit) in
# ~/.claude/settings.json. Fires when a session is discarded or quit, and sweeps the
# OS-level and on-disk residue its own /work or /automerge run left behind.
#
# SCOPE — read this before extending it. Teammates and Monitors are IN-PROCESS
# threads (settings.json: "teammateMode": "in-process"), not OS processes. A shell
# hook cannot kill them; only TaskStop can, and the model is gone by the time this
# runs. So this script is a BACKSTOP for what a shell can actually reach — state
# files, worktrees, genuinely backgrounded shells. The real mechanism is the stage
# teardown in work.md, which runs on every exit path *during* the run.
#
# SESSION SCOPING — several claude sessions run concurrently, often on the same repo.
# This script must only ever touch artifacts stamped with ITS OWN session id, or it
# would delete a live session's sentinels out from under it. Sentinels carry a
# "session" field; monitors carry the id in an argv marker.
#
# WHAT IT CANNOT SEE, it says so about. Outside a git repo the sentinel and worktree sweep
# cannot run at all; that prints an explicit NOT PERFORMED line rather than exiting quietly,
# because /reap reports this script's silence as "nothing to release".
#
# NEVER TOUCHES .claude/plans/*.md — those are work product, and the plan-file
# handoff between the plan and exec stages depends on them surviving.
#
# Exit code is ignored by the harness for SessionEnd; stdout/stderr go to the user.

set -u

INPUT=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

session=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$session" ] || exit 0

cleaned=""

# --- 0. Orphaned dev-server processes ----------------------------------------------
# MUST run before the repo check below. Orphan reaping is repo-independent: these are
# machine-wide processes, not session state, so exiting early on "not a git repo" would
# skip them entirely — which is exactly what happened when this block sat further down.
#
# Grandchildren of a killed background task (workerd under wrangler under turbo, and
# friends) survive the kill, reparent to init, and hold their ports forever. They carry
# no session stamp, so ownership cannot be checked the way it is for sentinels below —
# the reaper instead only touches processes whose parent is ALREADY DEAD, which is what
# makes it safe to run while other sessions are live. See hooks/reap-orphans.sh.
#
# Most of this session's own orphans are younger than the reaper's age floor right now
# and will be swept by the next session's SessionStart instead. That is deliberate: an
# age floor low enough to catch them here would also race legitimate restarts.
if [ -x "$HOME/.claude/hooks/reap-orphans.sh" ]; then
  reaped=$(bash "$HOME/.claude/hooks/reap-orphans.sh" --kill 2>/dev/null)
  [ -n "$reaped" ] && cleaned="$cleaned orphans"
fi

# --- 0b. This session's background-work snapshot -----------------------------------
# Written by hooks/bg-snapshot.sh at every turn end and read by /reap. Session state, not
# repo state, so it is released ABOVE the repo check for the same reason the orphan reap is.
rm -f "$HOME/.claude/run/bg-tasks-$session.json" 2>/dev/null

# Everything below is session-scoped state that lives inside a repo. Without one there
# is nothing further to sweep — but SAY that, rather than exiting quietly. A silent exit
# is indistinguishable from "there was nothing to sweep", and /reap renders that silence as
# a clean teardown: the blind-monitor failure, one process removed.
repo_root=$(git -C "${cwd:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || {
  [ -n "$cleaned" ] && echo "session-cleanup: released$cleaned"
  echo "session-cleanup: not in a git repo — sentinel/worktree sweep NOT PERFORMED"
  exit 0
}

# --- 1. Sentinels owned by this session ------------------------------------------
# An untagged sentinel predates session stamping: leave it. The rewake hook's
# staleness caps will retire it, and guessing wrong here means deleting live state.
for sentinel in "$repo_root"/.claude/work-active-* "$repo_root"/.claude/automerge-active "$repo_root"/.claude/automerge-active-*; do
  [ -f "$sentinel" ] || continue
  case "$sentinel" in *.rewakes|*.capped|*.progress) continue ;; esac
  owner=$(jq -r '.session // empty' "$sentinel" 2>/dev/null)
  [ "$owner" = "$session" ] || continue
  # All three side files, same set as the rewake hook's drop_sentinel().
  rm -f "$sentinel" "$sentinel.rewakes" "$sentinel.capped" "$sentinel.progress"
  cleaned="$cleaned $(basename "$sentinel")"
done

# --- 2. Background shells tagged with this session --------------------------------
# A no-op while monitors are in-process; correct the moment any of them is a real
# process. pkill excludes itself, and the marker is specific enough not to collide.
if command -v pkill >/dev/null 2>&1; then
  pkill -f "claude-work-monitor:$session" 2>/dev/null && cleaned="$cleaned monitors"
fi

# --- 3. Worktrees created by this session, ONLY if clean ---------------------------
# Never --force: an abandoned worktree is recoverable, destroyed work is not. A dirty
# worktree is reported and left for the user to decide about.
dirty=""
while IFS= read -r wt; do
  [ -n "$wt" ] || continue
  [ "$wt" = "$repo_root" ] && continue
  case "$wt" in *"/.claude-work/$session/"*) ;; *) continue ;; esac
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    dirty="$dirty$wt"$'\n'
    continue
  fi
  git -C "$repo_root" worktree remove "$wt" 2>/dev/null && cleaned="$cleaned $(basename "$wt")"
done <<EOF
$(git -C "$repo_root" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
EOF

git -C "$repo_root" worktree prune 2>/dev/null || true

[ -n "$cleaned" ] && echo "session-cleanup: released$cleaned"
if [ -n "$dirty" ]; then
  echo "session-cleanup: left worktrees with uncommitted changes (remove by hand if you don't want them):"
  printf '%s' "$dirty" | sed 's/^/  /'
fi

exit 0
