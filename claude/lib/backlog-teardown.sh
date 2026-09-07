#!/usr/bin/env bash
# backlog-teardown.sh — release the on-disk state one /backlog stage leaves behind.
#
# RUNS ON EVERY EXIT FROM A STAGE. Success, blocker, cap breach, error, abandonment — there is no
# path that skips it. Recording a blocker is not a substitute for teardown; it is the opposite. A
# blocked issue's sentinel is precisely the one still on disk, and every idle turn for the rest of
# the session pays a rewake nudge for work that is no longer running.
#
# WHAT THIS SCRIPT DOES NOT DO: TaskStop the Monitor and the teammate. Those are harness tools,
# not shell commands, so they stay in the skill body — and they must be stopped by the task IDs
# recorded in the ledger, never from memory, because after a compaction the memory is gone and a
# persistent:true Monitor polls `git log` + `gh pr list` every 60s until the session ends.
# A teammate that has already RETURNED still needs TaskStop: the harness keeps a finished
# subagent registered (ListAgents shows it `completed`) until it is stopped, so the clean-return
# path is not exempt. Skipping it there left 41 agents behind on a 20-issue /backlog run.
#
# CONTRACT: act on the exit code.
#   0   teardown complete (nothing left to remove is also success)
#   3   something was left behind that needs a person: a branch that could not be deleted, a
#       worktree holding uncommitted work, an orphaned process outside the tree, or a process
#       sweep that could not observe. Never "mostly fine".
#   64  usage error
#
# Output is one line per action taken, for the ledger and the transcript.

set -u

# Shared branch grammar — only ever a FALLBACK here; see the deletion block below.
_lib_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || _lib_dir=""
if [ -n "$_lib_dir" ] && [ -r "$_lib_dir/branch-name.sh" ]; then
  . "$_lib_dir/branch-name.sh" 2>/dev/null || true
fi

usage() {
  cat <<'EOF'
usage: backlog-teardown.sh <issue-number> [options]

  --pr N              also clear /automerge's automerge-active-N sentinel and its side files
  --merged            the merge was VERIFIED against gh (state reads MERGED). Only then is the
                      local feature branch deleted.
  --integration NAME  base branch to return to before deleting (default: resolved)
  --root PATH         repo root holding .claude/ (default: the main checkout for this tree)
  --worktree PATH     release this per-issue worktree (parallel>1). Never uses --force.
  --branch NAME       the EXACT branch to delete. Strongly preferred: /backlog already owns
                      this string. Without it, a grammar scan guesses, and this deletes.
EOF
}

[ $# -ge 1 ] || { usage >&2; exit 64; }
issue="$1"; shift
case "$issue" in ''|*[!0-9]*) printf 'usage: first argument must be an issue number\n'; usage >&2; exit 64 ;; esac

pr=""; merged=0; integration=""; root=""; worktree=""; branch=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)          pr="${2:-}"; shift 2 ;;
    --merged)      merged=1; shift ;;
    --integration) integration="${2:-}"; shift 2 ;;
    --root)        root="${2:-}"; shift 2 ;;
    --worktree)    worktree="${2:-}"; shift 2 ;;
    --branch)      branch="${2:-}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1"; usage >&2; exit 64 ;;
  esac
done

say() { printf '%s\n' "$1"; }
rc=0

