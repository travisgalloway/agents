#!/usr/bin/env bash
# backlog-guards.sh — exercise lib/backlog-preflight.sh and lib/backlog-teardown.sh against real
# throwaway repos. No network, no gh (guard 8's gh paths are covered only for the "gh absent"
# branch, which is the one that must NOT resolve to the optimistic answer).
#
# THE BUGS THESE PIN:
#
#  1. Guard 3 must never DISCARD. At parallel=1 the whole queue shares one working tree, so a
#     torn-down exec leaves edits behind — and `git checkout {base}` with non-conflicting modified
#     files SUCCEEDS and carries them onto the next issue's branch, where its `git add .` commits
#     them into the wrong PR. The fix is to refuse (or stash), never `checkout -f`/`reset --hard`:
#     an abandoned change is recoverable, a discarded one is not.
#
#  2. Guard 4 must fire on AHEAD, not on dirty. A stage running under bypassPermissions can commit
#     straight to the base branch with nothing to prompt it, and that is a whole-run stop, not a
#     per-issue blocker — it is invisible from every other signal.
#
#  3. Guard 7 must distinguish OUR leaked sentinel from ANOTHER session's. Removing a foreign one
#     disarms that run's rewake guard; refusing to remove our own leaves a nudge on every idle turn
#     for the rest of the session. Same file name, opposite correct actions.
#
#  4. Teardown must remove all THREE side files, not just the sentinel. A surviving `.progress` is
#     inherited by the next run on that issue as a fresh sample, so a stage that just started reads
#     as one that already stalled.
#
#  5. Teardown must delete a branch only AFTER checking out away from it — `git branch -D` refuses
#     to delete the branch the tree is standing on, which is how stale local branches outlive their
#     own merges.

set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

PREFLIGHT="$HOME/.claude/lib/backlog-preflight.sh"
TEARDOWN="$HOME/.claude/lib/backlog-teardown.sh"
for f in "$PREFLIGHT" "$TEARDOWN"; do
  [ -f "$f" ] || { bad "script not found at $f"; summary; exit 1; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/backlog-guards.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@example.com
git config --global user.name Test
git config --global init.defaultBranch main
export CLAUDE_CODE_SESSION_ID="session-under-test"

# fresh_repo <name> -> path to a repo with an `origin` remote and one commit on main
fresh_repo() {
  local up="$WORK/$1.git" wt="$WORK/$1"
  git init -q --bare "$up"
  git init -q -b main "$wt"
  echo seed > "$wt/seed.txt"
  git -C "$wt" add -A && git -C "$wt" commit -qm seed
  git -C "$wt" remote add origin "$up"
  git -C "$wt" push -q -u origin main 2>/dev/null
  git -C "$wt" remote set-head origin main >/dev/null 2>&1
  mkdir -p "$wt/.claude"
  printf '%s' "$wt"
}

# rc_of <cmd...> — run and echo the exit code, swallowing output
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

# ─────────────────────────────────────────────────────────────────────────────
section "Preflight: the happy path"
R=$(fresh_repo happy)
assert_eq "clean repo on main passes --run-start" "0" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 0 --run-start --integration main)"
assert_eq "clean repo passes a per-issue preflight" "0" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 7 --integration main)"

# ─────────────────────────────────────────────────────────────────────────────
section "Guard 2: HEAD must be on the integration branch"
R=$(fresh_repo g2)
git -C "$R" checkout -q -b feature/5-leftover
assert_eq "rc 2 when a torn-down stage left HEAD on a feature branch" "2" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 6 --integration main)"
# Guard 2 is checked BEFORE guard 3 on purpose: checking out away from a dirty feature branch is
# the silent carry-over, so the script must refuse rather than "helpfully" fix it.
echo drift > "$R/drift.txt"
assert_eq "still rc 2 (not 3) when both are wrong — order is load-bearing" "2" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 6 --integration main)"

# ─────────────────────────────────────────────────────────────────────────────
section "Guard 3: a dirty tree is refused, and NEVER discarded"
R=$(fresh_repo g3)
echo "half-finished work from issue 5" > "$R/orphan.txt"
git -C "$R" add orphan.txt
assert_eq "rc 3 on a dirty tree without --stash" "3" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 6 --integration main)"
assert_eq "the orphaned file still exists after the refusal" "half-finished work from issue 5" \
  "$(cat "$R/orphan.txt" 2>/dev/null)"

