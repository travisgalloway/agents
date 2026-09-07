#!/usr/bin/env bash
# backlog-preflight.sh — the guards /backlog runs before dispatching any stage.
#
# WHY THIS IS A SCRIPT AND NOT PROSE IN THE SKILL BODY:
# A /backlog run is long enough that the orchestrator's context WILL compact — a 40-issue queue
# costs ~10.5k tokens per issue to orchestrate. A remembered checklist degrades under compaction
# into a paraphrase: one that preserves "check the tree is clean" while dropping the reason it
# mattered, or "verify the merge" while dropping a jq null-guard. A script on disk cannot be
# lossily summarized. Calling this costs ~120 tokens; remembering it costs ~60 lines that decay.
#
# THE FAILURE THIS FILE EXISTS FOR (guard 3):
# At parallel=1 there are no worktrees — every issue in the queue shares one working tree. If an
# exec stage is torn down mid-edit, `git checkout {integration}` with non-conflicting modified
# files SUCCEEDS and carries them along; `checkout -b` then carries them onto the next issue's
# branch; and that issue's exec stage commits them with `git add .`. Issue N's half-finished work
# ships inside issue N+1's PR, and nothing anywhere reports an error.
#
# CONTRACT: act on the exit code and on nothing else. Every path prints a one-line reason to
# stdout first. Never parse the prose; it is for the human reading the transcript.
#
#   0   all requested guards pass
#   2   HEAD is not on the integration branch
#   3   working tree is dirty (with --stash: the stash itself failed)
#   4   HEAD is AHEAD of origin/{integration} — a stage committed straight to the base branch
#   5   fast-forward of the integration branch failed
#   6   a stale local branch for issue {N} exists (ANY prefix — see the guard)
#   7   a sentinel belonging to ANOTHER session is present — another run is live
#   8   a declared parent issue is not MERGED
#   9   worktree count does not match what {parallel} implies
#   11  parent state could not be read from gh — UNKNOWN, which is not the same as "fine"
#   12  the info/exclude entries could not be installed — the run's artifacts are committable
#   64  usage error
#
# Guards 2-6 are shared-tree guards and are SKIPPED when --tree names a per-issue worktree
# (parallel>1), where each issue is isolated by construction and the base branch is not checked
# out in the tree being examined.
#
# NOT here: the ledger monitor sweep. TaskStop is a harness tool, not a shell command, so that
# sweep lives in the skill body — but it runs at EVERY preflight, not only at
# the end of the run, because an orphaned 60s poller after compaction emits into the very
# context that just compacted.

set -u

# The branch grammar, shared with lib/branches.sh and lib/backlog-teardown.sh so guard 6 and
# what the skills tell the model can never drift apart.
_lib_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || _lib_dir=""
if [ -n "$_lib_dir" ] && [ -r "$_lib_dir/branch-name.sh" ]; then
  . "$_lib_dir/branch-name.sh" 2>/dev/null || true
fi

usage() {
  cat <<'EOF'
usage: backlog-preflight.sh <issue-number> [options]
       backlog-preflight.sh 0 --run-start [options]

  --parents 9,11      issue numbers that must read MERGED before this issue may be dispatched
  --integration NAME  base branch (default: resolved from origin/HEAD, else main/master)
  --tree PATH         the working tree to examine (default: repo root). Naming a per-issue
                      worktree skips the shared-tree guards 2-6.
  --repo OWNER/NAME   passed to gh as --repo (default: gh auto-detects)
  --stash             on a dirty tree, `git stash push -u` instead of failing. Prints the stash
                      ref for the ledger. NEVER discards: no checkout -f, no reset --hard.
  --worktrees N       expected `git worktree list` count (default: 1)
  --run-start         whole-run preflight: guards 2,3,4,5,7,9 only (no issue-specific checks)
EOF
}

issue=""; parents=""; integration=""; tree=""; repo=""; stash=0; want_worktrees=1; run_start=0

[ $# -ge 1 ] || { usage >&2; exit 64; }
issue="$1"; shift
case "$issue" in ''|*[!0-9]*) printf 'usage: first argument must be an issue number (0 with --run-start)\n'; usage >&2; exit 64 ;; esac