# --- locate the main checkout ------------------------------------------------------
if [ -z "$root" ]; then
  git_common=$(git rev-parse --git-common-dir 2>/dev/null || true)
  case "$git_common" in
    /*) ;;
    "") git_common="$(pwd)/.git" ;;
    *)  git_common="$(pwd)/$git_common" ;;
  esac
  root=$(cd "$git_common/.." 2>/dev/null && pwd || true)
  [ -n "$root" ] || { printf 'not inside a git repository and no --root given\n'; exit 64; }
fi

# --- 1. the issue sentinel and ALL THREE side files --------------------------------
# All four, every time. `.progress` carries the last observed progress fingerprint, and one left
# behind is inherited by the next run on this issue as though it were a fresh sample — so a stage
# that has genuinely just started reads as one that has already stalled.
s="$root/.claude/work-active-$issue"
if [ -f "$s" ] || [ -f "$s.rewakes" ] || [ -f "$s.capped" ] || [ -f "$s.progress" ]; then
  rm -f "$s" "$s.rewakes" "$s.capped" "$s.progress"
  say "removed work-active-$issue (+ .rewakes/.capped/.progress)"
fi

# --- 2. the merge stage's automerge sentinel ---------------------------------------
# /automerge deliberately keeps this alive until the merge is CONFIRMED, which is what lets a
# stalled merge be rewaken. The cost is that a merge stage which stops without merging leaves one
# behind, and nothing else removes it until SessionEnd hours later.
if [ -n "$pr" ]; then
  a="$root/.claude/automerge-active-$pr"
  if [ -f "$a" ] || [ -f "$a.rewakes" ] || [ -f "$a.capped" ] || [ -f "$a.progress" ]; then
    rm -f "$a" "$a.rewakes" "$a.capped" "$a.progress"
    say "removed automerge-active-$pr (+ .rewakes/.capped/.progress)"
  fi
fi

# --- 3. end the processes this stage orphaned --------------------------------------
# BEFORE the worktree release below, deliberately. A process still holding a cwd inside the
# worktree makes `git worktree remove` fail, and the release would then report uncommitted-work
# contention that is really a leaked process, sending you to look in the wrong place.
#
# At {parallel}=1 there is no per-issue worktree, so the stage's tree is the repo root.
sweep_tree="$worktree"
[ -n "$sweep_tree" ] || sweep_tree="$root"
if [ -n "$_lib_dir" ] && [ -x "$_lib_dir/stage-processes.sh" ]; then
  sweep_out=$("$_lib_dir/stage-processes.sh" sweep "$issue" --tree "$sweep_tree" 2>&1)
  sweep_rc=$?
  [ -n "$sweep_out" ] && printf '%s\n' "$sweep_out"
  case "$sweep_rc" in
    0) ;;
    5) say "PROCESS SWEEP BLIND for #$issue — orphaned processes cannot be ruled out. Was 'stage-processes.sh snapshot $issue' run before dispatch?"
       rc=3 ;;
    *) rc=3 ;;
  esac
else
  say "PROCESS SWEEP SKIPPED: no executable stage-processes.sh beside this script — orphans cannot be ruled out"
  rc=3
fi

# --- 4. release the per-issue worktree ---------------------------------------------
# NEVER --force. A non-zero exit means uncommitted work in that tree: leave it, name the path, and
# let the summary carry it. An abandoned worktree is recoverable; destroyed work is not.
if [ -n "$worktree" ] && [ -d "$worktree" ]; then
  if git -C "$root" worktree remove "$worktree" 2>/dev/null; then
    git -C "$root" worktree prune 2>/dev/null || true
    say "released worktree $worktree"
  else
    say "WORKTREE NOT RELEASED: $worktree still has uncommitted work — left in place deliberately. Resolve by hand; do not --force."
    rc=3
  fi
fi

# --- 5. delete the local branch, but only after a VERIFIED merge --------------------
# `gh pr merge --delete-branch` deletes the remote branch but refuses to delete a local one the
# tree is standing on — which is how stale local branches outlive their own merges. Returning to
# the base branch first is what makes the delete possible at all.
if [ "$merged" -eq 1 ]; then
  if [ -z "$integration" ]; then
    integration=$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
    if [ -z "$integration" ]; then
      for c in main master; do
        git -C "$root" show-ref --verify --quiet "refs/heads/$c" && { integration="$c"; break; }
      done
    fi
  fi
  # THE NAME COMES FROM THE CALLER, NOT A SCAN. This block runs `git branch -D`, which is
  # irreversible, and /backlog already owns the exact branch name (skills/backlog §6: the
  # orchestrator picks it, writes it into the sentinel, and hands it to every stage). A widened
  # glob such as refs/heads/*/{issue}-* would also match `travis/42-notes` and `wip/42-x` —
  # verified — so widening the DELETE path to cover conventional prefixes would trade a missed
  # cleanup for destroying someone's unrelated branch. Take the name instead.
  if [ -n "$branch" ]; then
    branches=$(git -C "$root" for-each-ref --format='%(refname:short)' "refs/heads/$branch" 2>/dev/null || true)
    [ -n "$branches" ] || say "branch '$branch' not present locally — nothing to delete"
  elif command -v branch_refs_strict >/dev/null 2>&1; then
    # Legacy fallback for callers that omit --branch. STRICT grammar only: an unrecognized name
    # is never deleted on a guess.
    branches=$(branch_refs_strict "$root" "$issue" 2>/dev/null || true)
  else
    branches=$(git -C "$root" for-each-ref --format='%(refname:short)' "refs/heads/feature/$issue-*" 2>/dev/null || true)
  fi
  if [ -n "$branches" ]; then
    if [ -n "$integration" ]; then
      head_branch=$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null || true)
      if [ "$head_branch" != "$integration" ]; then
        # Only safe because the caller asserted a clean tree via preflight guard 3 before this
        # point. A plain checkout with a dirty tree is the silent carry-over that guard exists for.
        git -C "$root" checkout --quiet "$integration" 2>/dev/null || say "could not checkout $integration"
      fi
    fi
    # A here-doc, deliberately NOT `printf … | while read`: a pipe runs the loop in a subshell,
    # so the rc=3 below would be discarded and a branch that could not be deleted would exit 0.
    # Unquoted `for b in $branches` also glob-expands, and scoped names carry parentheses.
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      if git -C "$root" branch -D "$b" >/dev/null 2>&1; then
        say "deleted merged local branch $b"
      else
        say "BRANCH NOT DELETED: $b — resolve by hand"
        rc=3
      fi
    done <<BRANCHES
$branches
BRANCHES
  fi
fi

[ "$rc" -eq 0 ] && say "teardown complete for #$issue"
exit "$rc"