section "Guard 3: --stash preserves the work and lets the run continue"
assert_eq "rc 0 with --stash" "0" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 6 --integration main --stash)"
assert_eq "tree is now clean" "" "$(git -C "$R" status --porcelain)"
STASHES=$(git -C "$R" stash list | wc -l | tr -d ' ')
assert_eq "the work is in a stash, not gone" "1" "$STASHES"
assert_contains "stash is labelled for recovery" "$(git -C "$R" stash list)" "backlog-orphan-"
assert_contains "the stashed content is intact" \
  "$(git -C "$R" stash show -p stash@{0} 2>/dev/null)" "half-finished work from issue 5"
assert_contains "the reason names the stash ref for the ledger" \
  "$(cd "$R" && bash "$PREFLIGHT" 6 --integration main --stash 2>&1; echo)" "preflight OK"

# ─────────────────────────────────────────────────────────────────────────────
section "Guard 4: a commit straight onto the base branch is a whole-run stop"
R=$(fresh_repo g4)
echo rogue > "$R/rogue.txt"
git -C "$R" add -A && git -C "$R" commit -qm "committed to main by mistake"
assert_eq "rc 4 when HEAD is ahead of origin/main" "4" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 9 --integration main)"
# The distinction that matters: this repo is CLEAN. Guard 3 sees nothing wrong, so without
# guard 4 the run would proceed and every later issue would branch from a polluted base.
assert_eq "the tree is clean, so only guard 4 can catch this" "" "$(git -C "$R" status --porcelain)"

# ─────────────────────────────────────────────────────────────────────────────
section "Guard 6: a stale local branch for this issue is refused"
R=$(fresh_repo g6)
git -C "$R" branch feature/12-earlier-attempt
assert_eq "rc 6 when feature/12-* already exists" "6" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 12 --integration main)"
assert_eq "a different issue number is unaffected" "0" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 13 --integration main)"
assert_eq "--run-start skips the issue-specific guard" "0" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 0 --run-start --integration main)"

# ─────────────────────────────────────────────────────────────────────────────
section "Guard 6 covers every conventional prefix, not just feature/"
# The guard REFUSES, so over-matching is cheap and under-matching is not: a missed stale branch
# means a plan stage latches onto old work and reports it as already done.
R=$(fresh_repo g6conv)
git -C "$R" branch fix/12-earlier-attempt
assert_eq "rc 6 for a stale fix/12-*" "6" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 12 --integration main)"
R=$(fresh_repo g6scoped)
git -C "$R" branch 'feat(api)/12-scoped'
assert_eq "rc 6 for a stale scoped feat(api)/12-*" "6" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 12 --integration main)"
R=$(fresh_repo g6slash)
# for-each-ref wildcards do not cross '/', so `refs/heads/*/12-*` cannot see this branch at all.
# The in-process scan is the only thing that catches it.
git -C "$R" branch 'feat/12-a/b'
assert_eq "rc 6 for a slug containing / (invisible to a glob)" "6" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 12 --integration main)"
R=$(fresh_repo g6foreign)
git -C "$R" branch travis/12-notes
assert_eq "rc 6 for an issue-shaped branch with a non-conventional prefix" "6" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 12 --integration main)"
R=$(fresh_repo g6clean)
git -C "$R" branch fix/13-other
git -C "$R" branch notes-12-thing
assert_eq "a different issue number is still unaffected" "0" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 12 --integration main)"

# ─────────────────────────────────────────────────────────────────────────────
section "Teardown deletes the branch it was GIVEN, and nothing else"
# This block runs `git branch -D`. /backlog owns the exact name already, so it is passed in
# rather than guessed — a widened glob would also match `travis/12-notes`, and the cost of a
# wrong match here is someone's unrelated branch, not a retry.
R=$(fresh_repo tdbranch)
git -C "$R" branch fix/12-target
git -C "$R" branch travis/12-notes
git -C "$R" branch 'feat(api)/12-other'
out=$(cd "$R" && bash "$TEARDOWN" 12 --merged --branch fix/12-target --root "$R" --integration main 2>&1)
assert_eq "the named branch is gone" "" \
  "$(git -C "$R" for-each-ref --format='%(refname:short)' refs/heads/fix/12-target)"