while [ $# -gt 0 ]; do
  case "$1" in
    --parents)
      parents="${2:-}"
      # Validated HERE, not at use time. Guard 8 reaches for gh, and a malformed list must be a
      # usage error rather than an "unknown parent state" that reads like a real dependency stop.
      for _p in $(printf '%s' "$parents" | tr ',' ' '); do
        case "$_p" in ''|*[!0-9]*)
          printf 'invalid --parents entry: %s (expected comma-separated issue numbers)\n' "$_p"
          exit 64 ;;
        esac
      done
      shift 2 ;;
    --integration) integration="${2:-}"; shift 2 ;;
    --tree)        tree="${2:-}"; shift 2 ;;
    --repo)        repo="${2:-}"; shift 2 ;;
    --worktrees)   want_worktrees="${2:-1}"; shift 2 ;;
    --stash)       stash=1; shift ;;
    --run-start)   run_start=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1"; usage >&2; exit 64 ;;
  esac
done

say()  { printf '%s\n' "$1"; }
fail() { printf '%s\n' "$2"; exit "$1"; }

# --- locate the tree ---------------------------------------------------------------
if [ -z "$tree" ]; then
  tree=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$tree" ] || fail 64 "not inside a git repository and no --tree given"
  shared_tree=1
else
  git -C "$tree" rev-parse --git-dir >/dev/null 2>&1 || fail 64 "--tree is not a git working tree: $tree"
  # A tree under .claude-work/ is a per-issue worktree; anything else is the shared main tree.
  case "$tree" in *"/.claude-work/"*) shared_tree=0 ;; *) shared_tree=1 ;; esac
fi