assert_eq "a same-issue foreign branch SURVIVES" "travis/12-notes" \
  "$(git -C "$R" for-each-ref --format='%(refname:short)' refs/heads/travis/12-notes)"
assert_eq "a same-issue conventional branch it was not told about SURVIVES" "feat(api)/12-other" \
  "$(git -C "$R" for-each-ref --format='%(refname:short)' 'refs/heads/feat(api)/12-other')"

R=$(fresh_repo tdstrict)
# Without --branch the strict grammar scan is the fallback. It must still never touch a name
# the grammar does not recognize.
git -C "$R" branch fix/12-legacyfallback
git -C "$R" branch travis/12-notes
out=$(cd "$R" && bash "$TEARDOWN" 12 --merged --root "$R" --integration main 2>&1)
assert_eq "the fallback deletes a recognized branch" "" \
  "$(git -C "$R" for-each-ref --format='%(refname:short)' refs/heads/fix/12-legacyfallback)"
assert_eq "the fallback never deletes an unrecognized one" "travis/12-notes" \
  "$(git -C "$R" for-each-ref --format='%(refname:short)' refs/heads/travis/12-notes)"

R=$(fresh_repo tdnomerge)
git -C "$R" branch fix/12-unmerged
out=$(cd "$R" && bash "$TEARDOWN" 12 --branch fix/12-unmerged --root "$R" --integration main 2>&1)
assert_eq "without --merged nothing is deleted at all" "fix/12-unmerged" \
  "$(git -C "$R" for-each-ref --format='%(refname:short)' refs/heads/fix/12-unmerged)"

# ─────────────────────────────────────────────────────────────────────────────
section "Guard 7: our leaked sentinel is swept; another session's is a refusal"
R=$(fresh_repo g7)
mk_sentinel() {
  printf '{"issue": %s, "stage": "exec", "branch": "feature/%s-x", "session": "%s"}\n' "$1" "$1" "$2" \
    > "$R/.claude/work-active-$1"
  : > "$R/.claude/work-active-$1.rewakes"
  : > "$R/.claude/work-active-$1.capped"
  : > "$R/.claude/work-active-$1.progress"
}
mk_sentinel 4 "session-under-test"
assert_eq "our own straggler does not block the run" "0" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 5 --integration main)"
assert_eq "it is removed" "" "$(ls "$R"/.claude/work-active-4 2>/dev/null)"
assert_eq "and so are all three side files" "0" \
  "$(ls "$R"/.claude/work-active-4.rewakes "$R"/.claude/work-active-4.capped \
        "$R"/.claude/work-active-4.progress 2>/dev/null | wc -l | tr -d ' ')"

mk_sentinel 8 "some-other-session"
assert_eq "another session's sentinel is rc 7, not a sweep" "7" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 9 --integration main)"
assert_eq "and it is left strictly alone" "1" \
  "$(ls "$R"/.claude/work-active-8 2>/dev/null | wc -l | tr -d ' ')"

# ─────────────────────────────────────────────────────────────────────────────
section "Guard 8: an unreadable parent is UNKNOWN (rc 11), never 'satisfied'"
R=$(fresh_repo g8)
# Shadow gh with an empty PATH entry so it cannot be found. An empty result from a lookup that
# could not run must not read the same as "the parent is merged".
assert_eq "rc 11 when parents are declared and gh is unavailable" "11" \
  "$(cd "$R" && PATH="$WORK/nogh:/usr/bin:/bin" rc_of bash "$PREFLIGHT" 3 --parents 1,2 --integration main)"
assert_eq "no --parents means no gh call and no failure" "0" \
  "$(cd "$R" && PATH="$WORK/nogh:/usr/bin:/bin" rc_of bash "$PREFLIGHT" 3 --integration main)"
assert_eq "rc 64 on a malformed --parents list" "64" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 3 --parents "1,abc" --integration main)"

# ─────────────────────────────────────────────────────────────────────────────
section "Guard 9: an unreleased worktree is caught"
R=$(fresh_repo g9)
git -C "$R" worktree add -q -b feature/2-wt "$R/.claude-work/session-under-test/issue-2" 2>/dev/null
assert_eq "rc 9 when a second worktree survives" "9" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 3 --integration main)"
assert_eq "expected count can be raised for parallel>1" "0" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 3 --integration main --worktrees 2)"

section "Shared-tree guards 2-6 are skipped inside a per-issue worktree"
WT="$R/.claude-work/session-under-test/issue-2"
echo dirty > "$WT/scratch.txt"
# In the worktree the branch is feature/2-wt (guard 2 would fire), the tree is dirty (guard 3
# would fire), and feature/2-* exists (guard 6 would fire). All three are correct states there.
assert_eq "a dirty worktree on its own feature branch still passes" "0" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 2 --tree "$WT" --integration main --worktrees 2)"

# ─────────────────────────────────────────────────────────────────────────────
section "Teardown: every side file goes, every time"
R=$(fresh_repo t1)
printf '{"issue": 5, "session": "session-under-test"}\n' > "$R/.claude/work-active-5"
: > "$R/.claude/work-active-5.rewakes"
: > "$R/.claude/work-active-5.capped"
: > "$R/.claude/work-active-5.progress"
printf '{"pr": 42}\n' > "$R/.claude/automerge-active-42"
: > "$R/.claude/automerge-active-42.progress"
assert_eq "teardown succeeds" "0" "$(cd "$R" && rc_of bash "$TEARDOWN" 5 --pr 42 --root "$R")"
assert_eq "no work-active-5 artifacts survive" "0" \
  "$(ls "$R"/.claude/work-active-5* 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "no automerge-active-42 artifacts survive" "0" \
  "$(ls "$R"/.claude/automerge-active-42* 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "teardown on an already-clean issue is still success" "0" \
  "$(cd "$R" && rc_of bash "$TEARDOWN" 5 --pr 42 --root "$R")"

# ─────────────────────────────────────────────────────────────────────────────
section "Teardown: the branch goes only on a VERIFIED merge, and only after checkout"
R=$(fresh_repo t2)
git -C "$R" checkout -q -b feature/9-done
echo work > "$R/w.txt"; git -C "$R" add -A; git -C "$R" commit -qm "work (#9)"
git -C "$R" checkout -q main

assert_eq "without --merged the branch is untouched" "0" \
  "$(cd "$R" && rc_of bash "$TEARDOWN" 9 --root "$R")"
assert_eq "feature/9-done still present" "feature/9-done" \
  "$(git -C "$R" for-each-ref --format='%(refname:short)' refs/heads/feature/9-done)"

# THE REGRESSION: standing on the branch is exactly the state after an exec stage, and
# `git branch -D` refuses to delete the branch HEAD points at.
git -C "$R" checkout -q feature/9-done
assert_eq "with --merged, teardown succeeds even while standing on the branch" "0" \
  "$(cd "$R" && rc_of bash "$TEARDOWN" 9 --merged --integration main --root "$R")"
assert_eq "the branch is gone" "" \
  "$(git -C "$R" for-each-ref --format='%(refname:short)' refs/heads/feature/9-done)"
assert_eq "and HEAD was returned to the base branch" "main" \
  "$(git -C "$R" symbolic-ref --short HEAD)"

# ─────────────────────────────────────────────────────────────────────────────
section "Teardown: a worktree with uncommitted work is NEVER destroyed"
R=$(fresh_repo t3)
WT="$R/.claude-work/session-under-test/issue-3"
git -C "$R" worktree add -q -b feature/3-wip "$WT" 2>/dev/null
echo "unsaved" > "$WT/unsaved.txt"
RC=$(cd "$R" && rc_of bash "$TEARDOWN" 3 --root "$R" --worktree "$WT")
assert_eq "rc 3 signals the worktree was left in place" "3" "$RC"
assert_eq "the uncommitted file survives" "unsaved" "$(cat "$WT/unsaved.txt" 2>/dev/null)"
assert_contains "and the path is named so it can be resolved by hand" \
  "$(cd "$R" && bash "$TEARDOWN" 3 --root "$R" --worktree "$WT" 2>&1)" "WORKTREE NOT RELEASED"

section "Teardown: a clean worktree IS released"
R=$(fresh_repo t4)
WT="$R/.claude-work/session-under-test/issue-4"
git -C "$R" worktree add -q -b feature/4-clean "$WT" 2>/dev/null
assert_eq "clean worktree releases cleanly" "0" \
  "$(cd "$R" && rc_of bash "$TEARDOWN" 4 --root "$R" --worktree "$WT")"
assert_eq "only the main tree remains" "1" \
  "$(git -C "$R" worktree list | wc -l | tr -d ' ')"

# ─────────────────────────────────────────────────────────────────────────────
section "Failure messages must not EXECUTE the commands they name"
# THE REGRESSION: a message like "a plain `git pull` here would create a merge commit" is written
# inside a double-quoted string, so bash runs `git pull` for real while explaining that you must
# not. `bash -n` cannot see this — it is syntactically valid. The guard-5 path was doing exactly
# that against the live tree.
# `grep -c` prints 0 and EXITS 1 when there are no matches, so a `|| echo 0` fallback would
# append a second 0 and this assertion could never pass. Let the count stand on its own.
assert_eq "no backticks inside double-quoted strings in preflight" "0" \
  "$(grep -c '"[^"]*`' "$PREFLIGHT" 2>/dev/null)"
assert_eq "no backticks inside double-quoted strings in teardown" "0" \
  "$(grep -c '"[^"]*`' "$TEARDOWN" 2>/dev/null)"

# Prove it behaviourally on the guard that carried the bug: diverge the base branch so guard 5
# fails, and confirm the failure path leaves the repo exactly as it found it.
R=$(fresh_repo g5)
echo upstream > "$WORK/g5.clone-seed"
git clone -q "$WORK/g5.git" "$WORK/g5-other"
echo remote-change > "$WORK/g5-other/remote.txt"
git -C "$WORK/g5-other" add -A && git -C "$WORK/g5-other" commit -qm "remote work"
git -C "$WORK/g5-other" push -q origin main
# Local main now has a commit the remote does not, and vice versa: a genuine divergence.
echo local-change > "$R/local.txt"
git -C "$R" add -A && git -C "$R" commit -qm "local work"
BEFORE=$(git -C "$R" rev-parse HEAD)
RC=$(cd "$R" && rc_of bash "$PREFLIGHT" 3 --integration main)
# rc 4 (ahead) fires before rc 5 here; either way the point is that nothing was merged or pulled.
assert_contains "divergence is refused (rc 4 or 5)" " 4 5 " " $RC "
assert_eq "HEAD is untouched by the failure path" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"
assert_eq "no merge commit was created" "1" \
  "$(git -C "$R" rev-list --count --merges HEAD~1..HEAD 2>/dev/null | grep -c '^0$' || echo 0)"

section "Guard 12: a broken info/exclude is loud, not a silent no-op"
# The caller's contract is that the ledger and plan files can never be committed into a PR. If the
# excludes cannot be installed that guarantee is void, so returning success here would be the
# expensive shape: everything looks fine until an exec stage's `git add .` commits them.
R=$(fresh_repo x1)
assert_eq "excludes are installed on a normal run" "0" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 0 --run-start --integration main)"
EX="$R/.git/info/exclude"
for p in '.claude/plans/' '.claude/work-active*' '.claude/automerge-active*' '.claude-work/'; do
  assert_contains "info/exclude carries $p" "$(cat "$EX" 2>/dev/null)" "$p"
done
assert_eq "re-running does not duplicate entries" "1" \
  "$(cd "$R" && bash "$PREFLIGHT" 0 --run-start --integration main >/dev/null 2>&1; \
     grep -cxF '.claude-work/' "$EX")"

R=$(fresh_repo x2)
chmod 0555 "$R/.git/info" 2>/dev/null
chmod 0444 "$R/.git/info/exclude" 2>/dev/null
RC=$(cd "$R" && rc_of bash "$PREFLIGHT" 0 --run-start --integration main)
chmod 0755 "$R/.git/info" 2>/dev/null; chmod 0644 "$R/.git/info/exclude" 2>/dev/null
assert_eq "an unwritable info/exclude is rc 12, not a silent pass" "12" "$RC"

section "Usage errors are rc 64, never a silent default"
R=$(fresh_repo u1)
assert_eq "preflight with no issue number" "64" "$(cd "$R" && rc_of bash "$PREFLIGHT")"
assert_eq "preflight with a non-numeric issue" "64" "$(cd "$R" && rc_of bash "$PREFLIGHT" abc)"
assert_eq "preflight with an unknown option" "64" \
  "$(cd "$R" && rc_of bash "$PREFLIGHT" 1 --nope)"
assert_eq "teardown with no issue number" "64" "$(cd "$R" && rc_of bash "$TEARDOWN")"
assert_eq "teardown with an unknown option" "64" \
  "$(cd "$R" && rc_of bash "$TEARDOWN" 1 --nope)"

summary