# The sentinels and the common git dir live with the MAIN checkout, not the worktree.
git_common=$(git -C "$tree" rev-parse --git-common-dir 2>/dev/null || true)
case "$git_common" in
  /*) ;;                                   # already absolute
  "") git_common="$tree/.git" ;;
  *)  git_common="$tree/$git_common" ;;    # git may hand back a relative path
esac
main_root=$(cd "$git_common/.." 2>/dev/null && pwd || printf '%s' "$tree")

# --- integration branch ------------------------------------------------------------
if [ -z "$integration" ]; then
  integration=$(git -C "$tree" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
fi
if [ -z "$integration" ]; then
  for c in main master; do
    if git -C "$tree" show-ref --verify --quiet "refs/heads/$c"; then integration="$c"; break; fi
  done
fi
[ -n "$integration" ] || fail 64 "could not resolve the integration branch; pass --integration"

# --- excludes (the /work §0c step, done here so it cannot be forgotten) --------------
# info/exclude, NOT .gitignore: it is shared by every worktree and is never committed, whereas a
# .gitignore edit exists only in the main tree — so in a fresh worktree these paths would be
# untracked and an exec stage's `git add .` would commit the plan file and the ledger into the PR.
# This also has to run before guard 3, or the run's own bookkeeping reads as a dirty tree.
# A failure here must be LOUD. The caller's contract says the ledger and plan files cannot be
# committed into a PR; if the excludes were not installed, that guarantee is void and every later
# `git add .` is a live hazard. Silently returning success would be the expensive failure shape.
ensure_excludes() {
  local ex="$git_common/info/exclude" p
  mkdir -p "$git_common/info" 2>/dev/null \
    || fail 12 "could not create $git_common/info — the info/exclude entries this run depends on cannot be installed, so an exec stage's 'git add .' would commit the ledger and plan files into a PR."
  [ -f "$ex" ] || : > "$ex"
  for p in '.claude/plans/' '.claude/work-active*' '.claude/automerge-active*' '.claude-work/'; do
    if ! grep -qxF "$p" "$ex" 2>/dev/null; then
      printf '%s\n' "$p" >> "$ex" \
        || fail 12 "could not append '$p' to $ex — see above; the run's artifacts are not excluded."
    fi
  done
}
ensure_excludes

# ================================================================= shared-tree guards
if [ "$shared_tree" -eq 1 ]; then

  # --- 2. HEAD is on the integration branch ---------------------------------------
  # Deliberately checked BEFORE guard 3 and never auto-fixed: `git checkout` from here with a
  # dirty tree is exactly the silent carry-over described in the header.
  head_branch=$(git -C "$tree" symbolic-ref --short HEAD 2>/dev/null || true)
  if [ "$head_branch" != "$integration" ]; then
    fail 2 "HEAD is on '${head_branch:-detached}', expected '$integration' — a previous stage was torn down without checking out the base branch. Resolve by hand; do NOT checkout while the tree is dirty."
  fi

  # --- 3. clean working tree -------------------------------------------------------
  dirty=$(git -C "$tree" status --porcelain 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    if [ "$stash" -eq 1 ]; then
      label="backlog-orphan-$(git -C "$tree" rev-parse --short HEAD 2>/dev/null || echo unknown)"
      if git -C "$tree" stash push -u -m "$label" >/dev/null 2>&1; then
        ref=$(git -C "$tree" stash list --format='%gd %gs' 2>/dev/null | head -1)
        say "guard 3: stashed orphaned changes — $ref (recoverable; never dropped automatically)"
      else
        fail 3 "working tree is dirty and 'git stash push -u' failed — resolve by hand. NEVER checkout -f or reset --hard here; that discards a stage's work."
      fi
    else
      fail 3 "working tree is dirty — an earlier stage left edits behind. They would be carried onto the next issue's branch by checkout and committed by its 'git add .'. Re-run with --stash, or resolve by hand."
    fi
  fi

  # --- 4. HEAD is not ahead of the remote base -------------------------------------
  # A stage running under bypassPermissions can commit straight to the base branch and nothing
  # prompts. This is a hard stop for the whole run, not a per-issue blocker.
  if git -C "$tree" rev-parse --verify --quiet "origin/$integration" >/dev/null 2>&1; then
    ahead=$(git -C "$tree" rev-list --count "origin/$integration..HEAD" 2>/dev/null || echo 0)
    if [ "${ahead:-0}" -gt 0 ]; then
      fail 4 "HEAD is $ahead commit(s) AHEAD of origin/$integration — a stage committed directly to the base branch. Stop the run and resolve this; do not bury it."
    fi
  else
    say "guard 4: origin/$integration not present locally — skipped (no remote tracking ref)"
  fi

  # --- 5. fast-forward the base branch ---------------------------------------------
  if git -C "$tree" remote get-url origin >/dev/null 2>&1; then
    if git -C "$tree" fetch --quiet origin "$integration" 2>/dev/null; then
      if ! git -C "$tree" merge --ff-only --quiet "origin/$integration" 2>/dev/null; then
        fail 5 "fast-forward of '$integration' from origin failed — the local base branch has diverged. A plain 'git pull' here would create a merge commit on the base branch."
      fi
    else
      say "guard 5: could not fetch origin/$integration — skipped (offline?); the base branch may be stale"
    fi
  else
    say "guard 5: no 'origin' remote — skipped"
  fi

  # --- 6. no stale local branch for this issue -------------------------------------
  if [ "$run_start" -eq 0 ]; then
    # DELIBERATELY BROAD: any local branch whose first path component is followed by
    # "{issue}-", recognized by the grammar or not. This guard REFUSES, and the two failure
    # directions are not symmetric — a false stop on `travis/42-notes` costs one clear message,
    # while a MISSED stale branch costs a duplicate branch and a run that reports clean, which
    # is the exact blind-monitor shape this file exists to prevent.
    #
    # Not a for-each-ref pattern: its wildcards do not cross '/', so `refs/heads/*/42-*` cannot
    # see `feat/42-a/b` at all. The scan enumerates refs/heads and filters in-process.
    if command -v branch_refs_issue_shaped >/dev/null 2>&1; then
      stale=$(branch_refs_issue_shaped "$tree" "$issue" 2>/dev/null || true)
    else
      # An unreadable grammar helper is UNKNOWN, not "nothing stale". Fall back to the legacy
      # literal so the guard still bites for the scheme that predates the conventional types,
      # and say that coverage is reduced rather than reporting a clean scan.
      stale=$(git -C "$tree" for-each-ref --format='%(refname:short)' "refs/heads/feature/$issue-*" 2>/dev/null || true)
      say "guard 6: lib/branch-name.sh unreadable — scanned only 'feature/$issue-*', NOT every conventional prefix"
    fi
    if [ -n "$stale" ]; then
      fail 6 "stale local branch(es) for issue #$issue: $(printf '%s' "$stale" | tr '\n' ' ')— a plan stage would latch onto old work and report it as already done. Confirm the PR state with 'gh pr list --head', and delete only what reads MERGED."
    fi
  fi
fi

# ================================================================= tree-agnostic guards

# --- 7. no foreign-session sentinels ----------------------------------------------
# Our own stragglers are removed and reported. Another session's are a refusal: two concurrent
# runs overwrite each other's `session` field, which disarms BOTH rewake guards at once and
# makes session-cleanup.sh refuse to delete either.
mine_session="${CLAUDE_CODE_SESSION_ID:-}"
removed=""
for s in "$main_root"/.claude/work-active-* "$main_root"/.claude/automerge-active "$main_root"/.claude/automerge-active-*; do
  [ -f "$s" ] || continue
  case "$s" in *.rewakes|*.capped|*.progress) continue ;; esac
  owner_session=$(sed -n 's/.*"session"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$s" 2>/dev/null | head -1)
  if [ -n "$owner_session" ] && [ -n "$mine_session" ] && [ "$owner_session" != "$mine_session" ]; then
    fail 7 "sentinel $(basename "$s") belongs to session $owner_session, not this one — another /backlog or /work run is live on this repo. Only one run per repo at a time."
  fi
  rm -f "$s" "$s.rewakes" "$s.capped" "$s.progress"
  removed="$removed $(basename "$s")"
done
[ -n "$removed" ] && say "guard 7: removed leaked sentinel(s) and their .rewakes/.capped/.progress:$removed"

# --- 9. worktree count -------------------------------------------------------------
wt=$(git -C "$tree" worktree list 2>/dev/null | wc -l | tr -d ' ')
if [ "${wt:-0}" -ne "$want_worktrees" ]; then
  fail 9 "expected $want_worktrees worktree(s), found ${wt:-0} — a previous issue's worktree was never released. Inspect with 'git worktree list'; release with 'git worktree remove' (NO --force) then 'git worktree prune'."
fi

# --- 8. parent issues must be MERGED ----------------------------------------------
# Not "PR open and green": at parallel=1 every branch is cut from the base branch, so an
# unmerged parent is invisible to its children. They would build against a codebase missing
# what the parent was supposed to add and fail for a reason that looks unrelated.
if [ "$run_start" -eq 0 ] && [ -n "$parents" ]; then
  command -v gh >/dev/null 2>&1 || fail 11 "parents declared for #$issue but gh is unavailable — parent state is UNKNOWN, which is not the same as satisfied."
  repo_flag=""
  [ -n "$repo" ] && repo_flag="--repo $repo"
  for p in $(printf '%s' "$parents" | tr ',' ' '); do
    # shellcheck disable=SC2086
    state=$(gh issue view "$p" $repo_flag --json state,stateReason -q '(.state // "") + " " + (.stateReason // "")' 2>/dev/null || true)
    if [ -z "$state" ]; then
      fail 11 "could not read issue #$p from gh — parent state is UNKNOWN. An unreadable source is never resolved to the optimistic answer."
    fi
    case "$state" in
      CLOSED*COMPLETED*|CLOSED*completed*) ;;                       # closed as done — satisfied
      CLOSED*) fail 8 "parent #$p is CLOSED but not completed ($state) — #$issue depends on work that was abandoned." ;;
      *)       fail 8 "parent #$p is still OPEN — #$issue must not be dispatched until it merges. Record #$issue as skipped and continue." ;;
    esac
  done
  say "guard 8: parents ($parents) all closed as completed"
fi

if [ "$run_start" -eq 1 ]; then
  say "preflight OK (run start) — tree clean, on '$integration', no leaked sentinels, $wt worktree(s)"
else
  say "preflight OK for #$issue — tree clean, on '$integration', no stale branch, parents satisfied"
fi
exit 0
